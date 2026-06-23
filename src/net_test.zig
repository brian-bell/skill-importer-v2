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
    // Use page_allocator for the fetch so the abandoned in-flight worker — which
    // frees its own allocations only after it eventually completes — does not
    // trip the leak detector that std.testing.allocator runs at test end.
    const gpa = std.heap.page_allocator;
    try testing.expectError(error.Timeout, net.fetchWithDeadline(io, gpa, u, 1));
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
