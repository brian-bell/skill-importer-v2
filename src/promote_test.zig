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

// silence unused-import warnings for helpers referenced only in some configs.
comptime {
    _ = frontmatter;
}
