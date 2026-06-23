//! Tests for root resolution (cli-clean-room-spec.md "Root Resolution").
//!
//! SAFETY (CLAUDE.md hard rule): these tests inject a fake environment and a
//! fake cwd string and NEVER touch real `$HOME`, `~/.claude/skills`,
//! `~/.agents/skills`, or `~/dev/agent-skills`. Runtime-root detection that
//! probes the filesystem is exercised only against a disposable temp tree from
//! `TmpRoots`.

const std = @import("std");
const testing = std.testing;

const roots = @import("roots.zig");
const tu = @import("testutil.zig");

/// A fake environment built from a fixed list of key/value pairs. Keys not in
/// the list are absent (returns null), so a test can prove a default does NOT
/// require `$HOME` simply by omitting it.
const FakeEnv = struct {
    entries: []const [2][]const u8 = &.{},

    fn lookup(self: *FakeEnv) roots.EnvLookup {
        return .{ .getFn = getImpl, .ctx = self };
    }

    fn getImpl(ctx: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        for (self.entries) |e| {
            if (std.mem.eql(u8, e[0], key)) return e[1];
        }
        return null;
    }
};

// spec "Root Resolution": "The CLI must allow each root to be overridden
// explicitly." All four roots provided explicitly must be used verbatim.
test "all roots explicit are used verbatim" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: FakeEnv = .{}; // empty: no HOME, no AGENT_SKILLS_REPO
    const r = roots.resolve(arena, std.testing.io, .{
        .canonical_root = "/x/canonical",
        .imports_root = "/x/imports",
        .claude_code_root = "/x/claude",
        .codex_root = "/x/codex",
    }, env.lookup(), "/some/cwd");

    const got = r.ok;
    try testing.expectEqualStrings("/x/canonical", got.canonical);
    try testing.expectEqualStrings("/x/imports", got.imports);
    try testing.expectEqualStrings("/x/claude", got.claude_code);
    try testing.expectEqualStrings("/x/codex", got.codex);
}

// spec "Root Resolution": "Explicitly providing all roots must not require
// HOME." With all four explicit and HOME unset, resolution must succeed.
test "all roots explicit does not require HOME" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: FakeEnv = .{};
    const r = roots.resolve(arena, std.testing.io, .{
        .canonical_root = "/a",
        .imports_root = "/b",
        .claude_code_root = "/c",
        .codex_root = "/d",
    }, env.lookup(), "/cwd");
    try testing.expect(r.isOk());
}

// spec "Root Resolution": "canonical_root defaults to
// <agent-skills-repo>/third-party" and "agent-skills-repo is AGENT_SKILLS_REPO
// when set". claude/codex default under HOME; imports defaults under runtime
// root (= cwd here, no AGENTS.md ancestor). AGENT_SKILLS_REPO satisfies the
// canonical default without needing HOME for it, but claude/codex still need it.
test "defaults: AGENT_SKILLS_REPO and HOME" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: FakeEnv = .{ .entries = &.{
        .{ "HOME", "/home/u" },
        .{ "AGENT_SKILLS_REPO", "/repos/agent-skills" },
    } };
    const r = roots.resolve(arena, std.testing.io, .{}, env.lookup(), "/work/proj");
    const got = r.ok;
    try testing.expectEqualStrings("/repos/agent-skills/third-party", got.canonical);
    try testing.expectEqualStrings("/work/proj/.skill-importer/imports", got.imports);
    try testing.expectEqualStrings("/home/u/.claude/skills", got.claude_code);
    try testing.expectEqualStrings("/home/u/.agents/skills", got.codex);
}

// spec "Root Resolution": "agent-skills-repo is AGENT_SKILLS_REPO when set,
// otherwise ~/dev/agent-skills." Without AGENT_SKILLS_REPO, canonical derives
// from HOME.
test "defaults: canonical from HOME when AGENT_SKILLS_REPO unset" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: FakeEnv = .{ .entries = &.{
        .{ "HOME", "/home/u" },
    } };
    const r = roots.resolve(arena, std.testing.io, .{}, env.lookup(), "/work/proj");
    const got = r.ok;
    try testing.expectEqualStrings("/home/u/dev/agent-skills/third-party", got.canonical);
    try testing.expectEqualStrings("/home/u/.claude/skills", got.claude_code);
    try testing.expectEqualStrings("/home/u/.agents/skills", got.codex);
}

// spec "Root Resolution": "If a default requires HOME, HOME must be set to an
// absolute path." A default that needs HOME but HOME is unset is an error.
test "missing HOME when a default needs it is an error" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: FakeEnv = .{}; // no HOME at all
    // Override everything EXCEPT claude_code, so the claude default needs HOME.
    const r = roots.resolve(arena, std.testing.io, .{
        .canonical_root = "/a",
        .imports_root = "/b",
        .codex_root = "/d",
    }, env.lookup(), "/cwd");
    try testing.expect(!r.isOk());
}

// spec "Root Resolution": "If a default requires HOME, HOME must be set to an
// absolute path." A relative HOME is rejected.
test "non-absolute HOME is an error when a default needs it" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: FakeEnv = .{ .entries = &.{
        .{ "HOME", "relative/home" },
    } };
    const r = roots.resolve(arena, std.testing.io, .{}, env.lookup(), "/cwd");
    try testing.expect(!r.isOk());
}

// spec "Root Resolution": only the roots whose DEFAULT needs HOME force the
// HOME requirement. With canonical via AGENT_SKILLS_REPO, imports via cwd, and
// claude+codex overridden, no default needs HOME — resolution succeeds without
// it.
test "HOME not required when no surviving default needs it" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: FakeEnv = .{ .entries = &.{
        .{ "AGENT_SKILLS_REPO", "/repo" },
    } };
    const r = roots.resolve(arena, std.testing.io, .{
        .claude_code_root = "/c",
        .codex_root = "/d",
    }, env.lookup(), "/work");
    const got = r.ok;
    try testing.expectEqualStrings("/repo/third-party", got.canonical);
    try testing.expectEqualStrings("/work/.skill-importer/imports", got.imports);
    try testing.expectEqualStrings("/c", got.claude_code);
    try testing.expectEqualStrings("/d", got.codex);
}

// spec "Root Resolution": "runtime-root is the nearest ancestor of the current
// working directory that contains both AGENTS.md and catalog/portable/. If no
// such ancestor exists, runtime-root is the current working directory."
// Build a disposable tree <tmp>/proj with AGENTS.md + catalog/portable/, then a
// nested cwd <tmp>/proj/a/b; imports must resolve under <tmp>/proj.
test "runtime-root: nearest ancestor with AGENTS.md and catalog/portable" {
    const a = testing.allocator;
    var tr = try tu.TmpRoots.init(a);
    defer tr.deinit();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = tr.base; // absolute path of the temp tree
    const proj = try std.fs.path.join(arena, &.{ base, "proj" });
    // Create proj/AGENTS.md and proj/catalog/portable/, plus nested proj/a/b.
    try tr.dir().createDirPath(std.testing.io, "proj/catalog/portable");
    try tr.dir().createDirPath(std.testing.io, "proj/a/b");
    {
        const f = try tr.dir().createFile(std.testing.io, "proj/AGENTS.md", .{});
        f.close(std.testing.io);
    }
    const cwd = try std.fs.path.join(arena, &.{ proj, "a", "b" });

    var env: FakeEnv = .{ .entries = &.{
        .{ "HOME", "/home/u" },
        .{ "AGENT_SKILLS_REPO", "/repo" },
    } };
    const r = roots.resolve(arena, std.testing.io, .{}, env.lookup(), cwd);
    const got = r.ok;
    const expected = try std.fs.path.join(arena, &.{ proj, ".skill-importer/imports" });
    try testing.expectEqualStrings(expected, got.imports);
}

// spec "Root Resolution": "If no such ancestor exists, runtime-root is the
// current working directory." A cwd with no qualifying ancestor uses cwd itself.
test "runtime-root: falls back to cwd when no qualifying ancestor" {
    const a = testing.allocator;
    var tr = try tu.TmpRoots.init(a);
    defer tr.deinit();
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A plain nested dir with NO AGENTS.md / catalog/portable anywhere above.
    try tr.dir().createDirPath(std.testing.io, "plain/x/y");
    const cwd = try std.fs.path.join(arena, &.{ tr.base, "plain/x/y" });

    var env: FakeEnv = .{ .entries = &.{
        .{ "AGENT_SKILLS_REPO", "/repo" },
    } };
    const r = roots.resolve(arena, std.testing.io, .{
        .claude_code_root = "/c",
        .codex_root = "/d",
    }, env.lookup(), cwd);
    const got = r.ok;
    const expected = try std.fs.path.join(arena, &.{ cwd, ".skill-importer/imports" });
    try testing.expectEqualStrings(expected, got.imports);
}
