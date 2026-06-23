//! Tests for filesystem utilities (zig-clean-room-cli.md Phase 2 fsutil scope):
//! no-follow symlink classification, lexical symlink target resolution,
//! recursive copy that recreates symlinks, and existing-ancestor canonicalize.
//! Safety: everything runs inside a unique temp tree (CLAUDE.md hard rule).

const std = @import("std");
const testing = std.testing;
const fsutil = @import("fsutil.zig");
const testutil = @import("testutil.zig");
const io = std.testing.io;

// --- classify: no-follow entry kind (zig-clean-room-cli.md "statFile follows
// symlinks ... classify by entry.kind"). ---

test "classify: missing entry" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    try testing.expectEqual(fsutil.EntryKind.missing, try fsutil.classify(io, roots.dir(), "nope"));
}

test "classify: regular file" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.strayFile(.claude, "f", "x");
    try testing.expectEqual(fsutil.EntryKind.file, try fsutil.classify(io, roots.dir(), "claude/f"));
}

test "classify: directory" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.realDir(.codex, "d");
    try testing.expectEqual(fsutil.EntryKind.directory, try fsutil.classify(io, roots.dir(), "codex/d"));
}

test "classify: symlink is NOT followed (broken link still classified as symlink)" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.symlink("does/not/exist", "claude/broken");
    try testing.expectEqual(fsutil.EntryKind.symlink, try fsutil.classify(io, roots.dir(), "claude/broken"));
}

test "classify: symlink to a real directory is classified as symlink, not directory" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/beta", "beta", "Beta.");
    try fx.managedSymlink(.claude, "beta", .canonical, "beta");
    try testing.expectEqual(fsutil.EntryKind.symlink, try fsutil.classify(io, roots.dir(), "claude/beta"));
}

// classify documents an else-branch: any entry whose stat kind is not a
// directory, symlink, or regular file is reported as `.file` (fsutil.zig: the
// `else => .file` arm). A FIFO (named pipe) is exactly such an entry. This locks
// the documented behavior so a regression that, e.g., started returning
// `.missing` or erroring for unexpected kinds would FAIL here. mkfifo is libc;
// skip on platforms without it. Safety: the FIFO lives inside the temp tree.
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "classify: FIFO (non-file/non-dir/non-symlink) maps to .file per else-branch" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    try roots.makeRoot(.codex);

    // Absolute, NUL-terminated path to the FIFO inside the isolated temp tree.
    const abs = try std.fs.path.joinZ(testing.allocator, &.{ roots.base, "codex", "fifo" });
    defer testing.allocator.free(abs);

    if (mkfifo(abs.ptr, 0o600) != 0) return error.SkipZigTest;

    // The else-branch of classify reports the FIFO's stat kind as `.file`.
    try testing.expectEqual(
        fsutil.EntryKind.file,
        try fsutil.classify(io, roots.dir(), "codex/fifo"),
    );
}

// --- resolveLinkTarget: lexical resolution via path.resolve, never realpath
// (zig-clean-room-cli.md: "Resolve symlink targets lexically ... never
// realpath"). ---

test "resolveLinkTarget: absolute target returned cleaned" {
    const got = try fsutil.resolveLinkTarget(testing.allocator, "/agents/skills", "/canonical/third-party/x");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/canonical/third-party/x", got);
}

test "resolveLinkTarget: relative target resolved against link's directory" {
    // A managed symlink at /agents/skills/x -> ../../canonical/x resolves
    // lexically to /canonical/x, with no filesystem access.
    const got = try fsutil.resolveLinkTarget(testing.allocator, "/agents/skills", "../../canonical/x");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/canonical/x", got);
}

test "resolveLinkTarget: does not require the target to exist" {
    const got = try fsutil.resolveLinkTarget(testing.allocator, "/nonexistent/dir", "sibling");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/nonexistent/dir/sibling", got);
}

// --- copyTree: recursive copy that RECREATES symlinks (copyFile dereferences,
// zig-clean-room-cli.md fsutil scope). ---

test "copyTree: copies nested files and directories" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    try fx.writeSupportFile("src", "SKILL.md", "skill-body");
    try fx.writeSupportFile("src/lib", "helper.txt", "helper-body");

    var src = try roots.dir().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    try roots.dir().createDirPath(io, "dst");
    var dst = try roots.dir().openDir(io, "dst", .{});
    defer dst.close(io);

    try fsutil.copyTree(io, src, dst);

    const a = try roots.dir().readFileAlloc(io, "dst/SKILL.md", testing.allocator, .unlimited);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("skill-body", a);
    const b = try roots.dir().readFileAlloc(io, "dst/lib/helper.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("helper-body", b);
}

test "copyTree: recreates a symlink entry as a symlink (does not dereference)" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    try fx.writeSupportFile("src", "real.txt", "payload");
    try fx.symlink("real.txt", "src/alias");

    var src = try roots.dir().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    try roots.dir().createDirPath(io, "dst");
    var dst = try roots.dir().openDir(io, "dst", .{});
    defer dst.close(io);

    try fsutil.copyTree(io, src, dst);

    // The copied alias must itself be a symlink (not a dereferenced regular file).
    try testing.expectEqual(fsutil.EntryKind.symlink, try fsutil.classify(io, roots.dir(), "dst/alias"));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try roots.dir().readLink(io, "dst/alias", &buf);
    try testing.expectEqualStrings("real.txt", buf[0..n]);
}

// --- canonicalizeExistingAncestor: hand-rolled (zig-clean-room-cli.md fsutil
// scope). Resolve the nearest existing ancestor with realpath, then re-append
// the not-yet-existing tail lexically. ---

test "canonicalizeExistingAncestor: fully existing path equals realpath" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.realDir(.canonical, "x"); // makes canonical/x on disk

    const abs = try std.fs.path.join(testing.allocator, &.{ roots.base, "canonical", "x" });
    defer testing.allocator.free(abs);

    const got = try fsutil.canonicalizeExistingAncestor(testing.allocator, io, abs);
    defer testing.allocator.free(got);

    const want = try roots.dir().realPathFileAlloc(io, "canonical/x", testing.allocator);
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, got);
}

test "canonicalizeExistingAncestor: appends non-existent tail to canonical ancestor" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    try roots.makeRoot(.imports); // imports/ exists; the skill dir does not yet

    const abs = try std.fs.path.join(testing.allocator, &.{ roots.base, "imports", "new-skill" });
    defer testing.allocator.free(abs);

    const got = try fsutil.canonicalizeExistingAncestor(testing.allocator, io, abs);
    defer testing.allocator.free(got);

    // The existing ancestor (imports/) is canonicalized; the missing tail is
    // appended verbatim.
    const want_anchor = try roots.dir().realPathFileAlloc(io, "imports", testing.allocator);
    defer testing.allocator.free(want_anchor);
    const want = try std.fs.path.join(testing.allocator, &.{ want_anchor, "new-skill" });
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, got);
}
