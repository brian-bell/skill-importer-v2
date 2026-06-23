//! Repository checkout provider for `import repository`
//! (cli-clean-room-spec.md "import repository").
//!
//! The `Provider` interface (struct of fn pointers) is injectable so repository
//! import tests need no network or `git` binary (zig-clean-room-cli.md "Test
//! infrastructure": fake git provider). `RealProvider` shells out to
//! `git clone --depth 1 <repository> <dest>`; a missing `git` binary
//! (spawn `FileNotFound`) surfaces as `error.GitUnavailable` so the CLI can
//! report "git not installed" (zig-clean-room-cli.md Phase 4b).

const std = @import("std");

/// Git/repository provider abstraction (struct of fn pointers). The real
/// implementation (`RealProvider`) and the test fake share this interface so
/// `repository.zig` is hermetic.
pub const Provider = struct {
    /// Materialize `repository` into the (already-created, empty) directory at
    /// absolute `dest_path`, or return a `CheckoutError`.
    checkoutFn: *const fn (ctx: *anyopaque, repository: []const u8, dest_path: []const u8) CheckoutError!void,
    ctx: *anyopaque,

    pub const CheckoutError = error{ GitUnavailable, RepositoryError };

    pub fn checkout(self: Provider, repository: []const u8, dest_path: []const u8) CheckoutError!void {
        return self.checkoutFn(self.ctx, repository, dest_path);
    }
};

/// Real provider: `git clone --depth 1 <repository> <dest_path>`
/// (zig-clean-room-cli.md Phase 4b). A `git` binary that cannot be spawned
/// (`error.FileNotFound`) maps to `GitUnavailable`; any non-zero exit or other
/// spawn/run failure maps to `RepositoryError`. Construct with an `Io` and an
/// allocator (0.16 `std.process.run` is Io-threaded).
pub const RealProvider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Executable used as `argv[0]` for the clone. Defaults to `"git"` (resolved
    /// via PATH). Injectable so error-mapping tests can point it at a missing
    /// path (spawn `FileNotFound` -> `GitUnavailable`) or a stub that exits
    /// non-zero (-> `RepositoryError`) without touching the process environment.
    git_path: []const u8 = "git",

    pub fn init(gpa: std.mem.Allocator, io: std.Io) RealProvider {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn provider(self: *RealProvider) Provider {
        return .{ .checkoutFn = checkoutImpl, .ctx = self };
    }

    fn checkoutImpl(ctx: *anyopaque, repository: []const u8, dest_path: []const u8) Provider.CheckoutError!void {
        const self: *RealProvider = @ptrCast(@alignCast(ctx));
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ self.git_path, "clone", "--depth", "1", repository, dest_path },
        }) catch |err| switch (err) {
            // No `git` binary on PATH (zig-clean-room-cli.md: spawn FileNotFound
            // -> "git not installed").
            error.FileNotFound => return error.GitUnavailable,
            else => return error.RepositoryError,
        };
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) return error.RepositoryError,
            else => return error.RepositoryError,
        }
    }
};

// --- RealProvider error-mapping tests --------------------------------------
//
// These exercise the REAL `std.process.run` path (only `FakeProvider` is used
// elsewhere). `git_path` is injected so we control the spawned executable
// without mutating the process environment (SAFETY: no real roots touched; the
// only filesystem writes are inside a `std.testing.tmpDir`).

const testing = std.testing;
const test_io = std.testing.io;

// A `git` binary that cannot be spawned (`spawn` returns `error.FileNotFound`)
// must map to `GitUnavailable` so the CLI can report "git not installed"
// (zig-clean-room-cli.md Phase 4b). We point `git_path` at an absolute path that
// does not exist: an absolute `argv[0]` bypasses PATH, so the exec fails with
// `FileNotFound`.
test "RealProvider: a missing git executable maps to GitUnavailable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(test_io, ".", testing.allocator);
    defer testing.allocator.free(base);

    const missing_git = try std.fs.path.join(testing.allocator, &.{ base, "definitely-not-git" });
    defer testing.allocator.free(missing_git);
    const dest = try std.fs.path.join(testing.allocator, &.{ base, "checkout" });
    defer testing.allocator.free(dest);

    var rp = RealProvider.init(testing.allocator, test_io);
    rp.git_path = missing_git;
    try testing.expectError(error.GitUnavailable, rp.provider().checkout("https://example.test/x.git", dest));
}

// A `git` that runs but exits non-zero must map to `RepositoryError` (the spec's
// fetch/open failure). We stub a tiny executable shell script that always exits
// 1, point `git_path` at it, and assert the mapping. (POSIX-only; on Windows the
// stub mechanism would differ, but the clean-room target is POSIX.)
test "RealProvider: a non-zero git exit maps to RepositoryError" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(test_io, ".", testing.allocator);
    defer testing.allocator.free(base);

    // Write an executable stub that exits non-zero regardless of arguments.
    {
        var f = try tmp.dir.createFile(test_io, "fakegit", .{ .permissions = .executable_file });
        defer f.close(test_io);
        try f.writeStreamingAll(test_io, "#!/bin/sh\nexit 7\n");
    }

    const stub = try std.fs.path.join(testing.allocator, &.{ base, "fakegit" });
    defer testing.allocator.free(stub);
    const dest = try std.fs.path.join(testing.allocator, &.{ base, "checkout" });
    defer testing.allocator.free(dest);

    var rp = RealProvider.init(testing.allocator, test_io);
    rp.git_path = stub;
    try testing.expectError(error.RepositoryError, rp.provider().checkout("https://example.test/x.git", dest));
}
