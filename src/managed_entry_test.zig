//! Tests for the managed-entry classifier (src/managed_entry.zig). This is the
//! unit-level test surface for the filesystem-safety policy that discovery and
//! ops both consume — it covers the no-follow classify, resolvable-symlink target
//! canonicalization, the component-aware `isInside` membership test, and the
//! broken-link policy (Finding #9) directly, rather than only through whole-
//! operation tests.
//!
//! Safety: every test runs inside a unique temp tree (CLAUDE.md hard rule); no
//! helper here ever touches a real user root.

const std = @import("std");
const testing = std.testing;
const managed_entry = @import("managed_entry.zig");
const testutil = @import("testutil.zig");
const io = std.testing.io;

/// Absolute path of `rel` under the temp base.
fn abs(roots: *testutil.TmpRoots, rel: []const u8) ![]u8 {
    return std.fs.path.join(testing.allocator, &.{ roots.base, rel });
}

// --- Step 1: classify happy (non-symlink) kinds ----------------------------

test "classify: missing path => .missing" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try abs(&roots, "claude/nope");
    defer testing.allocator.free(path);

    const c = try managed_entry.classify(arena, io, path);
    try testing.expectEqual(managed_entry.Classification.missing, c);
}

test "classify: real directory => .real_directory" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.realDir(.codex, "d");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try abs(&roots, "codex/d");
    defer testing.allocator.free(path);

    const c = try managed_entry.classify(arena, io, path);
    try testing.expectEqual(managed_entry.Classification.real_directory, c);
}

test "classify: real file => .real_file" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.strayFile(.claude, "f", "x");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try abs(&roots, "claude/f");
    defer testing.allocator.free(path);

    const c = try managed_entry.classify(arena, io, path);
    try testing.expectEqual(managed_entry.Classification.real_file, c);
}

// --- Step 2: resolvable symlinks + isInside + canonicalize -----------------

test "classify: symlink to a dir inside the canonical root => .symlink isInside(canonical)" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/beta", "beta", "Beta.");
    try fx.managedSymlink(.claude, "beta", .canonical, "beta");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try abs(&roots, "claude/beta");
    defer testing.allocator.free(path);

    const c = try managed_entry.classify(arena, io, path);
    const target = switch (c) {
        .symlink => |t| t,
        else => return error.ExpectedSymlink,
    };
    const canon = try managed_entry.canonicalize(arena, io, roots.canonical);
    const imports = try managed_entry.canonicalize(arena, io, roots.imports);
    try testing.expect(managed_entry.isInside(target, canon));
    try testing.expect(!managed_entry.isInside(target, imports));
}

test "classify: symlink to a dir inside the imports root => .symlink isInside(imports)" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("imports/gamma", "gamma", "Gamma.");
    try fx.managedSymlink(.codex, "gamma", .imports, "gamma");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try abs(&roots, "codex/gamma");
    defer testing.allocator.free(path);

    const c = try managed_entry.classify(arena, io, path);
    const target = switch (c) {
        .symlink => |t| t,
        else => return error.ExpectedSymlink,
    };
    const canon = try managed_entry.canonicalize(arena, io, roots.canonical);
    const imports = try managed_entry.canonicalize(arena, io, roots.imports);
    try testing.expect(managed_entry.isInside(target, imports));
    try testing.expect(!managed_entry.isInside(target, canon));
}

test "classify: symlink to a target outside all roots => isInside false for both" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    // A real external target outside any managed root, and a symlink to it.
    try fx.writeSupportFile("outside/thing", "SKILL.md", "x");
    try roots.makeRoot(.claude);
    const ext_target = try abs(&roots, "outside/thing");
    defer testing.allocator.free(ext_target);
    try fx.symlink(ext_target, "claude/ext");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try abs(&roots, "claude/ext");
    defer testing.allocator.free(path);

    const c = try managed_entry.classify(arena, io, path);
    const target = switch (c) {
        .symlink => |t| t,
        else => return error.ExpectedSymlink,
    };
    const canon = try managed_entry.canonicalize(arena, io, roots.canonical);
    const imports = try managed_entry.canonicalize(arena, io, roots.imports);
    try testing.expect(!managed_entry.isInside(target, canon));
    try testing.expect(!managed_entry.isInside(target, imports));
}

// Sibling-prefix trap (component-aware isInside): a symlink to `<canonical>-evil`
// shares the textual prefix `<canonical>` but is a SIBLING, not inside it. A
// naive startsWith would misclassify it as canonical_symlink (mirrors
// analyzer.pathWithin and the discovery classifier).
test "classify: symlink to a sibling-prefix dir is NOT inside the canonical root" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try roots.makeRoot(.canonical);
    // `<base>/canonical-evil/beta` — a real dir whose absolute path starts with
    // the canonical root's path plus "-evil".
    try fx.writeSupportFile("canonical-evil/beta", "SKILL.md", "x");
    try roots.makeRoot(.claude);
    const evil_target = try abs(&roots, "canonical-evil/beta");
    defer testing.allocator.free(evil_target);
    try fx.symlink(evil_target, "claude/beta");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try abs(&roots, "claude/beta");
    defer testing.allocator.free(path);

    const c = try managed_entry.classify(arena, io, path);
    const target = switch (c) {
        .symlink => |t| t,
        else => return error.ExpectedSymlink,
    };
    const canon = try managed_entry.canonicalize(arena, io, roots.canonical);
    try testing.expect(!managed_entry.isInside(target, canon));
}

// isInside is component-aware: equal path, strict descendant, and the
// sibling-prefix / partial-component traps. Pure function, no filesystem.
test "isInside: equality, descendant, and prefix traps" {
    try testing.expect(managed_entry.isInside("/a/b", "/a/b")); // root itself
    try testing.expect(managed_entry.isInside("/a/b/c", "/a/b")); // strict descendant
    try testing.expect(managed_entry.isInside("/a/b/c/d", "/a/b")); // deep descendant
    try testing.expect(!managed_entry.isInside("/a/b-evil", "/a/b")); // sibling prefix
    try testing.expect(!managed_entry.isInside("/a/bc", "/a/b")); // partial component
    try testing.expect(!managed_entry.isInside("/a", "/a/b")); // ancestor, not inside
    try testing.expect(!managed_entry.isInside("/x/y", "/a/b")); // unrelated
}

test "canonicalize: a fully non-existent path is resolved lexically" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A path whose trailing components do not exist canonicalizes to the same
    // absolute spelling (the existing ancestor — here `/` — is realpath'd and the
    // missing tail re-appended), with no filesystem dereference and no crash.
    const got = try managed_entry.canonicalize(arena, io, "/nonexistent/dir/x");
    try testing.expectEqualStrings("/nonexistent/dir/x", got);
}

test "canonicalize: a path reached through a symlinked ancestor is realpath'd" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();

    // Real tree under <base>/real; `link` -> `real`. A path spelled through the
    // symlinked `link` ancestor must canonicalize to the realpath'd `real` form.
    try roots.dir().createDirPath(io, "real/sub");
    try roots.dir().symLink(io, "real", "link", .{});

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const through_link = try abs(&roots, "link/sub");
    defer testing.allocator.free(through_link);
    const got = try managed_entry.canonicalize(arena, io, through_link);

    const want = try roots.dir().realPathFileAlloc(io, "real/sub", testing.allocator);
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, got);
}

// --- Step 3: broken-link policy (Finding #9) -------------------------------
// A symlink whose target cannot be resolved is `.broken_symlink`, never a
// resolvable `.symlink` (which could land outside the roots => External). This is
// the unit-level home for Finding #9, previously only covered via discovery_test.

test "classify: dangling symlink (target removed) => .broken_symlink" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.symlink("does/not/exist", "claude/ghost");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try abs(&roots, "claude/ghost");
    defer testing.allocator.free(path);

    const c = try managed_entry.classify(arena, io, path);
    try testing.expectEqual(managed_entry.Classification.broken_symlink, c);
}

test "classify: symlink loop (resolve error, not FileNotFound) => .broken_symlink" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    // A self-referential symlink: following it yields error.SymLinkLoop, NOT
    // FileNotFound. Any resolve error => broken (never misreported as External).
    try fx.symlink("loopy", "claude/loopy");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try abs(&roots, "claude/loopy");
    defer testing.allocator.free(path);

    const c = try managed_entry.classify(arena, io, path);
    try testing.expectEqual(managed_entry.Classification.broken_symlink, c);
}
