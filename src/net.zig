//! URL fetch for `import url` (cli-clean-room-spec.md "import url"):
//!   - bounded response size (1 MiB product limit),
//!   - reject invalid UTF-8,
//!   - finite network timeout (30 s),
//!   - on any failure, the caller creates no import storage.
//!
//! The `Fetcher` interface (struct of fn pointers) is injectable so URL import
//! tests stay hermetic (zig-clean-room-cli.md "Test infrastructure": fake net
//! provider). `realFetcher` is the std.http-backed implementation.
//!
//! std.http.Client has no socket timeout in 0.16, so the deadline is enforced
//! with a worker thread: the fetch runs on a spawned thread that signals an
//! `Io.Event`; the caller waits up to `timeout_seconds` and returns
//! `error.Timeout` if the worker has not signalled (best-effort; the socket may
//! linger past the deadline — zig-clean-room-cli.md "Risks").
//!
//! UAF invariant (findings #1/#2/#6): on a timeout the worker is detached and
//! keeps running in the background, so it must OWN every resource it touches for
//! its entire lifetime and free them itself on completion. Concretely the worker
//! owns its own `Io.Threaded` (NOT the caller's wait Io) and uses a
//! process-lifetime allocator (the gpa given to `RealFetcher.init`, NOT the
//! per-operation arena) for the `Job`, the private `url` copy, and the response
//! body. The caller's `waitTimeout` runs on a separate, caller-owned `Io`. After
//! a timeout the caller frees NOTHING the worker still uses, and tearing down the
//! caller's `RealFetcher`/arena cannot corrupt the still-running worker. The
//! socket may linger past the timeout; the worker self-frees on completion.

const std = @import("std");

/// 1 MiB body cap (spec "import url": "The current product limit is 1 MiB").
pub const max_body_bytes: usize = 1 << 20;

/// Network timeout (zig-clean-room-cli.md "Decisions locked in": 30 s).
pub const timeout_seconds: i64 = 30;

/// Network fetcher abstraction (struct of fn pointers). The real implementation
/// (`realFetcher`) and the test fake share this interface so `import.zig` is
/// hermetic.
pub const Fetcher = struct {
    /// Fetch the body at `url` into freshly allocated bytes owned by the caller,
    /// or return a `FetchError` (spec "import url" failure modes).
    fetchFn: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, url: []const u8) FetchError![]u8,
    ctx: *anyopaque,

    pub const FetchError = error{ FetchFailed, SizeExceeded, InvalidUtf8, Timeout, OutOfMemory };

    pub fn fetch(self: Fetcher, gpa: std.mem.Allocator, url: []const u8) FetchError![]u8 {
        return self.fetchFn(self.ctx, gpa, url);
    }
};

/// Real std.http-backed fetcher.
///
/// `wait_threaded` is a caller-owned `Io.Threaded` used ONLY to run the caller's
/// `waitTimeout`; the worker never touches it, so `deinit()` (which tears it
/// down) is safe even while a timed-out worker is still running in the
/// background. `gpa` is a process-lifetime allocator (the one passed to `init`)
/// handed to the worker for the `Job`, the private `url` copy, and the response
/// body — never the per-operation arena — so a detached worker that completes
/// after the caller's arena is gone frees only its own memory. Construct via
/// `init`, use `fetcher()`, and `deinit()` when done.
pub const RealFetcher = struct {
    gpa: std.mem.Allocator,
    wait_threaded: std.Io.Threaded,

    pub fn init(gpa: std.mem.Allocator) RealFetcher {
        return .{ .gpa = gpa, .wait_threaded = .init(gpa, .{}) };
    }

    pub fn deinit(self: *RealFetcher) void {
        // Only frees the caller-owned wait Io. A detached worker owns its own
        // Io.Threaded and uses `self.gpa` (process-lifetime) for everything else,
        // so this never frees anything an in-flight worker still references.
        self.wait_threaded.deinit();
    }

    pub fn fetcher(self: *RealFetcher) Fetcher {
        return .{ .fetchFn = fetchImpl, .ctx = self };
    }

    fn fetchImpl(ctx: *anyopaque, result_gpa: std.mem.Allocator, url: []const u8) Fetcher.FetchError![]u8 {
        const self: *RealFetcher = @ptrCast(@alignCast(ctx));
        return fetchWithDeadline(
            self.wait_threaded.io(),
            self.gpa,
            result_gpa,
            url,
            timeout_seconds,
            fetchOnce,
        );
    }
};

/// The fetch-function signature `fetchWithDeadline` runs on the worker thread.
/// It receives the worker's OWN `Io` and the worker-lifetime allocator; tests
/// inject a blocking stub, production injects `fetchOnce`.
pub const FetchFn = fn (io: std.Io, gpa: std.mem.Allocator, url: []const u8) Fetcher.FetchError![]u8;

/// State owned entirely by the fetch worker thread. Heap-allocated from the
/// worker-lifetime allocator (`gpa`) — NOT the caller's per-operation arena —
/// and reference-counted (2 owners: caller + worker) so that on a timeout the
/// caller can detach the worker and return without freeing anything the still-
/// running worker references. The worker also owns its own `Io.Threaded`
/// (`threaded`); the caller's wait Io is separate. Whichever side releases the
/// last reference frees the job, the url copy, the worker's Io.Threaded, and any
/// unconsumed body — all via the worker-lifetime allocator.
const Job = struct {
    /// Worker-lifetime allocator (process-lifetime in production). Owns `url`,
    /// the body in `result`, this `Job`, and (indirectly) `threaded`'s pool.
    gpa: std.mem.Allocator,
    /// The worker's OWN Io.Threaded — independent of the caller's wait Io so the
    /// caller may tear its own down at any time without affecting the worker.
    threaded: std.Io.Threaded,
    url: []u8,
    done: std.Io.Event = .unset,
    result: Fetcher.FetchError![]u8 = error.FetchFailed,
    refs: std.atomic.Value(usize) = .init(2),
    /// Set true by the caller when it takes ownership of `result`'s body; the
    /// last releaser frees the body only if it was never consumed.
    consumed: std.atomic.Value(bool) = .init(false),

    fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) == 1) {
            const gpa = job.gpa;
            // Last owner: if a successful body was produced but never consumed
            // by the caller (it timed out), free it so it does not leak.
            if (!job.consumed.load(.acquire)) {
                if (job.result) |body| gpa.free(body) else |_| {}
            }
            job.threaded.deinit();
            gpa.free(job.url);
            gpa.destroy(job);
        }
    }
};

/// Run `fetchFn` on a worker thread and wait up to `seconds` for it.
///
/// - `wait_io` is owned by the caller and used ONLY for `waitTimeout`.
/// - `worker_gpa` is a process-lifetime allocator used for ALL worker-owned
///   state (the job, the private url copy, the worker's Io.Threaded, and the
///   body the worker produces). It must outlive a detached worker; in production
///   it is the gpa passed to `RealFetcher.init` (never the per-op arena).
/// - `result_gpa` allocates the body returned to the caller on success; in
///   production this is the per-operation arena.
///
/// If the worker does not finish in time, return `error.Timeout`: the worker is
/// detached and finishes in the background (best-effort; the socket may linger
/// past the deadline — zig-clean-room-cli.md "Risks"), then self-frees every
/// worker-owned resource. Because the worker owns its own Io.Threaded and uses
/// `worker_gpa`, neither `wait_io` nor `result_gpa` (nor the caller's
/// RealFetcher) is touched after a timeout, so tearing them down cannot UAF.
pub fn fetchWithDeadline(
    wait_io: std.Io,
    worker_gpa: std.mem.Allocator,
    result_gpa: std.mem.Allocator,
    url: []const u8,
    seconds: i64,
    comptime fetchFn: FetchFn,
) Fetcher.FetchError![]u8 {
    const job = try worker_gpa.create(Job);
    job.* = .{
        .gpa = worker_gpa,
        .threaded = .init(worker_gpa, .{}),
        .url = undefined,
    };
    job.url = worker_gpa.dupe(u8, url) catch {
        job.threaded.deinit();
        worker_gpa.destroy(job);
        return error.OutOfMemory;
    };

    const thread = std.Thread.spawn(.{}, workerMain, .{ job, fetchFn }) catch {
        job.threaded.deinit();
        worker_gpa.free(job.url);
        worker_gpa.destroy(job);
        return error.FetchFailed;
    };

    const timeout: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromSeconds(seconds),
    } };
    job.done.waitTimeout(wait_io, timeout) catch |err| {
        // Worker still running: detach it. It owns its own Io.Threaded and uses
        // `worker_gpa` for everything, so it will free its own result body and
        // release its job reference when it eventually finishes, touching neither
        // `wait_io` nor `result_gpa`. The caller writes no storage on error.
        thread.detach();
        job.release();
        return switch (err) {
            error.Timeout => error.Timeout,
            else => error.FetchFailed,
        };
    };
    thread.join();
    // The worker finished within the deadline. Copy any returned body into the
    // result allocator (the arena, in production); the worker's own copy is freed
    // by the job releaser below.
    const result: Fetcher.FetchError![]u8 = if (job.result) |body|
        (result_gpa.dupe(u8, body) catch error.OutOfMemory)
    else |err|
        err;
    job.release();
    return result;
}

/// Worker entry point. Runs `fetchFn` on the worker's OWN Io, stores the result,
/// signals the caller, and releases its job reference (freeing all worker-owned
/// memory if the caller already detached after a timeout).
fn workerMain(job: *Job, comptime fetchFn: FetchFn) void {
    const io = job.threaded.io();
    job.result = fetchFn(io, job.gpa, job.url);
    job.done.set(io);
    job.release();
}

/// Perform a single bounded HTTP GET. Streams the body into an allocating
/// writer, enforces the 1 MiB cap, requires a 2xx status, and rejects invalid
/// UTF-8. Caller owns the returned slice.
pub fn fetchOnce(io: std.Io, gpa: std.mem.Allocator, url: []const u8) Fetcher.FetchError![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // Stream the body into a fixed buffer sized one byte over the cap. The http
    // reader fills `interface.buffer`; if it ever needs to `drain` (buffer
    // full), the body exceeds the cap and we mark it exceeded and abort the
    // transfer (error.WriteFailed). This bounds memory without buffering an
    // unbounded oversized response.
    var capped = try CappedWriter.init(gpa, max_body_bytes + 1);
    defer capped.deinit(gpa);

    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &capped.interface,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (capped.exceeded) return error.SizeExceeded;
            return error.FetchFailed;
        },
    };

    if (capped.exceeded) return error.SizeExceeded;
    if (@intFromEnum(res.status) < 200 or @intFromEnum(res.status) >= 300) return error.FetchFailed;

    const bytes = capped.interface.buffered();
    if (bytes.len > max_body_bytes) return error.SizeExceeded;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;

    return gpa.dupe(u8, bytes);
}

/// A `std.Io.Writer` backed by a fixed-capacity buffer. The reader writes
/// directly into `interface.buffer`; a `drain` call means the buffer overflowed,
/// i.e. the body exceeded `cap`, so it records `exceeded` and fails the write to
/// abort the transfer. Bounds HTTP body memory to `cap` bytes.
const CappedWriter = struct {
    interface: std.Io.Writer,
    exceeded: bool = false,

    fn init(gpa: std.mem.Allocator, cap: usize) !CappedWriter {
        const buf = try gpa.alloc(u8, cap);
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buf,
            },
        };
    }

    fn deinit(self: *CappedWriter, gpa: std.mem.Allocator) void {
        gpa.free(self.interface.buffer);
        self.* = undefined;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = data;
        _ = splat;
        const self: *CappedWriter = @alignCast(@fieldParentPtr("interface", w));
        self.exceeded = true;
        return error.WriteFailed;
    }
};
