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

/// Real std.http-backed fetcher. Owns an `Io.Threaded` so the worker thread and
/// the http client have an `Io` independent of any caller's. Construct via
/// `init`, use `fetcher()`, and `deinit()` when done.
pub const RealFetcher = struct {
    threaded: std.Io.Threaded,

    pub fn init(gpa: std.mem.Allocator) RealFetcher {
        return .{ .threaded = .init(gpa) };
    }

    pub fn deinit(self: *RealFetcher) void {
        self.threaded.deinit();
    }

    pub fn fetcher(self: *RealFetcher) Fetcher {
        return .{ .fetchFn = fetchImpl, .ctx = self };
    }

    fn fetchImpl(ctx: *anyopaque, gpa: std.mem.Allocator, url: []const u8) Fetcher.FetchError![]u8 {
        const self: *RealFetcher = @ptrCast(@alignCast(ctx));
        const io = self.threaded.io();
        return fetchWithDeadline(io, gpa, url, timeout_seconds);
    }
};

/// Shared state between the caller and the fetch worker thread. Heap-allocated
/// and reference-counted (2 owners: caller + worker) so that on a timeout the
/// caller can detach the worker and return without freeing state the still-
/// running worker references. Whichever side releases last frees the job.
const Job = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []u8,
    done: std.Io.Event = .unset,
    result: Fetcher.FetchError![]u8 = error.FetchFailed,
    refs: std.atomic.Value(usize) = .init(2),
    /// Set true by the caller when it takes ownership of `result`'s body; the
    /// last releaser frees the body only if it was never consumed.
    consumed: std.atomic.Value(bool) = .init(false),

    fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) == 1) {
            // Last owner: if a successful body was produced but never consumed
            // by the caller (it timed out), free it so it does not leak.
            if (!job.consumed.load(.acquire)) {
                if (job.result) |body| job.gpa.free(body) else |_| {}
            }
            const gpa = job.gpa;
            gpa.free(job.url);
            gpa.destroy(job);
        }
    }
};

/// Run `fetchOnce` on a worker thread and wait up to `seconds` for it. If the
/// worker does not finish in time, return `error.Timeout` (the worker is
/// detached and finishes in the background — best-effort, the socket may linger;
/// zig-clean-room-cli.md "Risks"). All worker-referenced state (the job and a
/// private copy of `url`) is reference-counted so detaching is memory-safe.
pub fn fetchWithDeadline(io: std.Io, gpa: std.mem.Allocator, url: []const u8, seconds: i64) Fetcher.FetchError![]u8 {
    const job = try gpa.create(Job);
    job.* = .{ .io = io, .gpa = gpa, .url = undefined };
    job.url = gpa.dupe(u8, url) catch {
        gpa.destroy(job);
        return error.OutOfMemory;
    };

    const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        gpa.free(job.url);
        gpa.destroy(job);
        return error.FetchFailed;
    };

    const timeout: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromSeconds(seconds),
    } };
    job.done.waitTimeout(io, timeout) catch |err| {
        // Worker still running: detach it; it will free its own result body and
        // release its job reference when it eventually finishes. The caller
        // writes no storage on error.
        thread.detach();
        job.release();
        return switch (err) {
            error.Timeout => error.Timeout,
            else => error.FetchFailed,
        };
    };
    thread.join();
    const result = job.result;
    // The worker finished; the caller takes ownership of any returned body so
    // the job's releaser must not free it.
    if (result) |_| job.consumed.store(true, .release) else |_| {}
    job.release();
    return result;
}

fn worker(job: *Job) void {
    job.result = fetchOnce(job.io, job.gpa, job.url);
    job.done.set(job.io);
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
