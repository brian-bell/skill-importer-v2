//! Behavior tests for `recording_copy.copyTree` — the single deterministic,
//! recording recursive directory copy shared by import / repository / promote.

const std = @import("std");
const testing = std.testing;
const testutil = @import("testutil.zig");
const recording_copy = @import("recording_copy.zig");

const io = std.testing.io;

/// A `Sink` that records emitted absolute paths into an arena-owned list, and can
/// optionally fail after a configured number of emits (to exercise the
/// partial-record contract).
const RecordingSink = struct {
    arena: std.mem.Allocator,
    paths: std.ArrayList([]const u8) = .empty,
    /// When set, the Nth emit (0-based index == fail_at) returns an error.
    fail_at: ?usize = null,

    fn sink(self: *RecordingSink) recording_copy.Sink {
        return .{ .ctx = self, .emitFn = emit };
    }

    fn emit(ctx: *anyopaque, abs_path: []const u8) anyerror!void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        if (self.fail_at) |n| {
            if (self.paths.items.len == n) return error.SinkFailed;
        }
        try self.paths.append(self.arena, try self.arena.dupe(u8, abs_path));
    }
};

/// Bundles a temp tree, an arena, a `src` and `dst` directory, and the absolute
/// path of `dst` (used as `dest_root`).
const Harness = struct {
    roots: testutil.TmpRoots,
    arena_state: std.heap.ArenaAllocator,
    fx: testutil.Fixtures,

    fn init() !Harness {
        var roots = try testutil.TmpRoots.init(testing.allocator);
        errdefer roots.deinit();
        // Materialize the two working dirs under the temp tree.
        try roots.dir().createDirPath(io, "src");
        try roots.dir().createDirPath(io, "dst");
        return .{
            .roots = roots,
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .fx = undefined,
        };
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
        self.roots.deinit();
    }

    fn arena(self: *Harness) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn destRoot(self: *Harness) []const u8 {
        return std.fs.path.join(self.arena(), &.{ self.roots.base, "dst" }) catch unreachable;
    }

    /// Write a file under `src` (creating parents) with one byte of content.
    fn writeSrcFile(self: *Harness, rel_path: []const u8) !void {
        const full = try std.fs.path.join(self.arena(), &.{ "src", rel_path });
        if (std.fs.path.dirname(full)) |d| try self.roots.dir().createDirPath(io, d);
        try self.roots.dir().writeFile(io, .{ .sub_path = full, .data = "x" });
    }

    /// Create a symlink `src/<link_rel>` pointing at `target` (creating parents).
    fn writeSrcSymlink(self: *Harness, link_rel: []const u8, target: []const u8) !void {
        const full = try std.fs.path.join(self.arena(), &.{ "src", link_rel });
        if (std.fs.path.dirname(full)) |d| try self.roots.dir().createDirPath(io, d);
        try self.roots.dir().symLink(io, target, full, .{});
    }

    /// Run copyTree from `src` into `dst` with the given exclusion and sink.
    fn run(self: *Harness, exclude: recording_copy.Exclude, sink: recording_copy.Sink) !void {
        var src = try self.roots.dir().openDir(io, "src", .{ .iterate = true });
        defer src.close(io);
        var dst = try self.roots.dir().openDir(io, "dst", .{});
        defer dst.close(io);
        try recording_copy.copyTree(self.arena(), io, src, dst, self.destRoot(), "", exclude, sink);
    }

    /// True iff `rel_path` exists under `dst`.
    fn dstExists(self: *Harness, rel_path: []const u8) bool {
        const full = std.fs.path.join(self.arena(), &.{ "dst", rel_path }) catch return false;
        _ = self.roots.dir().statFile(io, full, .{ .follow_symlinks = false }) catch return false;
        return true;
    }
};

test "copyTree: flat copy emits every regular file, sorted, absolute under dest_root" {
    var h = try Harness.init();
    defer h.deinit();

    // Create files in a deliberately non-alphabetical creation order.
    try h.writeSrcFile("c.txt");
    try h.writeSrcFile("a.txt");
    try h.writeSrcFile("SKILL.md");
    try h.writeSrcFile("b.txt");

    var rec: RecordingSink = .{ .arena = h.arena() };
    try h.run(recording_copy.exclude_none, rec.sink());

    // Every regular file landed on disk under dst.
    try testing.expect(h.dstExists("a.txt"));
    try testing.expect(h.dstExists("b.txt"));
    try testing.expect(h.dstExists("c.txt"));
    try testing.expect(h.dstExists("SKILL.md"));

    // Emitted paths are sorted ascending and absolute under dest_root.
    try testing.expectEqual(@as(usize, 4), rec.paths.items.len);
    const dest_root = h.destRoot();
    var prev: ?[]const u8 = null;
    for (rec.paths.items) |p| {
        try testing.expect(std.fs.path.isAbsolute(p));
        try testing.expect(std.mem.startsWith(u8, p, dest_root));
        if (prev) |pr| try testing.expect(std.mem.lessThan(u8, pr, p));
        prev = p;
    }
    // Sorted ascending by name: SKILL.md (uppercase) sorts before lowercase.
    try testing.expectEqualStrings("SKILL.md", std.fs.path.basename(rec.paths.items[0]));
    try testing.expectEqualStrings("a.txt", std.fs.path.basename(rec.paths.items[1]));
    try testing.expectEqualStrings("b.txt", std.fs.path.basename(rec.paths.items[2]));
    try testing.expectEqualStrings("c.txt", std.fs.path.basename(rec.paths.items[3]));
}

/// Collect the emitted basenames into a set-like check helper.
fn emittedBasenames(arena: std.mem.Allocator, paths: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (paths) |p| try list.append(arena, std.fs.path.basename(p));
    return list.toOwnedSlice(arena);
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

test "copyTree: exclude_none copies a top-level import.json" {
    var h = try Harness.init();
    defer h.deinit();

    try h.writeSrcFile("SKILL.md");
    try h.writeSrcFile("import.json");

    var rec: RecordingSink = .{ .arena = h.arena() };
    try h.run(recording_copy.exclude_none, rec.sink());

    try testing.expect(h.dstExists("import.json"));
    const names = try emittedBasenames(h.arena(), rec.paths.items);
    try testing.expect(containsStr(names, "import.json"));
}

test "copyTree: excludeGit skips .git at top level and nested" {
    var h = try Harness.init();
    defer h.deinit();

    try h.writeSrcFile("SKILL.md");
    try h.writeSrcFile(".git/config");
    try h.writeSrcFile("sub/.git/hook");
    try h.writeSrcFile("sub/keep.txt");

    var rec: RecordingSink = .{ .arena = h.arena() };
    try h.run(recording_copy.excludeGit(), rec.sink());

    // .git directories are skipped entirely (top-level and nested).
    try testing.expect(!h.dstExists(".git"));
    try testing.expect(!h.dstExists("sub/.git"));
    // Non-.git content is copied.
    try testing.expect(h.dstExists("SKILL.md"));
    try testing.expect(h.dstExists("sub/keep.txt"));

    const names = try emittedBasenames(h.arena(), rec.paths.items);
    try testing.expect(!containsStr(names, "config"));
    try testing.expect(!containsStr(names, "hook"));
    try testing.expect(containsStr(names, "SKILL.md"));
    try testing.expect(containsStr(names, "keep.txt"));
}

test "copyTree: excludeTopImportJson skips top-level import.json but copies a nested one" {
    var h = try Harness.init();
    defer h.deinit();

    try h.writeSrcFile("SKILL.md");
    try h.writeSrcFile("import.json");
    try h.writeSrcFile("sub/import.json");

    var rec: RecordingSink = .{ .arena = h.arena() };
    try h.run(recording_copy.excludeTopImportJson(), rec.sink());

    // Top-level import.json is excluded; the nested one is real content.
    try testing.expect(!h.dstExists("import.json"));
    try testing.expect(h.dstExists("sub/import.json"));
    try testing.expect(h.dstExists("SKILL.md"));

    // Exactly two copy_file emissions: SKILL.md and sub/import.json.
    try testing.expectEqual(@as(usize, 2), rec.paths.items.len);
    const dest_root = h.destRoot();
    try testing.expect(containsStr(rec.paths.items, std.fs.path.join(h.arena(), &.{ dest_root, "sub", "import.json" }) catch unreachable));
}

test "copyTree: a symlink in the source raises error.UnsupportedEntry" {
    var h = try Harness.init();
    defer h.deinit();

    try h.writeSrcFile("SKILL.md");
    try h.writeSrcSymlink("link", "SKILL.md");

    var rec: RecordingSink = .{ .arena = h.arena() };
    try testing.expectError(error.UnsupportedEntry, h.run(recording_copy.exclude_none, rec.sink()));
}

test "copyTree: a sink error aborts the copy; emitted files are exactly those the sink saw" {
    var h = try Harness.init();
    defer h.deinit();

    // Three files; the sink fails on the 2nd emit (0-based index 1).
    try h.writeSrcFile("a.txt");
    try h.writeSrcFile("b.txt");
    try h.writeSrcFile("c.txt");

    var rec: RecordingSink = .{ .arena = h.arena(), .fail_at = 1 };
    try testing.expectError(error.SinkFailed, h.run(recording_copy.exclude_none, rec.sink()));

    // The partial record is exactly the files the sink accepted before failing:
    // only "a.txt" (the failing "b.txt" emit was not recorded).
    try testing.expectEqual(@as(usize, 1), rec.paths.items.len);
    try testing.expectEqualStrings("a.txt", std.fs.path.basename(rec.paths.items[0]));
}

test "copyTree: recurses depth-first in sorted order, mapping paths under dest_root" {
    var h = try Harness.init();
    defer h.deinit();

    try h.writeSrcFile("top.txt");
    try h.writeSrcFile("sub/x.txt");
    try h.writeSrcFile("sub/deeper/y.txt");

    var rec: RecordingSink = .{ .arena = h.arena() };
    try h.run(recording_copy.exclude_none, rec.sink());

    // Subdirectories were created and files landed under dst.
    try testing.expect(h.dstExists("top.txt"));
    try testing.expect(h.dstExists("sub/x.txt"));
    try testing.expect(h.dstExists("sub/deeper/y.txt"));

    // Depth-first in sorted order: "sub" sorts before "top", and within "sub",
    // the file "x.txt" is recursed-into-vs-emitted by name order against "deeper".
    // "deeper" < "x.txt", so deeper/y.txt is emitted before sub/x.txt.
    const dest_root = h.destRoot();
    try testing.expectEqual(@as(usize, 3), rec.paths.items.len);
    try testing.expectEqualStrings(
        std.fs.path.join(h.arena(), &.{ dest_root, "sub", "deeper", "y.txt" }) catch unreachable,
        rec.paths.items[0],
    );
    try testing.expectEqualStrings(
        std.fs.path.join(h.arena(), &.{ dest_root, "sub", "x.txt" }) catch unreachable,
        rec.paths.items[1],
    );
    try testing.expectEqualStrings(
        std.fs.path.join(h.arena(), &.{ dest_root, "top.txt" }) catch unreachable,
        rec.paths.items[2],
    );
}
