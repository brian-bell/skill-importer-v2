//! Tests for net.zig (cli-clean-room-spec.md "import url"): bounded size,
//! invalid-UTF-8 rejection, finite timeout, and a real fetch against a loopback
//! std.http.Server. Safety: the server binds to IPv4 loopback on an ephemeral
//! port and is torn down per test; no real network or user roots are touched.

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const net = @import("net.zig");

/// A loopback HTTP server that serves one connection: it accepts a single
/// client, reads the request head, and responds per `Behavior`.
const LoopbackServer = struct {
    server: std.Io.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    behavior: Behavior,

    const Behavior = union(enum) {
        /// Respond 200 with this exact body.
        body: []const u8,
        /// Accept the connection but never respond (drives the client timeout).
        hang,
    };

    fn start(behavior: Behavior) !LoopbackServer {
        var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
        return .{
            .server = server,
            .port = server.socket.address.getPort(),
            .behavior = behavior,
        };
    }

    fn run(self: *LoopbackServer) void {
        var srv = self.server;
        var stream = srv.accept(io) catch return;
        defer stream.close(io);

        var read_buf: [16 * 1024]u8 = undefined;
        var write_buf: [16 * 1024]u8 = undefined;
        var sr = stream.reader(io, &read_buf);
        var sw = stream.writer(io, &write_buf);

        var http_server = std.http.Server.init(&sr.interface, &sw.interface);
        var request = http_server.receiveHead() catch return;

        switch (self.behavior) {
            .body => |b| {
                request.respond(b, .{}) catch return;
            },
            .hang => {
                // Hold the connection open briefly so the client deadline (not
                // the server) is what fires, then drop it.
                std.Io.Timeout.sleep(.{ .duration = .{
                    .clock = .awake,
                    .raw = std.Io.Duration.fromSeconds(2),
                } }, io) catch {};
            },
        }
    }

    fn spawn(self: *LoopbackServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn url(self: *LoopbackServer, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/skill.md", .{self.port});
    }

    fn deinit(self: *LoopbackServer) void {
        if (self.thread) |t| t.join();
        self.server.deinit(io);
    }
};

// --- real fetch against loopback (spec "import url": "Fetches Markdown from
// URL"). ---

test "fetchOnce returns the body served by a loopback server" {
    const md = "---\nname: net-skill\ndescription: From the loopback server.\n---\nBody.";
    var ls = try LoopbackServer.start(.{ .body = md });
    defer ls.deinit();
    try ls.spawn();

    const u = try ls.url(testing.allocator);
    defer testing.allocator.free(u);

    const body = try net.fetchOnce(io, testing.allocator, u);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(md, body);
}

// --- size cap (spec "import url": "Use a bounded response size ... 1 MiB"). ---

test "fetchOnce rejects a body larger than the 1 MiB cap" {
    const big = try testing.allocator.alloc(u8, net.max_body_bytes + 16);
    defer testing.allocator.free(big);
    @memset(big, 'a');

    var ls = try LoopbackServer.start(.{ .body = big });
    defer ls.deinit();
    try ls.spawn();

    const u = try ls.url(testing.allocator);
    defer testing.allocator.free(u);

    try testing.expectError(error.SizeExceeded, net.fetchOnce(io, testing.allocator, u));
}

test "fetchOnce accepts a body exactly at the 1 MiB cap" {
    const exact = try testing.allocator.alloc(u8, net.max_body_bytes);
    defer testing.allocator.free(exact);
    @memset(exact, 'b');

    var ls = try LoopbackServer.start(.{ .body = exact });
    defer ls.deinit();
    try ls.spawn();

    const u = try ls.url(testing.allocator);
    defer testing.allocator.free(u);

    const body = try net.fetchOnce(io, testing.allocator, u);
    defer testing.allocator.free(body);
    try testing.expectEqual(net.max_body_bytes, body.len);
}

// --- invalid UTF-8 (spec "import url": "Reject invalid UTF-8"). ---

test "fetchOnce rejects invalid UTF-8" {
    const invalid = "\xff\xfe not valid utf8";
    var ls = try LoopbackServer.start(.{ .body = invalid });
    defer ls.deinit();
    try ls.spawn();

    const u = try ls.url(testing.allocator);
    defer testing.allocator.free(u);

    try testing.expectError(error.InvalidUtf8, net.fetchOnce(io, testing.allocator, u));
}

// --- finite timeout (spec "import url": "Use a finite network timeout"). The
// deadline path uses a worker thread; here we set a 1 s deadline against a
// server that holds the connection for ~2 s. ---

test "fetchWithDeadline returns Timeout when the server does not respond in time" {
    var ls = try LoopbackServer.start(.hang);
    defer ls.deinit();
    try ls.spawn();

    const u = try ls.url(testing.allocator);
    defer testing.allocator.free(u);

    // On timeout the worker thread is detached and keeps running (best-effort;
    // zig-clean-room-cli.md "Risks": the socket may linger past the deadline).
    // The worker owns its own Io.Threaded and uses the worker-lifetime allocator
    // (page_allocator here) for the job and its body, freeing them itself when it
    // eventually completes — so the abandoned worker never touches the caller's
    // wait Io nor the result allocator.
    const worker_gpa = std.heap.page_allocator;
    var wait_threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer wait_threaded.deinit();
    const wait_io = wait_threaded.io();
    try testing.expectError(error.Timeout, net.fetchWithDeadline(
        wait_io,
        worker_gpa,
        testing.allocator,
        u,
        1,
        net.fetchOnce,
    ));
}

// --- UAF regression (findings #1/#2/#6): on timeout, NO detached worker may
// read or write any memory owned by the caller's wait Io or by the result
// allocator (the per-op arena in production). This test drives the timeout path
// with a fully deterministic blocking fetch and then releases the worker only
// AFTER the caller has returned AND torn down the wait Io + result allocator,
// asserting the worker self-frees with no UAF/double-free under the testing
// allocator. ---

/// Test-controlled blocking fetch. It blocks on `block_event` (settled by the
/// test thread) so the deadline deterministically fires first; on release it
/// allocates a body with the worker-lifetime allocator handed to it (proving the
/// worker uses neither the caller's wait Io nor the result allocator) and returns
/// it (the worker frees it on completion since the caller already timed out).
const BlockingFetch = struct {
    /// Set by the worker (under its own owned Io) so the test can confirm the
    /// worker reached the blocking point before the test releases it.
    var entered: std.atomic.Value(bool) = .init(false);
    /// Settled by the test thread to release the blocked worker.
    var release: std.atomic.Value(bool) = .init(false);
    /// Set true by the worker just before it returns, proving it self-completed
    /// without the caller present.
    var completed: std.atomic.Value(bool) = .init(false);

    fn fetch(worker_io: std.Io, worker_gpa: std.mem.Allocator, url: []const u8) net.Fetcher.FetchError![]u8 {
        _ = worker_io;
        entered.store(true, .release);
        // Busy-wait until the test releases us. This runs on the detached worker
        // thread; by the time `release` is true the caller has long since
        // returned and torn down its wait Io + result allocator.
        while (!release.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
        const body = try worker_gpa.dupe(u8, url);
        completed.store(true, .release);
        return body;
    }
};

test "fetchWithDeadline: detached worker self-frees after caller tears down (no UAF)" {
    BlockingFetch.entered.store(false, .release);
    BlockingFetch.release.store(false, .release);
    BlockingFetch.completed.store(false, .release);

    // The worker's job + body come from this checked allocator. If the detached
    // worker double-frees or the caller frees worker memory, the testing
    // allocator flags it; if the worker leaks, the leak check at scope end fires.
    var worker_gpa_state: std.heap.DebugAllocator(.{}) = .{};
    const worker_gpa = worker_gpa_state.allocator();

    {
        // The caller's wait Io and result allocator live ONLY in this block. The
        // worker must touch neither after the caller returns; we tear them down
        // here while the worker is still blocked, then release the worker.
        var wait_threaded: std.Io.Threaded = .init(testing.allocator, .{});
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const wait_io = wait_threaded.io();
        const result_gpa = arena_state.allocator();

        const err = net.fetchWithDeadline(
            wait_io,
            worker_gpa,
            result_gpa,
            "http://blocked.example/skill.md",
            1,
            BlockingFetch.fetch,
        );
        try testing.expectError(error.Timeout, err);
        // The worker must have reached its blocking point before we tear down.
        try testing.expect(BlockingFetch.entered.load(.acquire));

        // Tear down the caller-owned wait Io and result allocator while the
        // worker is STILL running and blocked. If the worker referenced either,
        // its later completion would corrupt freed memory.
        arena_state.deinit();
        wait_threaded.deinit();
    }

    // Now release the detached worker. It must complete using only worker-owned
    // resources (its own Io.Threaded + worker_gpa), freeing them itself.
    BlockingFetch.release.store(true, .release);
    while (!BlockingFetch.completed.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    // Give the worker a moment to run its self-free tail after setting completed.
    var spins: usize = 0;
    while (spins < 1_000_000) : (spins += 1) std.atomic.spinLoopHint();

    // No leak/double-free: the worker freed its own job + body. detectLeaks
    // returns the number of leaked allocations (0 == clean).
    try testing.expectEqual(@as(usize, 0), worker_gpa_state.detectLeaks());
    try testing.expectEqual(std.heap.Check.ok, worker_gpa_state.deinit());
}

// --- connection failure (spec "import url": "On fetch ... failure"). Nothing
// listens on this port. ---

test "fetchOnce reports FetchFailed for a refused connection" {
    // Bind+close to obtain a port that is then unused.
    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
    const port = server.socket.address.getPort();
    server.deinit(io);

    const u = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/x.md", .{port});
    defer testing.allocator.free(u);

    try testing.expectError(error.FetchFailed, net.fetchOnce(io, testing.allocator, u));
}
