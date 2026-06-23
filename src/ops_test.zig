//! Tests for ops.zig enable / disable (cli-clean-room-spec.md "enable",
//! "disable", "Filesystem Safety", "JSON Schemas > Skill Operation Result").
//! Covers the spec "Recommended TDD Acceptance Suite" bullet 8: idempotence,
//! agent order, duplicate agents, each unsafe-entry class, unknown skill,
//! agent-only, unpromoted (enable rejects), atomic multi-agent preflight (a
//! later unsafe entry leaves an earlier agent untouched).
//!
//! Safety: every test runs inside a unique temp tree (CLAUDE.md hard rule); no
//! real user root is ever touched.

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const ops = @import("ops.zig");
const types = @import("types.zig");
const result = @import("result.zig");
const testutil = @import("testutil.zig");

// --- harness ---------------------------------------------------------------

const Harness = struct {
    roots: testutil.TmpRoots,
    arena_state: std.heap.ArenaAllocator,

    fn init() !Harness {
        return .{
            .roots = try testutil.TmpRoots.init(testing.allocator),
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
        self.roots.deinit();
    }

    fn arena(self: *Harness) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn fixtures(self: *Harness) testutil.Fixtures {
        return testutil.Fixtures.init(&self.roots);
    }

    fn ctx(self: *Harness) ops.Context {
        return .{
            .arena = self.arena(),
            .io = io,
            .canonical_root = self.roots.canonical,
            .imports_root = self.roots.imports,
            .claude_code_root = self.roots.claude,
            .codex_root = self.roots.codex,
        };
    }
};

// --- assertion helpers -----------------------------------------------------

fn expectErrKind(res: result.Result(types.SkillOperationResult), kind: result.ErrorKind) !void {
    switch (res) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(kind, e.kind),
    }
}

fn expectOk(res: result.Result(types.SkillOperationResult)) !types.SkillOperationResult {
    switch (res) {
        .ok => |r| return r,
        .err => |e| {
            std.debug.print("unexpected error: {any}\n", .{e.kind});
            return error.ExpectedOk;
        },
    }
}

/// No-follow entry kind of `rel` under the temp base; missing => null.
fn entryKind(h: *Harness, rel: []const u8) !?std.Io.File.Kind {
    const st = h.roots.dir().statFile(io, rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return st.kind;
}

/// Read the absolute symlink target of `rel` under the temp base.
fn linkTarget(h: *Harness, rel: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try h.roots.dir().readLink(io, rel, &buf);
    return h.arena().dupe(u8, buf[0..n]);
}

/// Absolute canonical-copy path `<canonical>/<name>`.
fn canonicalPath(h: *Harness, name: []const u8) ![]u8 {
    return std.fs.path.join(h.arena(), &.{ h.roots.canonical, name });
}

// --- unknown / agent-only / unpromoted (spec "enable"/"disable") -----------

test "enable: unknown skill fails (spec enable: Unknown skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();
    try expectErrKind(ops.enable(&c, "nope", &.{.claude_code}), .unknown_skill);
}

test "enable: agent-only skill fails (spec enable: Agent-only skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    // A skill present only via an agent-root directory entry => agent_only.
    try h.fixtures().realDir(.claude, "ghost");
    var c = h.ctx();
    try expectErrKind(ops.enable(&c, "ghost", &.{.codex}), .agent_only_skill);
}

test "enable: unpromoted import fails (spec enable: Unpromoted imports fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/draft", "draft", "Draft.");
    try h.fixtures().writeManifest("imports/draft", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = false,
    });
    var c = h.ctx();
    try expectErrKind(ops.enable(&c, "draft", &.{.claude_code}), .not_promoted);
}

// --- on-disk directory name differs from frontmatter name (Finding #7) ------
// A canonical skill discovered as `cool` (frontmatter name) lives in a directory
// named `weird-dir`. enable must symlink to the REAL on-disk directory
// `<canonical>/weird-dir`, not `<canonical>/cool` (which does not exist).
// A symlink to a non-existent target is a dangling/broken link reported as
// success — the bug. The fix resolves the target from the on-disk directory.

test "enable: canonical skill whose dir name differs from frontmatter name links to the real dir (Finding #7)" {
    var h = try Harness.init();
    defer h.deinit();
    // On-disk dir `weird-dir`, frontmatter name `cool` => discovered as `cool`.
    try h.fixtures().writeSkill("canonical/weird-dir", "cool", "Cool.");
    var c = h.ctx();

    const r = try expectOk(ops.enable(&c, "cool", &.{.claude_code}));

    // The managed symlink lives at <claude>/cool (keyed by skill name) but must
    // TARGET the real on-disk dir <canonical>/weird-dir.
    const target = try linkTarget(&h, "claude/cool");
    try testing.expectEqualStrings(try canonicalPath(&h, "weird-dir"), target);
    // The recorded create_symlink action target matches.
    try testing.expectEqual(types.SkillActionKind.create_symlink, r.actions[r.actions.len - 1].action);
    try testing.expectEqualStrings(try canonicalPath(&h, "weird-dir"), r.actions[r.actions.len - 1].target.?);

    // Crucially the link resolves to a REAL directory (not dangling): following
    // it must reach the SKILL.md that we wrote.
    const followed = try h.roots.dir().statFile(io, "claude/cool", .{ .follow_symlinks = true });
    try testing.expect(followed.kind == .directory);
    const md = try readFileVia(&h, "claude/cool/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, md, "name: cool") != null);
}

/// Read a file `rel` (following symlinks) under the temp base into the arena.
fn readFileVia(h: *Harness, rel: []const u8) ![]u8 {
    return h.roots.dir().readFileAlloc(io, rel, h.arena(), .unlimited);
}

// --- enable missing -> create root + symlink to canonical copy -------------

test "enable: missing entry creates agent root + symlink to canonical copy (spec enable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/alpha", "alpha", "Alpha.");
    var c = h.ctx();

    const res = ops.enable(&c, "alpha", &.{.claude_code});
    const r = try expectOk(res);

    // claude root + symlink created; symlink target is the CANONICAL copy, not a
    // draft (spec "enable": link to canonical promoted copy).
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/alpha")).?);
    const target = try linkTarget(&h, "claude/alpha");
    try testing.expectEqualStrings(try canonicalPath(&h, "alpha"), target);

    // Action list records create_directory BEFORE create_symlink.
    try testing.expectEqual(@as(usize, 2), r.actions.len);
    try testing.expectEqual(types.SkillActionKind.create_directory, r.actions[0].action);
    try testing.expectEqual(types.SkillActionKind.create_symlink, r.actions[1].action);
    try testing.expectEqual(types.Agent.claude_code, r.actions[1].agent.?);
    try testing.expectEqualStrings(try canonicalPath(&h, "alpha"), r.actions[1].target.?);
}

test "enable: promoted import links to canonical copy, not draft (spec enable)" {
    var h = try Harness.init();
    defer h.deinit();
    // Promoted import: present in BOTH imports (draft) and canonical (promoted
    // copy), manifest promoted=true.
    try h.fixtures().writeSkill("imports/beta", "beta", "Beta.");
    try h.fixtures().writeManifest("imports/beta", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/beta", "beta", "Beta.");
    var c = h.ctx();

    const r = try expectOk(ops.enable(&c, "beta", &.{.codex}));
    const target = try linkTarget(&h, "codex/beta");
    // Target is the canonical copy, NOT the imports draft.
    try testing.expectEqualStrings(try canonicalPath(&h, "beta"), target);
    try testing.expect(std.mem.indexOf(u8, target, "imports") == null);
    _ = r;
}

// --- enable into a PRE-EXISTING agent root (no spurious create_directory) ---

test "enable: existing agent root, missing entry => only create_symlink (spec enable: create the agent root IF NEEDED)" {
    // spec "enable": "If an agent entry is missing, create the agent root if
    // needed and create a symlink." When the root already exists, create_directory
    // must NOT be emitted; only create_symlink.
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/one", "one", "One.");
    try h.fixtures().writeSkill("canonical/two", "two", "Two.");
    var c = h.ctx();

    // First enable creates the claude root (and links "one").
    _ = try expectOk(ops.enable(&c, "one", &.{.claude_code}));
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "claude")).?);

    // Second enable of a DIFFERENT skill into the now-existing root must emit
    // ONLY create_symlink (no spurious create_directory).
    const r = try expectOk(ops.enable(&c, "two", &.{.claude_code}));
    try testing.expectEqual(@as(usize, 1), r.actions.len);
    try testing.expectEqual(types.SkillActionKind.create_symlink, r.actions[0].action);
    try testing.expectEqualStrings(try canonicalPath(&h, "two"), r.actions[0].target.?);
}

// --- enable idempotence (already-correct -> skip_unchanged) ----------------

test "enable: already-correct symlink returns skip_unchanged (spec enable idempotence)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/gamma", "gamma", "Gamma.");
    var c = h.ctx();

    // First enable creates the symlink.
    _ = try expectOk(ops.enable(&c, "gamma", &.{.claude_code}));
    // Second enable is idempotent: skip_unchanged, no new mutation.
    const r = try expectOk(ops.enable(&c, "gamma", &.{.claude_code}));
    try testing.expectEqual(@as(usize, 1), r.actions.len);
    try testing.expectEqual(types.SkillActionKind.skip_unchanged, r.actions[0].action);
    // The link still points at the canonical copy.
    try testing.expectEqualStrings(try canonicalPath(&h, "gamma"), try linkTarget(&h, "claude/gamma"));
}

// --- enable agent order + duplicate agents (spec enable) -------------------

test "enable: agents honored in order and deduplicated first-seen (spec enable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/delta", "delta", "Delta.");
    var c = h.ctx();

    // Duplicate codex; order codex, claude-code, codex => deduped [codex, claude].
    const r = try expectOk(ops.enable(&c, "delta", &.{ .codex, .claude_code, .codex }));

    // Both agents linked; each with exactly one create_symlink (+ root create).
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "codex/delta")).?);
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/delta")).?);

    // Collect create_symlink actions in order; first-seen order is codex then
    // claude_code, with no third (duplicate) symlink.
    var symlink_agents: std.ArrayList(types.Agent) = .empty;
    for (r.actions) |a| {
        if (a.action == .create_symlink) try symlink_agents.append(h.arena(), a.agent.?);
    }
    try testing.expectEqual(@as(usize, 2), symlink_agents.items.len);
    try testing.expectEqual(types.Agent.codex, symlink_agents.items[0]);
    try testing.expectEqual(types.Agent.claude_code, symlink_agents.items[1]);
}

// --- enable unsafe-entry classes (each is rejected, left untouched) --------

test "enable: real directory entry is unsafe and untouched (spec enable/Filesystem Safety)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/eps", "eps", "Eps.");
    try h.fixtures().realDir(.claude, "eps"); // real dir already occupies the slot
    var c = h.ctx();

    try expectErrKind(ops.enable(&c, "eps", &.{.claude_code}), .unsafe_agent_entry);
    // Still a real directory, NOT replaced with a symlink (spec: left untouched).
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "claude/eps")).?);
}

test "enable: stray regular file entry is unsafe and untouched (spec enable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/zeta", "zeta", "Zeta.");
    try h.fixtures().strayFile(.claude, "zeta", "junk");
    var c = h.ctx();

    try expectErrKind(ops.enable(&c, "zeta", &.{.claude_code}), .unsafe_agent_entry);
    try testing.expectEqual(std.Io.File.Kind.file, (try entryKind(&h, "claude/zeta")).?);
}

test "enable: broken symlink entry is unsafe and untouched (spec enable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/eta", "eta", "Eta.");
    try h.fixtures().symlink("does/not/exist", "claude/eta");
    var c = h.ctx();

    try expectErrKind(ops.enable(&c, "eta", &.{.claude_code}), .unsafe_agent_entry);
    // Still the same broken symlink.
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/eta")).?);
    try testing.expectError(error.FileNotFound, h.roots.dir().statFile(io, "claude/eta", .{ .follow_symlinks = true }));
}

test "enable: external symlink entry is unsafe and untouched (spec enable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/theta", "theta", "Theta.");
    // Symlink to a real but external (outside managed roots) target.
    try h.fixtures().strayFile(.claude, "external-target", "x");
    try h.fixtures().symlink("external-target", "claude/theta");
    var c = h.ctx();

    try expectErrKind(ops.enable(&c, "theta", &.{.claude_code}), .unsafe_agent_entry);
    const target = try linkTarget(&h, "claude/theta");
    try testing.expectEqualStrings("external-target", target);
}

test "enable: symlink to WRONG managed target is unsafe and untouched (spec enable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/iota", "iota", "Iota.");
    // Another canonical skill that the link wrongly points at.
    try h.fixtures().writeSkill("canonical/other", "other", "Other.");
    try h.fixtures().managedSymlink(.claude, "iota", .canonical, "other");
    var c = h.ctx();

    try expectErrKind(ops.enable(&c, "iota", &.{.claude_code}), .unsafe_agent_entry);
    // Untouched: still points at "other".
    const target = try linkTarget(&h, "claude/iota");
    try testing.expectEqualStrings(try canonicalPath(&h, "other"), target);
}

// --- atomic multi-agent preflight (later unsafe => earlier untouched) ------

test "enable: a later unsafe agent leaves the earlier agent untouched (spec Filesystem Safety)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/kappa", "kappa", "Kappa.");
    // codex is requested SECOND and has an unsafe real-dir entry; claude-code is
    // requested first and must NOT be mutated.
    try h.fixtures().realDir(.codex, "kappa");
    var c = h.ctx();

    try expectErrKind(ops.enable(&c, "kappa", &.{ .claude_code, .codex }), .unsafe_agent_entry);

    // claude-code slot is still empty (no symlink created): preflight rejected
    // BEFORE any mutation (spec: "no earlier agent may be mutated").
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "claude/kappa"));
    // codex still its unsafe directory.
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "codex/kappa")).?);
}

// --- disable -------------------------------------------------------------

test "disable: removes the correct managed symlink (spec disable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/lam", "lam", "Lam.");
    try h.fixtures().managedSymlink(.claude, "lam", .canonical, "lam");
    var c = h.ctx();

    const r = try expectOk(ops.disable(&c, "lam", &.{.claude_code}));
    try testing.expectEqual(@as(usize, 1), r.actions.len);
    try testing.expectEqual(types.SkillActionKind.remove_symlink, r.actions[0].action);
    // The symlink is gone.
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "claude/lam"));
}

test "disable: missing entry returns skip_unchanged (spec disable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/mu", "mu", "Mu.");
    var c = h.ctx();

    const r = try expectOk(ops.disable(&c, "mu", &.{.claude_code}));
    try testing.expectEqual(@as(usize, 1), r.actions.len);
    try testing.expectEqual(types.SkillActionKind.skip_unchanged, r.actions[0].action);
}

test "disable: unsafe entry fails and is left untouched (spec disable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/nu", "nu", "Nu.");
    try h.fixtures().strayFile(.claude, "nu", "junk"); // real file in the slot
    var c = h.ctx();

    try expectErrKind(ops.disable(&c, "nu", &.{.claude_code}), .unsafe_agent_entry);
    try testing.expectEqual(std.Io.File.Kind.file, (try entryKind(&h, "claude/nu")).?);
}

test "disable: external symlink is unsafe and untouched (spec disable)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/xi", "xi", "Xi.");
    try h.fixtures().strayFile(.claude, "ext-target", "x");
    try h.fixtures().symlink("ext-target", "claude/xi");
    var c = h.ctx();

    try expectErrKind(ops.disable(&c, "xi", &.{.claude_code}), .unsafe_agent_entry);
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/xi")).?);
}

test "disable: allows legacy enabled unpromoted import via imported symlink (spec disable)" {
    var h = try Harness.init();
    defer h.deinit();
    // Unpromoted import enabled the legacy way: a managed symlink to the imports
    // draft directory. disable must remove it (spec "disable": "legacy enabled
    // unpromoted imports may be disabled").
    try h.fixtures().writeSkill("imports/leg", "leg", "Legacy.");
    try h.fixtures().writeManifest("imports/leg", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = false,
    });
    try h.fixtures().managedSymlink(.claude, "leg", .imports, "leg");
    var c = h.ctx();

    const r = try expectOk(ops.disable(&c, "leg", &.{.claude_code}));
    try testing.expectEqual(types.SkillActionKind.remove_symlink, r.actions[0].action);
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "claude/leg"));
}

test "disable: agent-only skill fails (spec disable: Agent-only skills fail.)" {
    // spec "disable": "Agent-only skills fail." Mirrors the enable case: a skill
    // present ONLY via an agent-root directory entry resolves to agent_only and
    // must be rejected, not treated as a disable target.
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().realDir(.claude, "ghost");
    var c = h.ctx();
    try expectErrKind(ops.disable(&c, "ghost", &.{.codex}), .agent_only_skill);
}

test "disable: unknown skill fails (spec disable: Unknown skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();
    try expectErrKind(ops.disable(&c, "nope", &.{.claude_code}), .unknown_skill);
}

test "disable: later unsafe agent leaves earlier managed symlink untouched (spec Filesystem Safety)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/omi", "omi", "Omicron.");
    try h.fixtures().managedSymlink(.claude, "omi", .canonical, "omi");
    try h.fixtures().strayFile(.codex, "omi", "junk"); // codex unsafe, requested 2nd
    var c = h.ctx();

    try expectErrKind(ops.disable(&c, "omi", &.{ .claude_code, .codex }), .unsafe_agent_entry);
    // claude-code's managed symlink is still present (not removed before the
    // later-agent preflight failure).
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/omi")).?);
}

// --- disable: a BROKEN managed symlink is UNSAFE and must be left untouched
// (Finding #8). spec "disable": "If the agent entry is the correct managed
// symlink, remove it." + "Unsafe entries are rejected and left untouched."
// spec "Terms"/"enable": a broken symlink is an External entry / unsafe entry.
// A managed symlink whose target dir (here the imports draft) does NOT exist is
// broken; disable must NOT remove it just because the lexical target matches. ---

test "disable: broken managed symlink is unsafe and left on disk (spec disable, Finding #8)" {
    var h = try Harness.init();
    defer h.deinit();
    // The skill is discoverable via canonical (so disable resolves it), but the
    // agent entry is a managed symlink pointing at the imports DRAFT dir which
    // does NOT exist on disk => a broken symlink (discovery: broken_symlink).
    try h.fixtures().writeSkill("canonical/brk", "brk", "Broken-link target.");
    // claude/brk -> <imports>/brk, and <imports>/brk is never created.
    try h.fixtures().managedSymlink(.claude, "brk", .imports, "brk");
    var c = h.ctx();

    // disable must REJECT the broken symlink as unsafe, not remove it.
    try expectErrKind(ops.disable(&c, "brk", &.{.claude_code}), .unsafe_agent_entry);

    // The broken symlink is still on disk, untouched, and still dangling.
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/brk")).?);
    try testing.expectError(error.FileNotFound, h.roots.dir().statFile(io, "claude/brk", .{ .follow_symlinks = true }));
}
