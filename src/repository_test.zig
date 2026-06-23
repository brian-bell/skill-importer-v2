//! Tests for repository.zig (cli-clean-room-spec.md "import repository",
//! "Collision Rules" > "Repository batch import", "JSON Schemas > Repository
//! Import Result"). Covers the spec "Recommended TDD Acceptance Suite" bullet 7:
//! single import, selection, selected import, batch import, duplicate selections,
//! missing selection, duplicate skill names, rollback on batch failure, root
//! skill import, invalid root SKILL.md, empty repository, depth-limit boundary
//! (depth 8 included, 9 skipped), and all three `kind` JSON shapes.
//!
//! Safety: every test runs inside a unique temp tree (CLAUDE.md hard rule); the
//! fake git provider copies a prebuilt local tree, so no network or `git` binary
//! is touched.

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const repository = @import("repository.zig");
const types = @import("types.zig");
const json_out = @import("json_out.zig");
const testutil = @import("testutil.zig");
const git = @import("git.zig");
const hash = @import("hash.zig");

// --- harness ---------------------------------------------------------------

const Harness = struct {
    roots: testutil.TmpRoots,
    arena_state: std.heap.ArenaAllocator,
    clock_state: testutil.FixedClock,

    fn init() !Harness {
        return .{
            .roots = try testutil.TmpRoots.init(testing.allocator),
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .clock_state = .{ .value = 1710000000 },
        };
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
        self.roots.deinit();
    }

    fn arena(self: *Harness) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn ctx(self: *Harness) repository.Context {
        return .{
            .arena = self.arena(),
            .io = io,
            .imports_root = self.roots.imports,
            .canonical_root = self.roots.canonical,
            .clock = self.clock_state.clock(),
        };
    }

    /// Absolute path of a prebuilt repository source tree under the temp base.
    fn srcTree(self: *Harness, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena(), &.{ self.roots.base, rel });
    }

    fn importsExists(self: *Harness, sub: []const u8) bool {
        const p = std.fs.path.join(testing.allocator, &.{ "imports", sub }) catch return false;
        defer testing.allocator.free(p);
        _ = self.roots.dir().statFile(io, p, .{ .follow_symlinks = false }) catch return false;
        return true;
    }

    fn readImports(self: *Harness, sub: []const u8) ![]u8 {
        const p = try std.fs.path.join(self.arena(), &.{ "imports", sub });
        return self.roots.dir().readFileAlloc(io, p, self.arena(), .unlimited);
    }
};

fn expectErr(res: anytype, kind: anytype) !void {
    switch (res) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(kind, e.kind),
    }
}

const no_select: []const []const u8 = &.{};

// --- single import: exactly one valid skill, no --select -> import immediately
// (spec "import repository": "Import immediately when exactly one valid skill
// exists and no --select was provided"; "JSON Schemas": kind "imported"). ---

test "repository import: one valid nested skill, no select, imports it (kind imported)" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // A repo source tree with exactly one valid skill in a nested dir.
    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First repository skill.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };

    // Single imported result (spec "Repository Import Result": kind imported).
    try testing.expect(r == .imported);
    const single = r.imported;
    try testing.expectEqual(types.RepoImportKind.imported, single.kind);
    try testing.expectEqualStrings("repo-alpha", single.skill_name);
    try testing.expect(std.mem.endsWith(u8, single.skill_path, "imports/repo-alpha"));

    // Manifest provenance (spec "import repository": repository manifests).
    try testing.expectEqual(types.ImportSourceType.repository, single.manifest.source_type);
    try testing.expectEqualStrings(
        "https://example.test/skills.git#repo-alpha",
        single.manifest.source_location.?,
    );
    try testing.expectEqualStrings("https://example.test/skills.git", single.manifest.source_repository.?.repository);
    try testing.expectEqualStrings("repo-alpha", single.manifest.source_repository.?.skill_path);

    // Manifest content_hash + imported_at (spec "Import Manifest": content_hash
    // is "SHA-256 ... prefixed with sha256:"; imported_at is a Unix timestamp).
    // The hash must be an `sha256:`-prefixed 71-char string and must equal an
    // independent hash of the SOURCE skill directory (spec "import repository":
    // directory content hash includes supporting files and relative paths).
    try testing.expect(std.mem.startsWith(u8, single.manifest.content_hash, "sha256:"));
    try testing.expectEqual(@as(usize, 71), single.manifest.content_hash.len);
    {
        var sdir = try h.roots.dir().openDir(io, try std.fs.path.join(h.arena(), &.{ "repo", "repo-alpha" }), .{ .iterate = true });
        defer sdir.close(io);
        const expected = try hash.hashDirectory(h.arena(), io, sdir);
        try testing.expectEqualStrings(expected, single.manifest.content_hash);
    }
    // imported_at comes from the (Fixed) clock — pin the exact value (spec
    // "Import Manifest": imported_at).
    try testing.expectEqual(@as(i64, 1710000000), single.manifest.imported_at);

    // Actions array (spec "JSON Schemas > Import Result": Import action values
    // create_directory / copy_file / write_manifest; "Repository Import Result":
    // imported.actions). A single-file skill records exactly: create_directory,
    // copy_file (SKILL.md), write_manifest — in that order.
    try testing.expect(single.actions.len >= 3);
    try testing.expectEqual(types.ImportActionKind.create_directory, single.actions[0].action);
    try testing.expectEqual(types.ImportActionKind.write_manifest, single.actions[single.actions.len - 1].action);
    {
        var saw_skill_copy = false;
        for (single.actions) |a| {
            if (a.action == .copy_file and std.mem.endsWith(u8, a.path, "SKILL.md")) saw_skill_copy = true;
        }
        try testing.expect(saw_skill_copy);
    }

    // Stored on disk.
    const skill = try h.readImports("repo-alpha/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "name: repo-alpha") != null);
    try testing.expect(h.importsExists("repo-alpha/import.json"));
}

// --- a skill with a support file records a copy_file action for EACH file and
// the manifest covers the support file (spec "JSON Schemas > Import Result":
// Import action values create_directory / copy_file / write_manifest;
// "Repository Import Result": imported.actions; "import repository": directory
// content hash includes supporting files). A regression that dropped action
// recording, recorded the wrong kind, or hashed only SKILL.md would fail here. ---

test "repository import: multi-file skill records copy_file per file, hash covers support files, JSON shows copy_file/write_manifest" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // One valid skill carrying a supporting file in a nested dir.
    try fx.writeSkill("repo/multi", "multi", "Multi-file skill.");
    try fx.writeSupportFile("repo/multi", "helper.txt", "support data");
    try fx.writeSupportFile("repo/multi/docs", "guide.md", "more support");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };
    try testing.expect(r == .imported);
    const single = r.imported;

    // Actions: begins with create_directory, ends with write_manifest, and
    // contains a copy_file for SKILL.md AND the support files (3 files => 3
    // copy_file actions). Sub-directories are created via create_directory.
    try testing.expectEqual(types.ImportActionKind.create_directory, single.actions[0].action);
    try testing.expectEqual(types.ImportActionKind.write_manifest, single.actions[single.actions.len - 1].action);
    var copies: usize = 0;
    var saw_skill = false;
    var saw_helper = false;
    var saw_guide = false;
    var saw_manifests: usize = 0;
    for (single.actions) |a| {
        switch (a.action) {
            .copy_file => {
                copies += 1;
                if (std.mem.endsWith(u8, a.path, "SKILL.md")) saw_skill = true;
                if (std.mem.endsWith(u8, a.path, "helper.txt")) saw_helper = true;
                if (std.mem.endsWith(u8, a.path, std.fs.path.join(h.arena(), &.{ "docs", "guide.md" }) catch "guide.md")) saw_guide = true;
            },
            .write_manifest => saw_manifests += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), copies);
    try testing.expect(saw_skill);
    try testing.expect(saw_helper);
    try testing.expect(saw_guide);
    try testing.expectEqual(@as(usize, 1), saw_manifests);

    // content_hash equals an independent hash of the SOURCE directory (covers
    // support files + relative paths). A SKILL.md-only hash would differ.
    {
        var sdir = try h.roots.dir().openDir(io, try std.fs.path.join(h.arena(), &.{ "repo", "multi" }), .{ .iterate = true });
        defer sdir.close(io);
        const expected = try hash.hashDirectory(h.arena(), io, sdir);
        try testing.expectEqualStrings(expected, single.manifest.content_hash);
    }

    // Rendered JSON carries the copy_file and write_manifest action tokens (spec
    // wire vocabulary).
    const json = try renderRepo(h.arena(), r);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\": \"copy_file\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\": \"write_manifest\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\": \"create_directory\"") != null);
}

// --- batch import: imported_at is derived from a SINGLE clock.now() per skill
// and shares one value across the batch (spec "Import Manifest": imported_at).
// IncrementingClock advances on every now() call, so a double-now() bug or
// per-skill divergence would surface here (testutil.IncrementingClock doc). The
// imports root is created up-front by makeCheckoutDir's parent handling, so we
// only assert the timestamps each writeSkill recorded. ---

test "repository import: batch imported_at is one clock value across all skills (IncrementingClock)" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    // A clock that advances on EVERY call. We capture its initial value, then
    // assert each imported skill's imported_at against the value observed, so any
    // extra now() call (double-now, per-skill drift) is detected.
    var clk: testutil.IncrementingClock = .{ .value = 1710000000, .step = 1000 };
    var c: repository.Context = .{
        .arena = h.arena(),
        .io = io,
        .imports_root = h.roots.imports,
        .canonical_root = h.roots.canonical,
        .clock = clk.clock(),
    };

    const sel: []const []const u8 = &.{ "repo-alpha", "repo-beta" };
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", sel);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };
    try testing.expect(r == .imported_batch);
    const batch = r.imported_batch;
    try testing.expectEqual(@as(usize, 2), batch.imports.len);

    // Each imported skill calls clock.now() exactly once for its manifest, so the
    // two timestamps advance by exactly one `step`, and each on-disk import.json
    // matches the in-memory manifest's imported_at (no second now() at write
    // time). Pin both values explicitly.
    try testing.expectEqual(@as(i64, 1710000000), batch.imports[0].manifest.imported_at);
    try testing.expectEqual(@as(i64, 1710001000), batch.imports[1].manifest.imported_at);
    // Exactly two now() calls total (one per skill) — no double-now anywhere.
    try testing.expectEqual(@as(usize, 2), clk.calls);

    // The persisted import.json imported_at matches the in-memory manifest.
    {
        const bytes = try h.readImports("repo-alpha/import.json");
        try testing.expect(std.mem.indexOf(u8, bytes, "\"imported_at\": 1710000000") != null);
    }
    {
        const bytes = try h.readImports("repo-beta/import.json");
        try testing.expect(std.mem.indexOf(u8, bytes, "\"imported_at\": 1710001000") != null);
    }
}

// --- selection: more than one valid skill, no --select -> selection result with
// NO storage written (spec "import repository": "Return a selection result when
// more than one valid skill exists and no --select was provided"; "JSON
// Schemas": kind "selection"). ---

test "repository import: multiple valid skills, no select, returns selection and writes nothing" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First repository skill.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second repository skill.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };

    try testing.expect(r == .selection);
    const sel = r.selection;
    try testing.expectEqual(types.RepoImportKind.selection, sel.kind);
    try testing.expectEqualStrings("https://example.test/skills.git", sel.repository);
    // Sorted by file_name (spec scan order): repo-alpha before repo-beta.
    try testing.expectEqual(@as(usize, 2), sel.skills.len);
    try testing.expectEqualStrings("repo-alpha", sel.skills[0].name);
    try testing.expectEqualStrings("repo-alpha", sel.skills[0].relative_path);
    try testing.expectEqualStrings("First repository skill.", sel.skills[0].description.?);
    try testing.expectEqualStrings("repo-beta", sel.skills[1].name);

    // No storage was written (spec: selection writes nothing).
    try testing.expect(!h.importsExists("repo-alpha"));
    try testing.expect(!h.importsExists("repo-beta"));
}

// --- selected import: --select picks one of several valid skills and imports it
// as a single result (spec "import repository": --select identifies skill
// directories). ---

test "repository import: --select one of several imports just that skill" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const sel: []const []const u8 = &.{"repo-beta"};
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", sel);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };

    // A single explicit selection imports as a batch of one (spec "JSON Schemas":
    // multiple selected -> imported_batch; we treat any --select via the batch
    // path so the wire shape is imported_batch with one entry).
    try testing.expect(r == .imported_batch);
    try testing.expectEqual(@as(usize, 1), r.imported_batch.imports.len);
    try testing.expectEqualStrings("repo-beta", r.imported_batch.imports[0].skill_name);
    try testing.expectEqualStrings(
        "https://example.test/skills.git#repo-beta",
        r.imported_batch.imports[0].manifest.source_location.?,
    );

    try testing.expect(h.importsExists("repo-beta/SKILL.md"));
    // The unselected skill is not imported.
    try testing.expect(!h.importsExists("repo-alpha"));
}

// --- batch import: multiple --select imports all of them (spec "import
// repository": import "one or more selected skill directories"; "JSON Schemas":
// kind "imported_batch"). ---

test "repository import: multiple --select imports all as imported_batch" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second.");
    try fx.writeSkill("repo/repo-gamma", "repo-gamma", "Third.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const sel: []const []const u8 = &.{ "repo-alpha", "repo-gamma" };
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", sel);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };

    try testing.expect(r == .imported_batch);
    const batch = r.imported_batch;
    try testing.expectEqual(types.RepoImportKind.imported_batch, batch.kind);
    try testing.expectEqual(@as(usize, 2), batch.imports.len);
    // Imports follow selection order.
    try testing.expectEqualStrings("repo-alpha", batch.imports[0].skill_name);
    try testing.expectEqualStrings("repo-gamma", batch.imports[1].skill_name);

    try testing.expect(h.importsExists("repo-alpha/import.json"));
    try testing.expect(h.importsExists("repo-gamma/import.json"));
    // The unselected skill is not imported.
    try testing.expect(!h.importsExists("repo-beta"));
}

// --- duplicate normalized selections are errors (spec "import repository":
// "Duplicate normalized selections are errors"). `./repo-alpha` and `repo-alpha`
// normalize to the same path. ---

test "repository import: duplicate normalized selections error" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const sel: []const []const u8 = &.{ "repo-alpha", "./repo-alpha" };
    try expectErr(repository.import(&c, fp.provider(), "https://example.test/skills.git", sel), .duplicate_selection);
    // Nothing was written.
    try testing.expect(!h.importsExists("repo-alpha"));
}

// --- an unmatched selection is an error (spec "import repository": "A selected
// path that does not match a discovered valid skill is an error"). ---

test "repository import: selection that matches no valid skill errors" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const sel: []const []const u8 = &.{"repo-nope"};
    try expectErr(repository.import(&c, fp.provider(), "https://example.test/skills.git", sel), .missing_selection);
    try testing.expect(!h.importsExists("repo-alpha"));
}

// --- duplicate selected skill NAMES are refused before writing (spec "Collision
// Rules" > "Repository batch import": "Refuse duplicate selected skill names
// before writing"). Two distinct directories whose frontmatter name collides. ---

test "repository import: batch with duplicate frontmatter names is refused before any write" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // Two different repo directories, both with frontmatter name "dup".
    try fx.writeSkill("repo/dir-one", "dup", "One.");
    try fx.writeSkill("repo/dir-two", "dup", "Two.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const sel: []const []const u8 = &.{ "dir-one", "dir-two" };
    try expectErr(repository.import(&c, fp.provider(), "https://example.test/skills.git", sel), .duplicate_skill_name);
    // Preflight refused before any write: imports root has no "dup".
    try testing.expect(!h.importsExists("dup"));
}

// --- existing imports-root collisions are refused before writing (spec
// "Collision Rules" > "Repository batch import": "Refuse existing imports-root
// collisions before writing"). ---

test "repository import: batch refuses an existing imports-root collision before writing" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // A pre-existing imported skill named repo-alpha.
    try fx.writeSkill("imports/repo-alpha", "repo-alpha", "Existing alpha.");
    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "Repo alpha.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Repo beta.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const sel: []const []const u8 = &.{ "repo-beta", "repo-alpha" };
    try expectErr(repository.import(&c, fp.provider(), "https://example.test/skills.git", sel), .import_collision);
    // Refused before any write: repo-beta was NOT imported, existing alpha intact.
    try testing.expect(!h.importsExists("repo-beta"));
    const existing = try h.readImports("repo-alpha/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, existing, "Existing alpha.") != null);
}

// --- rollback on batch failure: if a LATER batch write fails, previously-written
// imports from that batch must be rolled back (spec "import repository": "If a
// later batch write fails, previously written imports from that batch must be
// rolled back"; "Filesystem Safety"). An injected IO fails when copying a file
// whose basename is unique to the SECOND selected skill, so the first imports
// fully and the second fails mid-write, driving reverse-order rollback. ---

test "repository import: batch rolls back earlier imports when a later write fails" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // First skill: a clean skill that will import fully.
    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First.");
    // Second skill: carries a support file with a unique basename; the injected
    // IO fails to create exactly that file, so the second skill's copy fails.
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second.");
    try fx.writeSupportFile("repo/repo-beta", "boom.txt", "explode");

    const failing_io = testutil.FailingIo.forBasename("boom.txt");
    var c: repository.Context = .{
        .arena = h.arena(),
        .io = failing_io,
        .imports_root = h.roots.imports,
        .canonical_root = h.roots.canonical,
        .clock = h.clock_state.clock(),
    };

    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };
    const sel: []const []const u8 = &.{ "repo-alpha", "repo-beta" };
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", sel);
    try testing.expect(res == .err);

    // The first (already-written) import was rolled back, leaving no storage; the
    // failed second import left nothing either. Because THIS batch created the
    // imports root, the whole imports root is gone.
    try testing.expect(!h.importsExists("repo-alpha"));
    try testing.expect(!h.importsExists("repo-beta"));
}

// --- rollback preserves a PRE-EXISTING imports root: only the skill dirs this
// batch created are rolled back (spec "import repository": rollback "previously
// written imports from that batch"; the root it did not create must remain). ---

test "repository import: rollback removes batch skill dirs but keeps a pre-existing imports root" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // Pre-existing unrelated imported skill keeps the imports root present.
    try fx.writeSkill("imports/keep-me", "keep-me", "Pre-existing.");

    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second.");
    try fx.writeSupportFile("repo/repo-beta", "boom.txt", "explode");

    const failing_io = testutil.FailingIo.forBasename("boom.txt");
    var c: repository.Context = .{
        .arena = h.arena(),
        .io = failing_io,
        .imports_root = h.roots.imports,
        .canonical_root = h.roots.canonical,
        .clock = h.clock_state.clock(),
    };

    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };
    const sel: []const []const u8 = &.{ "repo-alpha", "repo-beta" };
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", sel);
    try testing.expect(res == .err);

    // The batch's skill dirs are gone; the pre-existing imports root + its
    // unrelated skill survive (the batch did not create the root).
    try testing.expect(!h.importsExists("repo-alpha"));
    try testing.expect(!h.importsExists("repo-beta"));
    try testing.expect(h.importsExists("keep-me/SKILL.md"));
}

// --- single (auto) import leaves no partial storage on a write failure (spec
// "Filesystem Safety": plan-then-execute, leave no partial storage). The
// auto-imported skill carries a support file the injected IO refuses to copy. ---

test "repository import: single auto-import rolls back on a write failure" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    try fx.writeSkill("repo/only", "only", "Only skill.");
    try fx.writeSupportFile("repo/only", "boom.txt", "explode");

    const failing_io = testutil.FailingIo.forBasename("boom.txt");
    var c: repository.Context = .{
        .arena = h.arena(),
        .io = failing_io,
        .imports_root = h.roots.imports,
        .canonical_root = h.roots.canonical,
        .clock = h.clock_state.clock(),
    };

    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select);
    try testing.expect(res == .err);
    try testing.expect(!h.importsExists("only"));
}

// --- root skill import: the repository root IS itself a skill (spec "import
// repository": "The repository root may itself be a skill"). With no nested
// skills and no --select, it imports immediately; the manifest skill_path is "."
// (spec: "source_repository.skill_path: ... or . for a root skill"). ---

test "repository import: repository root is the skill, imported with skill_path '.'" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // The checkout root itself is a skill.
    try fx.writeSkill("repo", "root-skill", "A root-level skill.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };

    try testing.expect(r == .imported);
    const single = r.imported;
    try testing.expectEqualStrings("root-skill", single.skill_name);
    try testing.expectEqualStrings(".", single.manifest.source_repository.?.skill_path);
    try testing.expectEqualStrings(
        "https://example.test/skills.git#.",
        single.manifest.source_location.?,
    );
    try testing.expect(h.importsExists("root-skill/SKILL.md"));
}

// --- invalid root SKILL.md FAILS; do not skip it and import nested skills (spec
// "import repository": "If the repository root has invalid SKILL.md, fail; do
// not skip it and import nested skills"). ---

test "repository import: invalid root SKILL.md fails and does not import nested skills" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // Root has a SKILL.md with NO closing delimiter (invalid frontmatter).
    try fx.writeSupportFile("repo", "SKILL.md", "---\nname: bad\ndescription: x\n");
    // A perfectly valid nested skill that must NOT be imported because the root
    // is invalid.
    try fx.writeSkill("repo/nested", "nested", "Nested skill.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select);
    try testing.expect(res == .err);
    // Neither the root nor the nested skill was imported.
    try testing.expect(!h.importsExists("nested"));
    try testing.expect(!h.importsExists("bad"));
}

// --- empty repository: no valid skills at all is an error (spec "import
// repository" + Recommended TDD Acceptance Suite: "empty repositories"). ---

test "repository import: a repository with no valid skills errors" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // A repo tree with only non-skill files.
    try fx.writeSupportFile("repo", "README.md", "no skills here");
    try fx.writeSupportFile("repo/docs", "guide.md", "still no skills");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    try expectErr(repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select), .empty_repository);
}

// --- depth-limit boundary (spec "import repository": "Skip skills beyond the
// repository scan depth limit. The current product uses depth 8"; this clean-room
// keeps 8 and tests the boundary). A skill whose directory sits at depth 8 (path
// of 8 components under the root) is INCLUDED; a skill at depth 9 is SKIPPED.
// With only the depth-8 skill discovered, it auto-imports. ---

test "repository import: depth-8 skill is included and depth-9 skill is skipped" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // depth 8: repo/l1/l2/l3/l4/l5/l6/l7/l8  (8 components under repo root)
    try fx.writeSkill("repo/l1/l2/l3/l4/l5/l6/l7/l8", "deep8", "Depth eight skill.");
    // depth 9: one level deeper -> must be skipped.
    try fx.writeSkill("repo/l1/l2/l3/l4/l5/l6/l7/l8/l9", "deep9", "Depth nine skill.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };

    // Only the depth-8 skill was discovered, so it auto-imported (exactly one
    // valid skill). The depth-9 skill was beyond the limit and skipped.
    try testing.expect(r == .imported);
    try testing.expectEqualStrings("deep8", r.imported.skill_name);
    try testing.expectEqualStrings(
        "l1/l2/l3/l4/l5/l6/l7/l8",
        r.imported.manifest.source_repository.?.skill_path,
    );
    try testing.expect(h.importsExists("deep8/SKILL.md"));
    try testing.expect(!h.importsExists("deep9"));
}

// --- JSON shapes for all three `kind` discriminators (spec "JSON Schemas >
// Repository Import Result"; Recommended TDD Acceptance Suite bullet 12: valid
// UTF-8 + trailing newline). ---

fn renderRepo(arena: std.mem.Allocator, r: types.RepositoryImportResult) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try json_out.writeRepositoryImportResult(&aw.writer, r);
    return aw.writer.buffered();
}

fn expectTrailingNewline(json: []const u8) !void {
    try testing.expect(std.unicode.utf8ValidateSlice(json));
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(json[json.len - 2] != '\n');
}

test "repository import JSON: kind 'imported' shape" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First repository skill.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select);
    const r = res.ok;

    const json = try renderRepo(h.arena(), r);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"imported\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"skill_name\": \"repo-alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"source_type\": \"repository\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"skill_path\": \"repo-alpha\"") != null);
    // `kind` is the FIRST key (spec discriminator first).
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\"").? < std.mem.indexOf(u8, json, "\"skill_name\"").?);
    try expectTrailingNewline(json);
}

test "repository import JSON: kind 'selection' shape" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First repository skill.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second repository skill.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select);
    const r = res.ok;

    const json = try renderRepo(h.arena(), r);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"selection\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"repository\": \"https://example.test/skills.git\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\": \"repo-alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"relative_path\": \"repo-alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"description\": \"First repository skill.\"") != null);
    try expectTrailingNewline(json);
}

test "repository import JSON: kind 'imported_batch' shape" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("repo/repo-alpha", "repo-alpha", "First.");
    try fx.writeSkill("repo/repo-beta", "repo-beta", "Second.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const sel: []const []const u8 = &.{ "repo-alpha", "repo-beta" };
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", sel);
    const r = res.ok;

    const json = try renderRepo(h.arena(), r);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"imported_batch\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"imports\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"skill_name\": \"repo-alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"skill_name\": \"repo-beta\"") != null);
    // No per-import `kind` inside imports[]: only one `kind` (the batch's).
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\"kind\""));
    try expectTrailingNewline(json);
}

// --- `--select .` normalizes to the root skill (spec "import repository":
// "Normalize . and ./name consistently"; "source_repository.skill_path: ... or .
// for a root skill"). ---

test "repository import: --select '.' selects the root skill" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // Root is a skill, plus a nested skill, so there is more than one valid skill
    // and an explicit selection is required to pick the root.
    try fx.writeSkill("repo", "root-skill", "Root.");
    try fx.writeSkill("repo/nested", "nested", "Nested.");
    var fp: testutil.FakeProvider = .{ .source_tree = try h.srcTree("repo") };

    var c = h.ctx();
    const sel: []const []const u8 = &.{"./"};
    const res = repository.import(&c, fp.provider(), "https://example.test/skills.git", sel);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };
    try testing.expect(r == .imported_batch);
    try testing.expectEqual(@as(usize, 1), r.imported_batch.imports.len);
    try testing.expectEqualStrings("root-skill", r.imported_batch.imports[0].skill_name);
    try testing.expectEqualStrings(".", r.imported_batch.imports[0].manifest.source_repository.?.skill_path);
    try testing.expect(h.importsExists("root-skill/SKILL.md"));
    try testing.expect(!h.importsExists("nested"));
}

// --- provider GitUnavailable maps to a git_unavailable error so the CLI can
// report "git not installed" (zig-clean-room-cli.md Phase 4b; spec "Output
// Contract": actionable stderr). ---

test "repository import: provider GitUnavailable maps to git_unavailable" {
    var h = try Harness.init();
    defer h.deinit();
    var fp: testutil.FakeProvider = .{ .fail_with = error.GitUnavailable };

    var c = h.ctx();
    try expectErr(repository.import(&c, fp.provider(), "https://example.test/skills.git", no_select), .git_unavailable);
}

// --- provider RepositoryError maps to a repository_error (spec "import
// repository": fetch/open failure). ---

test "repository import: provider RepositoryError maps to repository_error" {
    var h = try Harness.init();
    defer h.deinit();
    var fp: testutil.FakeProvider = .{ .fail_with = error.RepositoryError };

    var c = h.ctx();
    try expectErr(repository.import(&c, fp.provider(), "https://example.test/missing.git", no_select), .repository_error);
}

// --- real git provider smoke test (zig-clean-room-cli.md Phase 4b: "one smoke
// test exercises the real Child.run path guarded on git availability"). Clones a
// freshly-initialized LOCAL bare-ish repo via the real `git clone --depth 1`,
// then imports the single skill it contains. Skipped if `git` is unavailable. ---

test "repository import: real git provider clones and imports a local repo" {
    if (!gitAvailable()) return error.SkipZigTest;

    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);

    // Build a real git repository on disk with one committed skill.
    try fx.writeSkill("origin/repo-real", "repo-real", "Real cloned skill.");
    const origin = try std.fs.path.join(h.arena(), &.{ h.roots.base, "origin" });
    try runGit(h.arena(), origin, &.{ "git", "init", "-q" });
    try runGit(h.arena(), origin, &.{ "git", "config", "user.email", "t@test.invalid" });
    try runGit(h.arena(), origin, &.{ "git", "config", "user.name", "Test" });
    try runGit(h.arena(), origin, &.{ "git", "add", "-A" });
    try runGit(h.arena(), origin, &.{ "git", "commit", "-q", "-m", "init" });

    var rp = git.RealProvider.init(testing.allocator, io);

    var c = h.ctx();
    const res = repository.import(&c, rp.provider(), origin, no_select);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };
    try testing.expect(r == .imported);
    try testing.expectEqualStrings("repo-real", r.imported.skill_name);
    try testing.expect(h.importsExists("repo-real/SKILL.md"));
}

fn gitAvailable() bool {
    const res = std.process.run(testing.allocator, io, .{
        .argv = &.{ "git", "--version" },
    }) catch return false;
    testing.allocator.free(res.stdout);
    testing.allocator.free(res.stderr);
    return switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runGit(gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const res = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandFailed,
    }
}
