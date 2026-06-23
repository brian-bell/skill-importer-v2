//! Tests for import.zig (cli-clean-room-spec.md "import markdown" / "import path"
//! / "import url", "Collision Rules", "Filesystem Safety", "JSON Schemas >
//! Import Result"). Covers the spec "Recommended TDD Acceptance Suite" bullets
//! 4-6: markdown validate + no-partial-on-failure; local file + local dir
//! preserving supporting files; reject symlink / reserved import.json /
//! imports-root-inside-source; url timeout / over-size / invalid-UTF-8 with no
//! partial storage; import-result JSON shape.
//!
//! Safety: every test runs inside a unique temp tree (CLAUDE.md hard rule).

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const importmod = @import("import.zig");
const types = @import("types.zig");
const json_out = @import("json_out.zig");
const manifest_mod = @import("manifest.zig");
const testutil = @import("testutil.zig");
const net = @import("net.zig");

// --- helpers ---------------------------------------------------------------

/// A test harness bundling a TmpRoots, an arena, and a fixed clock.
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

    fn clock(self: *Harness) testutil.Clock {
        return self.clock_state.clock();
    }

    fn ctx(self: *Harness) importmod.Context {
        return .{
            .arena = self.arena(),
            .io = io,
            .imports_root = self.roots.imports,
            .canonical_root = self.roots.canonical,
            .clock = self.clock(),
        };
    }

    /// True iff `<imports>/<sub>` exists on disk (no-follow).
    fn importsExists(self: *Harness, sub: []const u8) bool {
        const p = std.fs.path.join(testing.allocator, &.{ "imports", sub }) catch return false;
        defer testing.allocator.free(p);
        _ = self.roots.dir().statFile(io, p, .{ .follow_symlinks = false }) catch return false;
        return true;
    }

    /// Read a file under the imports root into arena bytes.
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

const valid_md = "---\nname: alpha\ndescription: Alpha skill.\n---\nBody text.\n";

// --- markdown happy path + JSON shape (spec "import markdown" + "Import
// Result"). ---

test "import markdown writes SKILL.md + import.json and returns the result shape" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();

    const res = importmod.markdown(&c, valid_md, "clipboard");
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };

    // Result fields (spec "Import Result").
    try testing.expectEqualStrings("alpha", r.skill_name);
    try testing.expect(std.mem.endsWith(u8, r.skill_path, "imports/alpha"));
    try testing.expect(std.mem.endsWith(u8, r.manifest_path, "imports/alpha/import.json"));
    try testing.expectEqual(types.ImportSourceType.markdown, r.manifest.source_type);
    try testing.expectEqualStrings("clipboard", r.manifest.source_location.?);
    try testing.expectEqual(@as(i64, 1710000000), r.manifest.imported_at);
    try testing.expect(std.mem.startsWith(u8, r.manifest.content_hash, "sha256:"));
    try testing.expect(!r.manifest.promoted);

    // Actions: create_directory, write_skill, write_manifest (spec "Import
    // Result" example).
    try testing.expectEqual(@as(usize, 3), r.actions.len);
    try testing.expectEqual(types.ImportActionKind.create_directory, r.actions[0].action);
    try testing.expectEqual(types.ImportActionKind.write_skill, r.actions[1].action);
    try testing.expectEqual(types.ImportActionKind.write_manifest, r.actions[2].action);

    // On disk.
    const skill = try h.readImports("alpha/SKILL.md");
    try testing.expectEqualStrings(valid_md, skill);
    const manifest = try h.readImports("alpha/import.json");
    try testing.expect(std.mem.indexOf(u8, manifest, "\"source_type\": \"markdown\"") != null);
    // import.json has no trailing newline (spec decision).
    try testing.expect(manifest[manifest.len - 1] != '\n');
}

// --- markdown validation failures leave no storage (spec "Skill Metadata" +
// "Markdown imports ... leave no partial storage on failure"). ---

test "import markdown with missing closing delimiter fails and writes nothing" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();

    const bad = "---\nname: alpha\ndescription: x\n"; // no closing ---
    try expectErr(importmod.markdown(&c, bad, null), .missing_close_delimiter);
    try testing.expect(!h.importsExists("alpha"));
}

test "import markdown with empty name fails and writes nothing" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();

    const bad = "---\nname:\ndescription: x\n---\n";
    try expectErr(importmod.markdown(&c, bad, null), .missing_name);
    // No directory created anywhere under imports.
    try testing.expect(!h.importsExists("alpha"));
}

// --- collision within imports root by directory name (spec "Collision Rules":
// "Refuse collisions within imports root by directory name"). ---

test "import markdown refuses an existing imports-root directory of the same name" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    // Pre-existing imported skill named alpha.
    try fx.writeSkill("imports/alpha", "alpha", "Existing alpha.");

    var c = h.ctx();
    try expectErr(importmod.markdown(&c, valid_md, null), .import_collision);

    // The existing skill is untouched.
    const skill = try h.readImports("alpha/SKILL.md");
    try testing.expect(std.mem.indexOf(u8, skill, "Existing alpha.") != null);
}

// --- collision within imports root by frontmatter name even when the directory
// name differs (spec "Collision Rules": "or by SKILL.md frontmatter name"). ---

test "import markdown refuses a frontmatter-name collision under a different dir" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    // An imported skill stored under dir "other" but whose frontmatter name is
    // "alpha" collides with a new alpha import.
    try fx.writeSkill("imports/other", "alpha", "Existing alpha via other dir.");

    var c = h.ctx();
    try expectErr(importmod.markdown(&c, valid_md, null), .import_collision);
    try testing.expect(!h.importsExists("alpha"));
}

// --- canonical collisions are ALLOWED (spec "Collision Rules": "Allow
// collisions with canonical root"). ---

test "import markdown allows a canonical-root collision (replacement draft)" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("canonical/alpha", "alpha", "Canonical alpha.");

    var c = h.ctx();
    const res = importmod.markdown(&c, valid_md, null);
    try testing.expect(res == .ok);
    try testing.expect(h.importsExists("alpha"));
}

// --- rollback on a mid-store failure leaves no partial storage (spec
// "Filesystem Safety": plan-then-execute; "leave no partial storage on
// failure"). A regular file already occupying the target dir path makes the
// create_directory step fail; the operation must error and create nothing. ---

test "import markdown rolls back and leaves no skill directory on a store failure" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    // A regular file (not a directory) sits where imports/alpha would go. It is
    // not a same-name *directory* collision, so the create_directory step is the
    // one that fails.
    try fx.writeSupportFile("imports", "alpha", "i am a file, not a dir");

    var c = h.ctx();
    const res = importmod.markdown(&c, valid_md, null);
    try testing.expect(res == .err);

    // The stray file remains a file; no SKILL.md / import.json was written under
    // it, i.e. no partial skill directory was left behind.
    const st = try h.roots.dir().statFile(io, "imports/alpha", .{ .follow_symlinks = false });
    try testing.expect(st.kind == .file);
    try testing.expect(!h.importsExists("alpha/SKILL.md"));
    try testing.expect(!h.importsExists("alpha/import.json"));
}

// --- import path: local Markdown file (spec "import path": Markdown file
// behavior). ---

test "import path imports a local Markdown file as local_path" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    // A standalone markdown file outside the roots.
    try fx.writeSupportFile("src", "alpha.md", valid_md);
    const src_path = try std.fs.path.join(h.arena(), &.{ h.roots.base, "src", "alpha.md" });

    var c = h.ctx();
    const res = importmod.path(&c, src_path);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };
    try testing.expectEqualStrings("alpha", r.skill_name);
    try testing.expectEqual(types.ImportSourceType.local_path, r.manifest.source_type);
    try testing.expectEqualStrings(src_path, r.manifest.source_location.?);

    const skill = try h.readImports("alpha/SKILL.md");
    try testing.expectEqualStrings(valid_md, skill);
}

// --- import path: local directory preserves supporting files (spec "import
// path": Directory behavior; "Local directory imports preserve supporting
// files"). ---

test "import path imports a directory and preserves supporting files" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("src/alpha", "alpha", "Alpha dir skill.");
    try fx.writeSupportFile("src/alpha", "helper.txt", "support data");
    try fx.writeSupportFile("src/alpha/nested", "deep.txt", "deep data");
    const src_dir = try std.fs.path.join(h.arena(), &.{ h.roots.base, "src", "alpha" });

    var c = h.ctx();
    const res = importmod.path(&c, src_dir);
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };
    try testing.expectEqualStrings("alpha", r.skill_name);

    // Supporting files copied, preserving relative layout.
    const helper = try h.readImports("alpha/helper.txt");
    try testing.expectEqualStrings("support data", helper);
    const deep = try h.readImports("alpha/nested/deep.txt");
    try testing.expectEqualStrings("deep data", deep);
    // import.json present; the source had none.
    try testing.expect(h.importsExists("alpha/import.json"));

    // Actions include copy_file entries (spec "Import action values").
    var saw_copy = false;
    for (r.actions) |a| {
        if (a.action == .copy_file) saw_copy = true;
    }
    try testing.expect(saw_copy);
}

// --- import path: directory must contain SKILL.md (spec "import path":
// "The directory must contain SKILL.md"). ---

test "import path rejects a directory without SKILL.md" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSupportFile("src/nope", "readme.txt", "no skill here");
    const src_dir = try std.fs.path.join(h.arena(), &.{ h.roots.base, "src", "nope" });

    var c = h.ctx();
    const res = importmod.path(&c, src_dir);
    try testing.expect(res == .err);
}

// --- import path: reject symlinks inside the source directory (spec "import
// path": "Symlinks and unsupported filesystem entries are rejected."). ---

test "import path rejects a directory containing a symlink and writes nothing" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("src/alpha", "alpha", "Alpha.");
    try fx.writeSupportFile("src/alpha", "real.txt", "data");
    // A symlink inside the source skill directory.
    try fx.symlink("real.txt", "src/alpha/link.txt");
    const src_dir = try std.fs.path.join(h.arena(), &.{ h.roots.base, "src", "alpha" });

    var c = h.ctx();
    try expectErr(importmod.path(&c, src_dir), .unsupported_entry);
    try testing.expect(!h.importsExists("alpha"));
}

// --- import path: reserved import.json in source (spec "import path":
// "import.json in the source directory is reserved and must be rejected."). ---

test "import path rejects a source directory containing import.json" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("src/alpha", "alpha", "Alpha.");
    try fx.writeRawManifest("src/alpha", "{}");
    const src_dir = try std.fs.path.join(h.arena(), &.{ h.roots.base, "src", "alpha" });

    var c = h.ctx();
    try expectErr(importmod.path(&c, src_dir), .reserved_manifest_in_source);
    try testing.expect(!h.importsExists("alpha"));
}

// --- import path: imports root must not be inside the source dir (spec "import
// path": "The imports root must not be inside the source directory."). ---

test "import path rejects when the imports root is inside the source directory" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    // Make the source directory an ancestor of the imports root: use base as the
    // source (imports = base/imports lives inside base).
    try fx.writeSkill(".", "alpha", "Root-as-source.");
    const src_dir = try h.arena().dupe(u8, h.roots.base);

    var c = h.ctx();
    try expectErr(importmod.path(&c, src_dir), .imports_root_inside_source);
}

// --- import url happy path (spec "import url"). Uses the fake fetcher. ---

test "import url stores fetched markdown as url source" {
    var h = try Harness.init();
    defer h.deinit();
    var ff: testutil.FakeFetcher = .{ .body = valid_md };

    var c = h.ctx();
    const res = importmod.url(&c, ff.fetcher(), "https://example.test/alpha.md");
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };
    try testing.expectEqualStrings("alpha", r.skill_name);
    try testing.expectEqual(types.ImportSourceType.url, r.manifest.source_type);
    try testing.expectEqualStrings("https://example.test/alpha.md", r.manifest.source_location.?);

    const skill = try h.readImports("alpha/SKILL.md");
    try testing.expectEqualStrings(valid_md, skill);
}

// --- import url failures leave no storage (spec "import url": "On fetch, size,
// UTF-8, or validation failure, do not create import storage."). ---

test "import url timeout creates no storage" {
    var h = try Harness.init();
    defer h.deinit();
    var ff: testutil.FakeFetcher = .{ .fail_with = error.Timeout };

    var c = h.ctx();
    try expectErr(importmod.url(&c, ff.fetcher(), "https://example.test/slow.md"), .timeout);
    try testing.expect(!h.importsExists("alpha"));
}

test "import url over-size creates no storage" {
    var h = try Harness.init();
    defer h.deinit();
    var ff: testutil.FakeFetcher = .{ .fail_with = error.SizeExceeded };

    var c = h.ctx();
    try expectErr(importmod.url(&c, ff.fetcher(), "https://example.test/big.md"), .size_exceeded);
    try testing.expect(!h.importsExists("alpha"));
}

test "import url invalid UTF-8 creates no storage" {
    var h = try Harness.init();
    defer h.deinit();
    var ff: testutil.FakeFetcher = .{ .fail_with = error.InvalidUtf8 };

    var c = h.ctx();
    try expectErr(importmod.url(&c, ff.fetcher(), "https://example.test/bin.md"), .invalid_utf8);
    try testing.expect(!h.importsExists("alpha"));
}

test "import url with invalid frontmatter creates no storage" {
    var h = try Harness.init();
    defer h.deinit();
    var ff: testutil.FakeFetcher = .{ .body = "no frontmatter here" };

    var c = h.ctx();
    const res = importmod.url(&c, ff.fetcher(), "https://example.test/plain.md");
    try testing.expect(res == .err);
    try testing.expect(!h.importsExists("alpha"));
}

// --- import-result JSON shape end-to-end (spec "JSON Schemas > Import Result";
// acceptance bullet 12: valid UTF-8 + trailing newline). ---

test "import result renders the spec JSON shape with a trailing newline" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();

    const res = importmod.markdown(&c, valid_md, "clipboard");
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };

    var aw: std.Io.Writer.Allocating = .init(h.arena());
    try json_out.writeImportResult(&aw.writer, r);
    const json = aw.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, json, "\"skill_name\": \"alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\": \"create_directory\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\": \"write_skill\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\": \"write_manifest\"") != null);
    // Valid UTF-8 + exactly one trailing newline (spec "Output Contract").
    try testing.expect(std.unicode.utf8ValidateSlice(json));
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(json[json.len - 2] != '\n');
}

/// Render an import result to its JSON string (owned by `arena`).
fn renderImportJson(h: *Harness, r: types.ImportResult) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(h.arena());
    try json_out.writeImportResult(&aw.writer, r);
    return aw.toOwnedSlice();
}

/// Byte offset of the n-th (0-based) occurrence of `needle` in `hay`, or null.
fn nthIndex(hay: []const u8, needle: []const u8, n: usize) ?usize {
    var start: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, hay, start, needle)) |i| {
        if (seen == n) return i;
        seen += 1;
        start = i + needle.len;
    }
    return null;
}

// --- H1(c): markdown import result WIRE shape. Locks that the `actions` array is
// rendered in spec order (create_directory < write_skill < write_manifest) on
// the wire, that the manifest OMITS `source_repository` for a markdown import
// (not null), and that there is exactly one trailing newline. ---
test "import result wire: markdown action order and source_repository omitted" {
    var h = try Harness.init();
    defer h.deinit();
    var c = h.ctx();

    const r = switch (importmod.markdown(&c, valid_md, "clipboard")) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };
    const json = try renderImportJson(&h, r);

    // Action order on the wire: create_directory, write_skill, write_manifest.
    const i_create = std.mem.indexOf(u8, json, "\"action\": \"create_directory\"").?;
    const i_write_skill = std.mem.indexOf(u8, json, "\"action\": \"write_skill\"").?;
    const i_write_manifest = std.mem.indexOf(u8, json, "\"action\": \"write_manifest\"").?;
    try testing.expect(i_create < i_write_skill);
    try testing.expect(i_write_skill < i_write_manifest);

    // source_repository OMITTED (not null) for a markdown import; source_type
    // markdown; source_location present.
    try testing.expect(std.mem.indexOf(u8, json, "\"source_repository\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "null") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"source_type\": \"markdown\"") != null);

    // Exactly one trailing newline (spec "Output Contract").
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(json[json.len - 2] != '\n');
}

// --- H1(c): directory import result WIRE shape. A directory import copies
// supporting files, so the action array is create_directory, copy_file*,
// write_manifest. Locks that EVERY copy_file falls between create_directory and
// write_manifest on the wire, and that source_repository is omitted for a
// local_path import. ---
test "import result wire: directory copy_file actions ordered between create_directory and write_manifest" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("src/alpha", "alpha", "Alpha dir skill.");
    try fx.writeSupportFile("src/alpha", "helper.txt", "support data");
    try fx.writeSupportFile("src/alpha/nested", "deep.txt", "deep data");
    const src_dir = try std.fs.path.join(h.arena(), &.{ h.roots.base, "src", "alpha" });

    var c = h.ctx();
    const r = switch (importmod.path(&c, src_dir)) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };
    const json = try renderImportJson(&h, r);

    const i_create = std.mem.indexOf(u8, json, "\"action\": \"create_directory\"").?;
    const i_write_manifest = std.mem.indexOf(u8, json, "\"action\": \"write_manifest\"").?;
    try testing.expect(i_create < i_write_manifest);

    // At least one copy_file, and every copy_file is between create_directory and
    // write_manifest.
    const first_copy = std.mem.indexOf(u8, json, "\"action\": \"copy_file\"");
    try testing.expect(first_copy != null);
    var idx: usize = 0;
    while (nthIndex(json, "\"action\": \"copy_file\"", idx)) |pos| : (idx += 1) {
        try testing.expect(i_create < pos);
        try testing.expect(pos < i_write_manifest);
    }

    // local_path import => source_repository omitted (not null).
    try testing.expect(std.mem.indexOf(u8, json, "\"source_type\": \"local_path\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"source_repository\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "null") == null);
}

// --- the imported_at persisted in import.json equals the imported_at in the
// returned result (spec "Import Manifest": imported_at; "JSON Schemas > Import
// Result": the same manifest object). The clock advances on every call, so a
// second clock.now() for the on-disk write would diverge from the result. ---

test "import markdown persists the same imported_at on disk and in the result" {
    var h = try Harness.init();
    defer h.deinit();
    // A clock that advances on EVERY call. If store() and executeStore() each
    // call clock.now() independently, the on-disk imported_at and the result's
    // imported_at differ and this test fails.
    var clk: testutil.IncrementingClock = .{ .value = 1710000000, .step = 1000 };
    var c: importmod.Context = .{
        .arena = h.arena(),
        .io = io,
        .imports_root = h.roots.imports,
        .canonical_root = h.roots.canonical,
        .clock = clk.clock(),
    };

    const res = importmod.markdown(&c, valid_md, "clipboard");
    const r = switch (res) {
        .ok => |r| r,
        .err => return error.ImportFailed,
    };

    // Read import.json from disk and parse its imported_at.
    const bytes = try h.readImports("alpha/import.json");
    const parsed = try manifest_mod.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(r.manifest.imported_at, parsed.value.imported_at);
    // And exactly ONE now() call was made for this import.
    try testing.expectEqual(@as(usize, 1), clk.calls);
}

// --- import path: the source path argument is ITSELF a symlink (spec "import
// path": "Symlinks and unsupported filesystem entries are rejected."). This
// guards the top-level classification branch, distinct from a symlink found
// *inside* a source directory. ---

test "import path rejects a source path that is itself a symlink and writes nothing" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    // A real skill directory, plus a symlink pointing at it.
    try fx.writeSkill("src/alpha", "alpha", "Alpha.");
    try fx.symlink("alpha", "src/alpha-link");
    const link_path = try std.fs.path.join(h.arena(), &.{ h.roots.base, "src", "alpha-link" });

    var c = h.ctx();
    try expectErr(importmod.path(&c, link_path), .unsupported_entry);
    // No import storage was created.
    try testing.expect(!h.importsExists("alpha"));
    try testing.expect(!h.importsExists("alpha-link"));
}

// --- partial-write rollback: a failure AFTER create_directory must delete the
// directory WE created, leaving no partial storage (spec "Filesystem Safety":
// plan-then-execute; "leave no partial storage on failure"; Recommended TDD
// Acceptance Suite: "Markdown imports ... leave no partial storage on
// failure"). An injected IO fails the import.json write so create_directory
// succeeds first, driving the genuine rollback deleteTree branch. ---

test "import markdown rolls back the created directory when a later write fails" {
    var h = try Harness.init();
    defer h.deinit();
    // IO that lets the directory + SKILL.md be created, but fails the
    // import.json write — the only step after create_directory.
    const failing_io = testutil.FailingIo.forBasename("import.json");
    var c: importmod.Context = .{
        .arena = h.arena(),
        .io = failing_io,
        .imports_root = h.roots.imports,
        .canonical_root = h.roots.canonical,
        .clock = h.clock(),
    };

    const res = importmod.markdown(&c, valid_md, null);
    try testing.expect(res == .err);

    // The directory we created (and its partial SKILL.md) were rolled back:
    // nothing remains under imports/alpha.
    try testing.expect(!h.importsExists("alpha"));
    try testing.expect(!h.importsExists("alpha/SKILL.md"));
    try testing.expect(!h.importsExists("alpha/import.json"));
}
