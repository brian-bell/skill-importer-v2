//! Tests for ops.zig promote / unpromote / delete (cli-clean-room-spec.md
//! "promote", "unpromote", "delete", "Collision Rules", "Filesystem Safety",
//! "JSON Schemas > Skill Operation Result").
//!
//! Covers the spec "Recommended TDD Acceptance Suite" bullets 9-11:
//!   - promote: support-file copy, manifest update, import.json exclusion,
//!     relink, canonical collision, overwrite (same/different name), unsafe agent
//!     entry, unsupported import entry, already-promoted;
//!   - unpromote: remove canonical copy + managed agent symlinks + manifest
//!     update, invalid source states;
//!   - delete: success, promoted/enabled block, canonical/agent-only errors,
//!     preserve unrelated same-name agent entries.
//!
//! Safety: every test runs inside a unique temp tree (CLAUDE.md hard rule); no
//! real user root is ever touched.

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const ops = @import("ops.zig");
const types = @import("types.zig");
const result = @import("result.zig");
const manifest_mod = @import("manifest.zig");
const frontmatter = @import("frontmatter.zig");
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

/// Return the ErrorInfo of an expected-error result so a test can inspect its
/// `kind`, `path`, and `partial_actions` (spec "Filesystem Safety": a partially
/// completed operation should report the actions that completed).
fn expectErr(res: result.Result(types.SkillOperationResult)) !result.ErrorInfo {
    switch (res) {
        .ok => return error.ExpectedError,
        .err => |e| return e,
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

/// Read the bytes of a file `rel` under the temp base.
fn readFile(h: *Harness, rel: []const u8) ![]u8 {
    return h.roots.dir().readFileAlloc(io, rel, h.arena(), .unlimited);
}

/// Parse the import manifest at `<rel_dir>/import.json` under the temp base.
fn readManifest(h: *Harness, rel_dir: []const u8) !types.ImportManifest {
    const path = try std.fs.path.join(h.arena(), &.{ rel_dir, "import.json" });
    const bytes = try readFile(h, path);
    var parsed = try manifest_mod.parse(h.arena(), bytes);
    defer parsed.deinit();
    return .{
        .source_type = parsed.value.source_type,
        .source_location = if (parsed.value.source_location) |s| try h.arena().dupe(u8, s) else null,
        .source_repository = null,
        .imported_at = parsed.value.imported_at,
        .content_hash = try h.arena().dupe(u8, parsed.value.content_hash),
        .promoted = parsed.value.promoted,
    };
}

/// Write a standard unpromoted draft import at `imports/<name>` with the given
/// frontmatter name + description.
fn draft(h: *Harness, dir_name: []const u8, fm_name: []const u8, desc: []const u8) !void {
    const rel = try std.fs.path.join(h.arena(), &.{ "imports", dir_name });
    try h.fixtures().writeSkill(rel, fm_name, desc);
    try h.fixtures().writeManifest(rel, .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = false,
    });
}

// ===========================================================================
// promote
// ===========================================================================

// --- on-disk directory name differs from frontmatter name (Finding #7) ------
// An imported draft discovered as `cool` (frontmatter name) lives in a directory
// named `weird-import`. promote must read the import content from the REAL
// on-disk dir `<imports>/weird-import`, not `<imports>/cool` (which does not
// exist). Under the buggy code promote tries `<imports>/cool` and fails to find
// the source. The canonical destination is still keyed by skill name.

test "promote: imported draft whose dir name differs from frontmatter name promotes from the real dir (Finding #7)" {
    var h = try Harness.init();
    defer h.deinit();
    // On-disk dir `weird-import`, frontmatter name `cool` => discovered as `cool`.
    try draft(&h, "weird-import", "cool", "Cool draft.");
    try h.fixtures().writeSupportFile("imports/weird-import", "helper.txt", "support-data");
    var c = h.ctx();

    const r = try expectOk(ops.promote(&c, "cool", false));
    try testing.expectEqualStrings("cool", r.skill_name);

    // Canonical copy is keyed by skill name and carries the real content + support
    // files copied from the on-disk import dir.
    const skill = try readFile(&h, "canonical/cool/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "name: cool") != null);
    try testing.expectEqualStrings("support-data", try readFile(&h, "canonical/cool/helper.txt"));

    // The draft manifest in the REAL import dir is flipped to promoted=true.
    const man = try readManifest(&h, "imports/weird-import");
    try testing.expect(man.promoted);
}

test "unpromote: promoted import whose dir name differs from frontmatter name flips the real dir manifest (Finding #7)" {
    var h = try Harness.init();
    defer h.deinit();
    // On-disk import dir `weird-import` (frontmatter name `cool`), already promoted
    // with a canonical copy at <canonical>/cool.
    const rel = try std.fs.path.join(h.arena(), &.{ "imports", "weird-import" });
    try h.fixtures().writeSkill(rel, "cool", "Cool draft.");
    try h.fixtures().writeManifest(rel, .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/cool", "cool", "Cool promoted.");
    var c = h.ctx();

    _ = try expectOk(ops.unpromote(&c, "cool"));

    // Canonical copy removed; the REAL import dir's manifest flipped to false.
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/cool"));
    const man = try readManifest(&h, "imports/weird-import");
    try testing.expect(!man.promoted);
}

// --- error paths -----------------------------------------------------------

test "promote: unknown skill fails (spec promote: Unknown skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();
    try expectErrKind(ops.promote(&c, "nope", false), .unknown_skill);
}

test "promote: canonical-only skill fails (spec promote: Canonical skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/can", "can", "Canonical.");
    var c = h.ctx();
    try expectErrKind(ops.promote(&c, "can", false), .canonical_only_skill);
}

test "promote: agent-only skill fails (spec promote: agent-only skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().realDir(.claude, "ghost");
    var c = h.ctx();
    try expectErrKind(ops.promote(&c, "ghost", false), .agent_only_skill);
}

test "promote: already-promoted import fails (spec promote: Already promoted imports fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/beta", "beta", "Beta.");
    try h.fixtures().writeManifest("imports/beta", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/beta", "beta", "Beta.");
    var c = h.ctx();
    try expectErrKind(ops.promote(&c, "beta", false), .already_promoted);
}

test "promote: existing canonical destination fails without --overwrite (spec promote)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "alpha", "alpha", "Draft alpha.");
    // A pre-existing canonical entry of the same name (e.g. a prior promotion of
    // a different draft) blocks promotion unless --overwrite (spec promote +
    // "Collision Rules": refuse canonical collisions unless overwrite explicit).
    try h.fixtures().writeSkill("canonical/alpha", "alpha", "Existing alpha.");
    var c = h.ctx();
    try expectErrKind(ops.promote(&c, "alpha", false), .canonical_collision);
}

// --- happy path: copy content, exclude import.json, manifest=true ----------

test "promote: copies SKILL.md + support files, excludes import.json, sets manifest promoted=true (spec promote)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "gamma", "gamma", "Gamma draft.");
    try h.fixtures().writeSupportFile("imports/gamma", "helper.txt", "support-data");
    try h.fixtures().writeSupportFile("imports/gamma/sub", "nested.txt", "nested-data");
    var c = h.ctx();

    const r = try expectOk(ops.promote(&c, "gamma", false));
    try testing.expectEqualStrings("gamma", r.skill_name);

    // Canonical copy exists with SKILL.md and support files.
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "canonical/gamma")).?);
    const skill = try readFile(&h, "canonical/gamma/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "name: gamma") != null);
    try testing.expectEqualStrings("support-data", try readFile(&h, "canonical/gamma/helper.txt"));
    try testing.expectEqualStrings("nested-data", try readFile(&h, "canonical/gamma/sub/nested.txt"));

    // import.json is NOT copied into canonical (spec: excludes top-level import.json).
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/gamma/import.json"));

    // Draft manifest promoted flag flipped to true (spec promote).
    const man = try readManifest(&h, "imports/gamma");
    try testing.expect(man.promoted);
}

test "promote: every copy_file action path points at an existing file under canonical/<name> (spec promote/Skill Operation Result copy_file 'path')" {
    // Spec: the action list describes WHAT HAPPENED with the specific path
    // (Filesystem Safety step 5; JSON Schemas > Skill Operation Result copy_file
    // 'path'). promote stages into a sibling .<name>.staging dir then swaps; the
    // recorded copy_file paths must name the FINAL destination
    // (<canonical>/<name>/...), not the now-deleted staging dir.
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "rho", "rho", "Rho draft.");
    try h.fixtures().writeSupportFile("imports/rho", "helper.txt", "support-data");
    try h.fixtures().writeSupportFile("imports/rho/sub", "nested.txt", "nested-data");
    var c = h.ctx();

    const r = try expectOk(ops.promote(&c, "rho", false));

    const dest_dir = try canonicalPath(&h, "rho");
    var saw_copy = false;
    for (r.actions) |a| {
        if (a.action != .copy_file) continue;
        saw_copy = true;
        // The recorded path must be under the FINAL canonical/<name> dir...
        try testing.expect(std.mem.startsWith(u8, a.path, dest_dir));
        // ...and must name a file that actually exists on disk after the swap
        // (the staging path would not exist; it was renamed away).
        const st = std.Io.Dir.cwd().statFile(io, a.path, .{ .follow_symlinks = false }) catch |err| {
            std.debug.print("copy_file action path does not exist: {s} ({any})\n", .{ a.path, err });
            return error.CopyFilePathMissing;
        };
        try testing.expectEqual(std.Io.File.Kind.file, st.kind);
    }
    try testing.expect(saw_copy);
}

test "promote: stage-then-swap leaves no staging/backup litter in canonical (spec promote)" {
    // The stage-then-swap implementation (spec promote: don't remove the old
    // canonical until the replacement is ready) must not leave temporary
    // .<name>.staging / .<name>.old directories behind — they would pollute
    // discovery.
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "sigma", "sigma", "New sigma.");
    try h.fixtures().writeSkill("canonical/sigma", "sigma", "Old sigma.");
    var c = h.ctx();

    _ = try expectOk(ops.promote(&c, "sigma", true));

    // Only the promoted skill dir remains in canonical; no dot-prefixed temps.
    var dir = try h.roots.dir().openDir(io, "canonical", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        try testing.expect(entry.name[0] != '.');
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

// --- collision: frontmatter name elsewhere in canonical --------------------

test "promote: frontmatter-name collision elsewhere in canonical fails (spec promote/Collision Rules)" {
    var h = try Harness.init();
    defer h.deinit();
    // Draft "delta" (dir name == frontmatter name, as the real import path
    // guarantees).
    try draft(&h, "delta", "delta", "Delta draft.");
    // A DIFFERENT canonical directory ("other-dir") whose SKILL.md frontmatter
    // name is "delta" => frontmatter name collision anywhere in canonical (spec
    // "Collision Rules": refuse frontmatter name collisions anywhere in
    // canonical, including when the colliding directory has a different directory
    // name). The collision is NOT at the destination path "canonical/delta".
    try h.fixtures().writeSkill("canonical/other-dir", "delta", "Other.");
    var c = h.ctx();
    try expectErrKind(ops.promote(&c, "delta", false), .frontmatter_name_collision);
}

// --- leftover staging from a crash-interrupted promote (Finding #11) -------

test "promote: a leftover .<name>.staging dir from an interrupted promote does NOT cause a false frontmatter_name_collision (Finding #11)" {
    // A crash-interrupted promote can leave `<canonical>/.<name>.staging`
    // containing a valid SKILL.md whose frontmatter name == <name>. The reserved
    // staging path is the operation's OWN transient directory and must not be
    // treated as a colliding canonical skill (spec "Collision Rules": frontmatter
    // collisions are about real canonical skills). Re-running promote must succeed
    // and clean the stale staging dir, not be permanently blocked.
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "omega", "omega", "Omega draft.");
    // Simulate the crash-leftover: a staging dir with a valid SKILL.md naming the
    // same skill. Its directory name (.omega.staging) differs from "omega", so the
    // buggy collision scan flags it as a frontmatter_name_collision.
    try h.fixtures().writeSkill("canonical/.omega.staging", "omega", "Half-staged omega.");
    var c = h.ctx();

    const r = try expectOk(ops.promote(&c, "omega", false));
    try testing.expectEqualStrings("omega", r.skill_name);

    // The canonical copy was created from the real draft content.
    const skill = try readFile(&h, "canonical/omega/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "Omega draft.") != null);
    // The stale staging dir is gone (no litter remains).
    try expectNoStagingLitter(&h, "omega");
    // Draft manifest flipped to promoted.
    const man = try readManifest(&h, "imports/omega");
    try testing.expect(man.promoted);
}

test "promote: a genuine frontmatter name collision in a real canonical dir still fails even with a leftover staging dir present (Finding #11)" {
    // The staging-exclusion fix must NOT mask a real collision: a DIFFERENT,
    // real canonical directory whose SKILL.md frontmatter name equals the skill
    // still collides (spec "Collision Rules"). The presence of a leftover staging
    // dir for the same skill must not suppress that genuine collision.
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "psi-c", "psi-c", "Psi-c draft.");
    // A real, non-reserved canonical dir colliding on frontmatter name.
    try h.fixtures().writeSkill("canonical/other-psi", "psi-c", "Other psi-c.");
    // Plus a leftover staging dir for the skill being promoted.
    try h.fixtures().writeSkill("canonical/.psi-c.staging", "psi-c", "Half-staged psi-c.");
    var c = h.ctx();

    try expectErrKind(ops.promote(&c, "psi-c", false), .frontmatter_name_collision);
}

// --- unsupported entries inside the import dir (symlinks) ------------------

test "promote: symlink inside the import directory fails (spec promote: Unsupported entries ... must fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "eps", "eps", "Eps draft.");
    // A symlink inside the import dir is an unsupported entry for promotion copy
    // (spec promote). Place a real target + a symlink to it within the import dir.
    try h.fixtures().writeSupportFile("imports/eps", "real.txt", "x");
    try h.fixtures().symlink("real.txt", "imports/eps/link.txt");
    var c = h.ctx();

    try expectErrKind(ops.promote(&c, "eps", false), .unsupported_entry);
    // No canonical copy was created (failed before/with no surviving partial).
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/eps"));
}

// --- unsafe agent entry must fail BEFORE mutation --------------------------

test "promote: unsafe agent entry for the skill fails before any mutation (spec promote)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "zeta", "zeta", "Zeta draft.");
    // A real directory occupying the agent slot for this skill is unsafe; the
    // existing managed-symlink relink step cannot proceed safely (spec promote:
    // "Existing unsafe agent entries for the skill must fail before mutation").
    try h.fixtures().realDir(.claude, "zeta");
    var c = h.ctx();

    try expectErrKind(ops.promote(&c, "zeta", false), .unsafe_agent_entry);
    // No canonical copy created, draft manifest still unpromoted (no mutation).
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/zeta"));
    const man = try readManifest(&h, "imports/zeta");
    try testing.expect(!man.promoted);
    // agent slot untouched (still a real dir).
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "claude/zeta")).?);
}

// --- relink managed import symlinks to canonical copy ----------------------

test "promote: managed import symlinks are relinked to the canonical copy (spec promote)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "eta", "eta", "Eta draft.");
    // Legacy-enabled: a managed symlink in the agent root pointing at the draft
    // import dir. After promotion it must point at the canonical copy (spec
    // promote: "Existing managed symlinks that point to the import directory must
    // be relinked to the canonical promoted copy").
    try h.fixtures().managedSymlink(.claude, "eta", .imports, "eta");
    var c = h.ctx();

    const r = try expectOk(ops.promote(&c, "eta", false));
    // The agent symlink now targets the canonical copy.
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/eta")).?);
    try testing.expectEqualStrings(try canonicalPath(&h, "eta"), try linkTarget(&h, "claude/eta"));

    // A remove_symlink + create_symlink (relink) pair is recorded for the agent.
    var saw_remove = false;
    var saw_create = false;
    for (r.actions) |a| {
        if (a.action == .remove_symlink and a.agent == .claude_code) saw_remove = true;
        if (a.action == .create_symlink and a.agent == .claude_code) saw_create = true;
    }
    try testing.expect(saw_remove);
    try testing.expect(saw_create);
}

// --- overwrite paths -------------------------------------------------------

test "promote --overwrite: replaces matching-name canonical dest, old copy gone (spec promote)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "theta", "theta", "New theta.");
    // Existing canonical dest with the SAME frontmatter name "theta" but stale
    // content; --overwrite replaces it (spec promote: overwrite allowed when
    // dest SKILL.md name matches).
    try h.fixtures().writeSkill("canonical/theta", "theta", "Old theta.");
    try h.fixtures().writeSupportFile("canonical/theta", "stale.txt", "stale");
    var c = h.ctx();

    _ = try expectOk(ops.promote(&c, "theta", true));
    // Canonical copy now has the NEW content; the stale support file is gone
    // (stage-then-swap replaced the directory wholesale).
    const skill = try readFile(&h, "canonical/theta/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "New theta.") != null);
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/theta/stale.txt"));
    const man = try readManifest(&h, "imports/theta");
    try testing.expect(man.promoted);
}

test "promote --overwrite: dest whose SKILL.md name differs fails, dest untouched (spec promote)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "iota", "iota", "Iota draft.");
    // Existing canonical dir AT THE DESTINATION PATH whose SKILL.md frontmatter
    // name differs => even with --overwrite this must fail (spec promote: "Even
    // with --overwrite, an existing destination whose SKILL.md frontmatter has a
    // different name must fail").
    try h.fixtures().writeSkill("canonical/iota", "different-name", "Different.");
    var c = h.ctx();

    try expectErrKind(ops.promote(&c, "iota", true), .canonical_collision);
    // Destination untouched: still the different-named skill.
    const skill = try readFile(&h, "canonical/iota/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "different-name") != null);
    const man = try readManifest(&h, "imports/iota");
    try testing.expect(!man.promoted);
}

// --- overwrite data-loss safety: failure injection -------------------------

/// Assert no `.<name>.staging` / `.<name>.old` litter remains in canonical after
/// a failed promote (the stage-then-swap temporaries must be cleaned up).
fn expectNoStagingLitter(h: *Harness, name: []const u8) !void {
    const staging = try std.fmt.allocPrint(h.arena(), "canonical/.{s}.staging", .{name});
    const old = try std.fmt.allocPrint(h.arena(), "canonical/.{s}.old", .{name});
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(h, staging));
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(h, old));
}

test "promote --overwrite: a staged-copy failure leaves the OLD canonical copy intact (spec promote: don't remove the old copy until the replacement is ready)" {
    // Spec promote: "With --overwrite, the existing canonical copy must not be
    // removed until the replacement copy is known to be valid and ready."
    // Inject a failure copying SKILL.md INTO the staging dir. The copy happens
    // BEFORE the old dest is moved aside, so the original canonical copy and the
    // draft manifest must be entirely untouched, and no staging/backup litter may
    // remain. A naive delete-then-copy implementation would have already removed
    // the old copy and would fail this test.
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "psi", "psi", "New psi.");
    try h.fixtures().writeSkill("canonical/psi", "psi", "Old psi.");
    try h.fixtures().writeSupportFile("canonical/psi", "keep.txt", "old-support");

    // IO that fails the staging copy of SKILL.md.
    const failing_io = testutil.FailingIo.forBasename("SKILL.md");
    var c = h.ctx();
    c.io = failing_io;

    const res = ops.promote(&c, "psi", true);
    try testing.expect(res == .err);

    // The OLD canonical copy survives intact (content + support file).
    const skill = try readFile(&h, "canonical/psi/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "Old psi.") != null);
    try testing.expectEqualStrings("old-support", try readFile(&h, "canonical/psi/keep.txt"));
    // The draft manifest stays unpromoted.
    const man = try readManifest(&h, "imports/psi");
    try testing.expect(!man.promoted);
    // No stage/backup litter.
    try expectNoStagingLitter(&h, "psi");
}

test "promote --overwrite: a swap-rename failure restores the original canonical copy (spec promote: don't remove the old copy until the replacement is ready)" {
    // Spec promote: "With --overwrite, the existing canonical copy must not be
    // removed until the replacement copy is known to be valid and ready." The
    // stage-then-swap moves the old dest aside to .<name>.old, then renames the
    // staging dir into place. Inject a failure on THAT swap rename (source
    // basename .<name>.staging). The implementation must restore the original
    // canonical copy from the backup, leaving no .old/.staging litter and the
    // draft manifest unpromoted.
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "chi", "chi", "New chi.");
    try h.fixtures().writeSkill("canonical/chi", "chi", "Old chi.");
    try h.fixtures().writeSupportFile("canonical/chi", "keep.txt", "old-support");

    // IO that fails ONLY the `.chi.staging -> chi` swap rename (keyed on the
    // source basename), so the recovery `.chi.old -> chi` rename still succeeds.
    const failing_io = testutil.FailingRenameIo.forOldBasename(".chi.staging");
    var c = h.ctx();
    c.io = failing_io;

    const res = ops.promote(&c, "chi", true);
    try testing.expect(res == .err);

    // The original canonical copy is fully restored (content + support file).
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "canonical/chi")).?);
    const skill = try readFile(&h, "canonical/chi/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "Old chi.") != null);
    try testing.expectEqualStrings("old-support", try readFile(&h, "canonical/chi/keep.txt"));
    // The draft manifest stays unpromoted.
    const man = try readManifest(&h, "imports/chi");
    try testing.expect(!man.promoted);
    // No stage/backup litter.
    try expectNoStagingLitter(&h, "chi");
}

// ===========================================================================
// unpromote
// ===========================================================================

test "unpromote: unknown skill fails (spec unpromote: Unknown skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();
    try expectErrKind(ops.unpromote(&c, "nope"), .unknown_skill);
}

test "unpromote: canonical-only skill fails (spec unpromote: Canonical-only ... fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/can", "can", "Canonical.");
    var c = h.ctx();
    try expectErrKind(ops.unpromote(&c, "can"), .canonical_only_skill);
}

test "unpromote: agent-only skill fails (spec unpromote: agent-only skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().realDir(.claude, "ghost");
    var c = h.ctx();
    try expectErrKind(ops.unpromote(&c, "ghost"), .agent_only_skill);
}

test "unpromote: unpromoted import fails (spec unpromote: Unpromoted imports fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "draft", "draft", "Draft.");
    var c = h.ctx();
    try expectErrKind(ops.unpromote(&c, "draft"), .not_promoted);
}

test "unpromote: removes canonical copy + managed agent symlinks, sets manifest promoted=false (spec unpromote)" {
    var h = try Harness.init();
    defer h.deinit();
    // Promoted import: draft (promoted=true) + canonical copy + a managed agent
    // symlink to the canonical copy.
    try h.fixtures().writeSkill("imports/kappa", "kappa", "Kappa.");
    try h.fixtures().writeManifest("imports/kappa", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/kappa", "kappa", "Kappa.");
    try h.fixtures().managedSymlink(.claude, "kappa", .canonical, "kappa");
    var c = h.ctx();

    const r = try expectOk(ops.unpromote(&c, "kappa"));
    // Managed agent symlink to the canonical copy is removed (spec unpromote).
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "claude/kappa"));
    // Canonical copy is removed (spec unpromote).
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/kappa"));
    // Draft import remains; manifest promoted flag set to false (spec unpromote).
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "imports/kappa")).?);
    const man = try readManifest(&h, "imports/kappa");
    try testing.expect(!man.promoted);

    // Action list records remove_symlink (agent) + remove_directory (canonical).
    var saw_remove_symlink = false;
    var saw_remove_dir = false;
    for (r.actions) |a| {
        if (a.action == .remove_symlink) saw_remove_symlink = true;
        if (a.action == .remove_directory) saw_remove_dir = true;
    }
    try testing.expect(saw_remove_symlink);
    try testing.expect(saw_remove_dir);
}

test "unpromote: leaves an unrelated external agent symlink untouched (spec unpromote/Filesystem Safety)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/lam", "lam", "Lam.");
    try h.fixtures().writeManifest("imports/lam", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/lam", "lam", "Lam.");
    // An agent entry that is an EXTERNAL symlink (not pointing at the canonical
    // copy) must NOT be removed (spec "Filesystem Safety": never remove external
    // entries; unpromote only removes managed symlinks to the canonical copy).
    try h.fixtures().strayFile(.claude, "ext-target", "x");
    try h.fixtures().symlink("ext-target", "claude/lam");
    var c = h.ctx();

    _ = try expectOk(ops.unpromote(&c, "lam"));
    // The external symlink is left intact.
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/lam")).?);
    try testing.expectEqualStrings("ext-target", try linkTarget(&h, "claude/lam"));
    // Canonical copy still removed.
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/lam"));
}

// ===========================================================================
// delete
// ===========================================================================

test "delete: unknown skill fails (spec delete: Unknown skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();
    try expectErrKind(ops.delete(&c, "nope"), .unknown_skill);
}

test "delete: canonical-only skill fails (spec delete: Canonical ... fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("canonical/can", "can", "Canonical.");
    var c = h.ctx();
    try expectErrKind(ops.delete(&c, "can"), .canonical_only_skill);
}

test "delete: agent-only skill fails (spec delete: ... agent-only skills fail.)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().realDir(.claude, "ghost");
    var c = h.ctx();
    try expectErrKind(ops.delete(&c, "ghost"), .agent_only_skill);
}

test "delete: promoted import fails (spec delete: Promoted imports fail; unpromote first.)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/mu", "mu", "Mu.");
    try h.fixtures().writeManifest("imports/mu", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/mu", "mu", "Mu.");
    var c = h.ctx();
    try expectErrKind(ops.delete(&c, "mu"), .already_promoted);
    // Import left intact (not deleted).
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "imports/mu")).?);
}

test "delete: legacy-enabled import (managed import symlink) fails; disable first (spec delete)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "nu", "nu", "Nu.");
    // Enabled the legacy way: a managed symlink in the agent root to the imports
    // draft dir => delete must fail (spec delete: "Imports enabled through legacy
    // managed import symlinks fail; disable first").
    try h.fixtures().managedSymlink(.claude, "nu", .imports, "nu");
    var c = h.ctx();
    try expectErrKind(ops.delete(&c, "nu"), .enabled_import);
    // Import left intact.
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "imports/nu")).?);
}

test "delete: success removes <imports-root>/<name> (spec delete)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "xi", "xi", "Xi.");
    var c = h.ctx();

    const r = try expectOk(ops.delete(&c, "xi"));
    try testing.expectEqualStrings("xi", r.skill_name);
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "imports/xi"));
    // Records a remove_directory action.
    var saw_remove_dir = false;
    for (r.actions) |a| {
        if (a.action == .remove_directory) saw_remove_dir = true;
    }
    try testing.expect(saw_remove_dir);
}

test "delete: unrelated same-name unsafe agent entry does NOT block and is left untouched (spec delete)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "omi", "omi", "Omicron.");
    // An UNRELATED agent entry with the same name that is NOT a managed import
    // symlink (a stray real directory, e.g. an agent_only-looking dir). It must
    // neither block deletion nor be touched (spec delete: "Unrelated same-name
    // unsafe agent entries do not block deletion and must be left untouched").
    try h.fixtures().realDir(.claude, "omi");
    var c = h.ctx();

    _ = try expectOk(ops.delete(&c, "omi"));
    // Import removed.
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "imports/omi"));
    // Unrelated agent entry untouched.
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "claude/omi")).?);
}

// ===========================================================================
// H7 hardening additions
// ===========================================================================

// --- (1) promote action paths all exist on disk after the swap --------------

test "promote: EVERY recorded action path (create_directory/copy_file/write_manifest) exists on disk after the swap (spec promote/Filesystem Safety step 5)" {
    // Spec "Filesystem Safety" step 5 + "Skill Operation Result": the action list
    // describes WHAT HAPPENED, with the specific path. promote stages into a
    // sibling .<name>.staging dir then swaps it into place; a regression that
    // recorded the transient staging path for ANY action (copy_file,
    // create_directory, write_manifest) would name a path that no longer exists
    // after the swap. Assert every action path is present on disk.
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "tau", "tau", "Tau draft.");
    try h.fixtures().writeSupportFile("imports/tau", "helper.txt", "support-data");
    try h.fixtures().writeSupportFile("imports/tau/sub", "nested.txt", "nested-data");
    var c = h.ctx();

    const r = try expectOk(ops.promote(&c, "tau", false));

    var saw_copy = false;
    var saw_manifest = false;
    for (r.actions) |a| {
        switch (a.action) {
            .copy_file => saw_copy = true,
            .write_manifest => saw_manifest = true,
            .create_directory => {},
            else => {},
        }
        const st = std.Io.Dir.cwd().statFile(io, a.path, .{ .follow_symlinks = false }) catch |err| {
            std.debug.print("promote {s} action path does not exist: {s} ({any})\n", .{ @tagName(a.action), a.path, err });
            return error.ActionPathMissing;
        };
        _ = st;
    }
    try testing.expect(saw_copy);
    // write_manifest names the draft import.json, which still exists post-swap.
    try testing.expect(saw_manifest);
}

// --- (3) codex-branch coverage ---------------------------------------------

test "promote: managed import symlinks are relinked on the CODEX root (spec promote)" {
    // Mirror of the claude relink test, but exercising the codex agent branch of
    // promoteRun's relink loop, which was previously untested.
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "eta-cx", "eta-cx", "Eta codex draft.");
    try h.fixtures().managedSymlink(.codex, "eta-cx", .imports, "eta-cx");
    var c = h.ctx();

    const r = try expectOk(ops.promote(&c, "eta-cx", false));
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "codex/eta-cx")).?);
    try testing.expectEqualStrings(try canonicalPath(&h, "eta-cx"), try linkTarget(&h, "codex/eta-cx"));

    var saw_remove = false;
    var saw_create = false;
    for (r.actions) |a| {
        if (a.action == .remove_symlink and a.agent == .codex) saw_remove = true;
        if (a.action == .create_symlink and a.agent == .codex) saw_create = true;
    }
    try testing.expect(saw_remove);
    try testing.expect(saw_create);
}

test "unpromote: removes a managed agent symlink on the CODEX root (spec unpromote)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/kappa-cx", "kappa-cx", "Kappa codex.");
    try h.fixtures().writeManifest("imports/kappa-cx", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/kappa-cx", "kappa-cx", "Kappa codex.");
    try h.fixtures().managedSymlink(.codex, "kappa-cx", .canonical, "kappa-cx");
    var c = h.ctx();

    const r = try expectOk(ops.unpromote(&c, "kappa-cx"));
    // Codex managed symlink removed.
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "codex/kappa-cx"));
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/kappa-cx"));

    var saw_remove_codex = false;
    for (r.actions) |a| {
        if (a.action == .remove_symlink and a.agent == .codex) saw_remove_codex = true;
    }
    try testing.expect(saw_remove_codex);
}

test "delete: legacy-enabled import via the CODEX root fails; disable first (spec delete)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "nu-cx", "nu-cx", "Nu codex.");
    try h.fixtures().managedSymlink(.codex, "nu-cx", .imports, "nu-cx");
    var c = h.ctx();
    try expectErrKind(ops.delete(&c, "nu-cx"), .enabled_import);
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "imports/nu-cx")).?);
}

// --- (4) manifest field preservation ---------------------------------------

test "promote: preserves source_type/source_location/source_repository/content_hash while flipping promoted=true (spec promote/Import Manifest)" {
    // Spec promote: "Promotion sets the draft import manifest promoted field to
    // true." It must NOT clobber the other manifest fields. Use a repository
    // import manifest (the richest shape) so source_repository survives too.
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/repo-skill", "repo-skill", "Repo skill.");
    try h.fixtures().writeManifest("imports/repo-skill", .{
        .source_type = .repository,
        .source_location = "https://example.test/skills.git#repo-skill",
        .source_repository = .{
            .repository = "https://example.test/skills.git",
            .skill_path = "repo-skill",
        },
        .imported_at = 1710000123,
        .content_hash = "sha256:abc123",
        .promoted = false,
    });
    var c = h.ctx();

    _ = try expectOk(ops.promote(&c, "repo-skill", false));

    // Re-read the raw on-disk manifest; assert all provenance fields survived and
    // only `promoted` flipped.
    const bytes = try readFile(&h, "imports/repo-skill/import.json");
    var parsed = try manifest_mod.parse(h.arena(), bytes);
    defer parsed.deinit();
    const m = parsed.value;
    try testing.expectEqual(types.ImportSourceType.repository, m.source_type);
    try testing.expectEqualStrings("https://example.test/skills.git#repo-skill", m.source_location.?);
    try testing.expect(m.source_repository != null);
    try testing.expectEqualStrings("https://example.test/skills.git", m.source_repository.?.repository);
    try testing.expectEqualStrings("repo-skill", m.source_repository.?.skill_path);
    try testing.expectEqual(@as(i64, 1710000123), m.imported_at);
    try testing.expectEqualStrings("sha256:abc123", m.content_hash);
    try testing.expect(m.promoted);
}

test "unpromote: preserves provenance fields while flipping promoted=false (spec unpromote/Import Manifest)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/repo-un", "repo-un", "Repo un.");
    try h.fixtures().writeManifest("imports/repo-un", .{
        .source_type = .repository,
        .source_location = "https://example.test/skills.git#repo-un",
        .source_repository = .{
            .repository = "https://example.test/skills.git",
            .skill_path = "repo-un",
        },
        .imported_at = 1710000999,
        .content_hash = "sha256:def456",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/repo-un", "repo-un", "Repo un.");
    var c = h.ctx();

    _ = try expectOk(ops.unpromote(&c, "repo-un"));

    const bytes = try readFile(&h, "imports/repo-un/import.json");
    var parsed = try manifest_mod.parse(h.arena(), bytes);
    defer parsed.deinit();
    const m = parsed.value;
    try testing.expectEqual(types.ImportSourceType.repository, m.source_type);
    try testing.expectEqualStrings("https://example.test/skills.git#repo-un", m.source_location.?);
    try testing.expect(m.source_repository != null);
    try testing.expectEqualStrings("repo-un", m.source_repository.?.skill_path);
    try testing.expectEqual(@as(i64, 1710000999), m.imported_at);
    try testing.expectEqualStrings("sha256:def456", m.content_hash);
    try testing.expect(!m.promoted);
}

test "promote: a manifest-less import is promoted (content copied, no crash, no write_manifest action) (spec promote)" {
    // An imported draft without import.json is discoverable as `imported`
    // (promoted=false). promote must still copy its content into canonical and
    // succeed; with no manifest there is nothing to flip, so no write_manifest
    // action is recorded and no error occurs.
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/bare", "bare", "Bare draft.");
    // deliberately NO import.json
    var c = h.ctx();

    const r = try expectOk(ops.promote(&c, "bare", false));
    try testing.expectEqual(std.Io.File.Kind.directory, (try entryKind(&h, "canonical/bare")).?);
    const skill = try readFile(&h, "canonical/bare/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "name: bare") != null);
    // No manifest to flip => no write_manifest action.
    for (r.actions) |a| {
        try testing.expect(a.action != .write_manifest);
    }
    // import.json must not have been created in the import dir.
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "imports/bare/import.json"));
}

// --- (5) unsafe agent entry variants for promote ---------------------------

test "promote: an EXTERNAL agent symlink for the skill fails before mutation (spec promote)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "ext-p", "ext-p", "Ext draft.");
    // An agent symlink pointing OUTSIDE managed roots is unsafe; promote must
    // fail before mutating anything (spec promote: "Existing unsafe agent entries
    // for the skill must fail before mutation").
    try h.fixtures().strayFile(.claude, "ext-target", "x");
    try h.fixtures().symlink("ext-target", "claude/ext-p");
    var c = h.ctx();

    try expectErrKind(ops.promote(&c, "ext-p", false), .unsafe_agent_entry);
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/ext-p"));
    const man = try readManifest(&h, "imports/ext-p");
    try testing.expect(!man.promoted);
    // External symlink untouched.
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/ext-p")).?);
    try testing.expectEqualStrings("ext-target", try linkTarget(&h, "claude/ext-p"));
}

test "promote: a BROKEN agent symlink for the skill fails before mutation (spec promote)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "brk-p", "brk-p", "Broken draft.");
    // A broken symlink (target does not exist) is unsafe.
    try h.fixtures().symlink("does/not/exist", "claude/brk-p");
    var c = h.ctx();

    try expectErrKind(ops.promote(&c, "brk-p", false), .unsafe_agent_entry);
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/brk-p"));
    const man = try readManifest(&h, "imports/brk-p");
    try testing.expect(!man.promoted);
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/brk-p")).?);
}

test "promote: a WRONG-managed-target agent symlink for the skill fails before mutation (spec promote)" {
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "wrong-p", "wrong-p", "Wrong-target draft.");
    // A managed symlink pointing at a DIFFERENT managed skill (neither the import
    // dir nor the eventual canonical copy) is unsafe.
    try h.fixtures().writeSkill("canonical/other", "other", "Other.");
    try h.fixtures().managedSymlink(.claude, "wrong-p", .canonical, "other");
    var c = h.ctx();

    try expectErrKind(ops.promote(&c, "wrong-p", false), .unsafe_agent_entry);
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/wrong-p"));
    const man = try readManifest(&h, "imports/wrong-p");
    try testing.expect(!man.promoted);
    // The wrong-target symlink is left pointing where it did.
    try testing.expectEqualStrings(try canonicalPath(&h, "other"), try linkTarget(&h, "claude/wrong-p"));
}

test "unpromote: leaves a BROKEN agent symlink for the skill untouched (spec unpromote/Filesystem Safety)" {
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/brk-u", "brk-u", "Brk un.");
    try h.fixtures().writeManifest("imports/brk-u", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/brk-u", "brk-u", "Brk un.");
    // A broken symlink in the agent root is NOT a managed symlink to the canonical
    // copy; unpromote must leave it untouched.
    try h.fixtures().symlink("does/not/exist", "claude/brk-u");
    var c = h.ctx();

    _ = try expectOk(ops.unpromote(&c, "brk-u"));
    // Broken symlink intact.
    try testing.expectEqual(std.Io.File.Kind.sym_link, (try entryKind(&h, "claude/brk-u")).?);
    try testing.expectEqualStrings("does/not/exist", try linkTarget(&h, "claude/brk-u"));
    // Canonical copy still removed.
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try entryKind(&h, "canonical/brk-u"));
}

// --- (6) partial-action reporting on execute-phase I/O error ----------------

test "promote: an execute-phase I/O failure reports the completed actions in partial_actions (spec Filesystem Safety)" {
    // Spec "Filesystem Safety": "Partially completed operations caused by
    // unexpected I/O errors should report the actions that completed before the
    // failure when the implementation can do so." Inject a failure on the draft
    // manifest write (the LAST execute step) — by then the canonical copy and its
    // copy_file actions are already recorded. Those completed actions must be
    // surfaced in the error's partial_actions, not silently discarded.
    var h = try Harness.init();
    defer h.deinit();
    try draft(&h, "partial-p", "partial-p", "Partial promote.");
    try h.fixtures().writeSupportFile("imports/partial-p", "helper.txt", "data");

    // Fail the import.json write (manifest update) only; the staged copy of
    // SKILL.md/helper.txt and the swap complete first. (The draft import.json is
    // never copied into canonical, so this only trips setManifestPromoted.)
    const failing_io = testutil.FailingIo.forBasename("import.json");
    var c = h.ctx();
    c.io = failing_io;

    const e = try expectErr(ops.promote(&c, "partial-p", false));
    try testing.expectEqual(result.ErrorKind.io_error, e.kind);
    // The canonical copy completed before the failure.
    try testing.expect(e.partial_actions.items.len > 0);
    var saw_copy = false;
    for (e.partial_actions.items) |a| {
        if (a.action == .copy_file) saw_copy = true;
    }
    try testing.expect(saw_copy);
}

test "unpromote: an execute-phase I/O failure reports completed actions in partial_actions (spec Filesystem Safety)" {
    // Remove the managed agent symlink + canonical copy succeed (recorded), then
    // the manifest write fails. The completed remove_symlink/remove_directory
    // actions must be surfaced in partial_actions.
    var h = try Harness.init();
    defer h.deinit();
    try h.fixtures().writeSkill("imports/partial-u", "partial-u", "Partial un.");
    try h.fixtures().writeManifest("imports/partial-u", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:x",
        .promoted = true,
    });
    try h.fixtures().writeSkill("canonical/partial-u", "partial-u", "Partial un.");
    try h.fixtures().managedSymlink(.claude, "partial-u", .canonical, "partial-u");

    const failing_io = testutil.FailingIo.forBasename("import.json");
    var c = h.ctx();
    c.io = failing_io;

    const e = try expectErr(ops.unpromote(&c, "partial-u"));
    try testing.expectEqual(result.ErrorKind.io_error, e.kind);
    try testing.expect(e.partial_actions.items.len > 0);
    var saw_remove = false;
    for (e.partial_actions.items) |a| {
        if (a.action == .remove_symlink or a.action == .remove_directory) saw_remove = true;
    }
    try testing.expect(saw_remove);
}

// silence unused-import warnings for helpers referenced only in some configs.
comptime {
    _ = frontmatter;
}
