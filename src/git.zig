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

    pub fn init(gpa: std.mem.Allocator, io: std.Io) RealProvider {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn provider(self: *RealProvider) Provider {
        return .{ .checkoutFn = checkoutImpl, .ctx = self };
    }

    fn checkoutImpl(ctx: *anyopaque, repository: []const u8, dest_path: []const u8) Provider.CheckoutError!void {
        const self: *RealProvider = @ptrCast(@alignCast(ctx));
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "git", "clone", "--depth", "1", repository, dest_path },
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
