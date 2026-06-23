//! Tests for discovery (cli-clean-room-spec.md "list" + "JSON Schemas > Inventory").
//! Covers spec "Recommended TDD Acceptance Suite" bullets 1-3:
//!   - deterministic JSON for canonical, imported, promoted, enabled, external,
//!     broken, and agent-only skills,
//!   - missing roots -> empty inventory (not error),
//!   - malformed import manifests for valid imported skills fail discovery.
//! Safety: everything runs inside a unique temp tree (CLAUDE.md hard rule).

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const discovery = @import("discovery.zig");
const json_out = @import("json_out.zig");
const types = @import("types.zig");
const testutil = @import("testutil.zig");

/// Resolve the four root absolute paths from a TmpRoots into the discovery
/// `Roots` struct expected by `discover`.
fn rootsOf(roots: *testutil.TmpRoots) discovery.Roots {
    return .{
        .canonical = roots.canonical,
        .imports = roots.imports,
        .claude_code = roots.claude,
        .codex = roots.codex,
    };
}

/// Run discovery and return the owned Inventory + arena; caller deinits arena.
fn discover(roots: *testutil.TmpRoots, arena: std.mem.Allocator) !types.Inventory {
    var res = discovery.discover(arena, io, rootsOf(roots));
    switch (res) {
        .ok => |inv| return inv,
        .err => |*e| {
            e.deinit(arena);
            return error.DiscoveryFailed;
        },
    }
}

// --- missing roots -> empty inventory (spec: "Missing roots are treated as
// empty during discovery."; acceptance bullet 2). ---

test "missing roots produce an empty inventory rather than an error" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    // No roots are materialized on disk.

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 0), inv.skills.len);
    try testing.expectEqual(@as(usize, 0), inv.source_repositories.len);
}

/// Render an inventory to its JSON string (owned by `arena`).
fn renderJson(inv: types.Inventory, arena: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try json_out.writeInventory(&aw.writer, inv);
    return aw.toOwnedSlice();
}

// --- empty inventory JSON shape + trailing newline (spec "Output Contract":
// "terminated by a newline"; acceptance bullet 12). ---

test "empty inventory emits empty arrays and a single trailing newline" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    const json = try renderJson(inv, arena);

    try testing.expectEqualStrings(
        \\{
        \\  "skills": [],
        \\  "source_repositories": []
        \\}
        \\
    , json);
    // Exactly one trailing newline.
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(json[json.len - 2] != '\n');
}

// --- a single canonical skill: full key order, omit description? no (present),
// omit source_repository? yes (absent), enablement false for missing agents
// (spec "Inventory" schema + key order; acceptance bullet 1). ---

test "canonical skill emits full entry with omitted source_repository" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/example-skill", "example-skill", "Example description.");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    const json = try renderJson(inv, arena);

    try testing.expectEqualStrings(
        \\{
        \\  "skills": [
        \\    {
        \\      "name": "example-skill",
        \\      "description": "Example description.",
        \\      "source": "canonical",
        \\      "promoted": false,
        \\      "enablement": {
        \\        "claude_code": false,
        \\        "codex": false
        \\      },
        \\      "agent_entries": {
        \\        "claude_code": "missing",
        \\        "codex": "missing"
        \\      }
        \\    }
        \\  ],
        \\  "source_repositories": []
        \\}
        \\
    , json);
}

// --- enabled canonical skill: managed canonical_symlink => enablement true for
// that agent (spec "Inventory": enablement true for canonical_symlink). ---

test "enabled canonical skill reports canonical_symlink and enablement true" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/example-skill", "example-skill", "Example description.");
    try fx.managedSymlink(.claude, "example-skill", .canonical, "example-skill");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    const s = inv.skills[0];
    try testing.expectEqual(types.SkillSource.canonical, s.source);
    try testing.expectEqual(types.AgentEntryStatus.canonical_symlink, s.agent_entries.claude_code);
    try testing.expectEqual(types.AgentEntryStatus.missing, s.agent_entries.codex);
    try testing.expect(s.enablement.claude_code);
    try testing.expect(!s.enablement.codex);
}

// --- imported + promoted + repository metadata (spec "Inventory":
// source_repository on imported repo skills; promoted from manifest;
// source_repositories grouping). ---

test "imported promoted repository skill carries source_repository and group" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("imports/repo-alpha", "repo-alpha", "Alpha repo skill.");
    try fx.writeManifest("imports/repo-alpha", .{
        .source_type = .repository,
        .source_location = "https://example.test/skills.git#helpers/repo-alpha",
        .source_repository = .{
            .repository = "https://example.test/skills.git",
            .skill_path = "helpers/repo-alpha",
        },
        .imported_at = 1710000000,
        .content_hash = "sha256:deadbeef",
        .promoted = true,
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    const json = try renderJson(inv, arena);

    try testing.expectEqualStrings(
        \\{
        \\  "skills": [
        \\    {
        \\      "name": "repo-alpha",
        \\      "description": "Alpha repo skill.",
        \\      "source": "imported",
        \\      "source_repository": {
        \\        "repository": "https://example.test/skills.git",
        \\        "skill_path": "helpers/repo-alpha"
        \\      },
        \\      "promoted": true,
        \\      "enablement": {
        \\        "claude_code": false,
        \\        "codex": false
        \\      },
        \\      "agent_entries": {
        \\        "claude_code": "missing",
        \\        "codex": "missing"
        \\      }
        \\    }
        \\  ],
        \\  "source_repositories": [
        \\    {
        \\      "repository": "https://example.test/skills.git",
        \\      "skills": [
        \\        {
        \\          "skill_name": "repo-alpha",
        \\          "skill_path": "helpers/repo-alpha"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    , json);
}

/// Discover, expecting an error of the given kind (spec discovery failures).
fn expectDiscoverError(roots: *testutil.TmpRoots, arena: std.mem.Allocator, kind: @import("result.zig").ErrorKind) !void {
    var res = discovery.discover(arena, io, rootsOf(roots));
    switch (res) {
        .ok => return error.UnexpectedSuccess,
        .err => |*e| {
            defer e.deinit(arena);
            try testing.expectEqual(kind, e.kind);
        },
    }
}

// --- malformed import.json for an otherwise-valid imported skill is an error
// (spec "list": "malformed import.json ... is an error"; acceptance bullet 3). ---

test "malformed import.json for a valid imported skill fails discovery" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("imports/broken-manifest", "broken-manifest", "Has a bad manifest.");
    try fx.writeRawManifest("imports/broken-manifest", "{ this is not valid json ");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectDiscoverError(&roots, arena, .malformed_manifest);
}

// --- an imported skill MAY omit import.json (spec "list": "Imported skills may
// include import.json"): absent manifest is valid, source imported, unpromoted. ---

test "imported skill without import.json is valid and unpromoted" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("imports/no-manifest", "no-manifest", "No manifest here.");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    try testing.expectEqual(types.SkillSource.imported, inv.skills[0].source);
    try testing.expect(!inv.skills[0].promoted);
    try testing.expect(inv.skills[0].source_repository == null);
}

// --- imported_symlink: a managed symlink whose target is in the imports root
// (spec "Inventory": imported_symlink; enablement true). ---

test "imported skill enabled via imported_symlink reports imported_symlink" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("imports/draft", "draft", "Draft skill.");
    try fx.managedSymlink(.codex, "draft", .imports, "draft");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    const s = inv.skills[0];
    try testing.expectEqual(types.SkillSource.imported, s.source);
    try testing.expectEqual(types.AgentEntryStatus.imported_symlink, s.agent_entries.codex);
    try testing.expect(s.enablement.codex);
}

// --- external_symlink: a symlink to a target OUTSIDE managed roots (spec
// "Terms": External entry / spec "Inventory": external_symlink; enablement
// true). The same-named canonical skill keeps source canonical. ---

test "external_symlink to a target outside managed roots, enablement true" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/example-skill", "example-skill", "Example.");
    // A real external target outside any managed root, and a symlink to it.
    try fx.writeSupportFile("outside/example-skill", "SKILL.md", "x");
    try roots.makeRoot(.claude);
    const ext_target = try std.fs.path.join(testing.allocator, &.{ roots.base, "outside", "example-skill" });
    defer testing.allocator.free(ext_target);
    try fx.symlink(ext_target, "claude/example-skill");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    const s = inv.skills[0];
    try testing.expectEqual(types.AgentEntryStatus.external_symlink, s.agent_entries.claude_code);
    try testing.expect(s.enablement.claude_code);
}

// --- managed symlink reached through a SYMLINKED ANCESTOR component classifies
// as canonical_symlink, not external_symlink (spec "Inventory":
// canonical_symlink; "Terms": External entry == "symlink to a target OUTSIDE
// managed roots"). Regression: classifyAgentEntry must resolve BOTH the link
// target and the canonical/imports roots with the same symlink policy. If the
// roots are realpath'd (intermediate symlinks resolved) but the on-disk link
// target keeps its un-resolved spelling, isInside() prefix-compares the realpath
// against the un-resolved path, returns false, and a true canonical_symlink is
// misreported as external_symlink -- flipping enablement classification and
// making a managed entry look External (which mutating commands must refuse). ---

test "managed symlink through a symlinked ancestor reports canonical_symlink" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    const gpa = testing.allocator;

    // Real on-disk tree under <base>/real/{canonical,claude}. `link` is a symlink
    // to `real`, so every path spelled through <base>/link/... has a symlinked
    // ancestor component (mirrors macOS /tmp->/private/tmp, a symlinked $HOME, or
    // a canonical_root reached via a symlinked dev dir).
    try roots.dir().createDirPath(io, "real/canonical/example-skill");
    try roots.dir().createDirPath(io, "real/claude");
    try roots.dir().writeFile(io, .{
        .sub_path = "real/canonical/example-skill/SKILL.md",
        .data = "---\nname: example-skill\ndescription: Example.\n---\n",
    });
    try roots.dir().symLink(io, "real", "link", .{});

    // Roots are spelled through the symlinked `link` ancestor (UN-resolved).
    const canonical = try std.fs.path.join(gpa, &.{ roots.base, "link", "canonical" });
    defer gpa.free(canonical);
    const imports = try std.fs.path.join(gpa, &.{ roots.base, "link", "imports" });
    defer gpa.free(imports);
    const claude = try std.fs.path.join(gpa, &.{ roots.base, "link", "claude" });
    defer gpa.free(claude);
    const codex = try std.fs.path.join(gpa, &.{ roots.base, "link", "codex" });
    defer gpa.free(codex);

    // The managed symlink's stored target also uses the un-resolved `link`
    // spelling -- exactly what enable would write given an un-resolved root.
    const target = try std.fs.path.join(gpa, &.{ canonical, "example-skill" });
    defer gpa.free(target);
    try roots.dir().symLink(io, target, "real/claude/example-skill", .{});

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var res = discovery.discover(arena, io, .{
        .canonical = canonical,
        .imports = imports,
        .claude_code = claude,
        .codex = codex,
    });
    const inv = switch (res) {
        .ok => |inv| inv,
        .err => |*e| {
            e.deinit(arena);
            return error.DiscoveryFailed;
        },
    };

    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    const s = inv.skills[0];
    try testing.expectEqual(types.AgentEntryStatus.canonical_symlink, s.agent_entries.claude_code);
    try testing.expect(s.enablement.claude_code);
}

// --- broken_symlink: a symlink whose target does not exist (spec "Inventory":
// broken_symlink; enablement FALSE). It surfaces as an agent_only skill. ---

test "broken_symlink reports broken_symlink and enablement false" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.symlink("does/not/exist", "claude/ghost");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    const s = inv.skills[0];
    try testing.expectEqual(types.SkillSource.agent_only, s.source);
    try testing.expectEqual(types.AgentEntryStatus.broken_symlink, s.agent_entries.claude_code);
    try testing.expect(!s.enablement.claude_code);
}

// --- agent_only skill: a real directory in an agent root only (spec "Terms":
// Agent-only skill; spec "Inventory": skill_directory => source agent_only,
// enablement true). ---

test "agent_only real directory reports skill_directory and source agent_only" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.realDir(.codex, "local-only");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    const s = inv.skills[0];
    try testing.expectEqual(types.SkillSource.agent_only, s.source);
    try testing.expectEqual(types.AgentEntryStatus.skill_directory, s.agent_entries.codex);
    try testing.expect(s.enablement.codex);
    // agent_only skills carry no description (no SKILL.md was parsed).
    try testing.expect(s.description == null);
}

// --- all SIX AgentEntryStatus enablement booleans in one inventory (spec
// "Inventory": "Enablement booleans are true for skill_directory,
// canonical_symlink, imported_symlink, external_symlink; false for missing and
// broken_symlink"). ---

test "every AgentEntryStatus maps to the spec enablement boolean" {
    const T = types.AgentEntryStatus;
    try testing.expect(T.skill_directory.enabled());
    try testing.expect(T.canonical_symlink.enabled());
    try testing.expect(T.imported_symlink.enabled());
    try testing.expect(T.external_symlink.enabled());
    try testing.expect(!T.missing.enabled());
    try testing.expect(!T.broken_symlink.enabled());
}

// --- deterministic name ordering including a shared prefix (spec "list":
// "Skill entries are returned in deterministic order by skill name"). ---

test "skills are name-sorted including shared-prefix names" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    // Insert out of order and with a shared prefix (alpha < alpha-two < beta).
    try fx.writeSkill("canonical/beta", "beta", "B.");
    try fx.writeSkill("canonical/alpha-two", "alpha-two", "A2.");
    try fx.writeSkill("imports/alpha", "alpha", "A.");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 3), inv.skills.len);
    try testing.expectEqualStrings("alpha", inv.skills[0].name);
    try testing.expectEqualStrings("alpha-two", inv.skills[1].name);
    try testing.expectEqualStrings("beta", inv.skills[2].name);
}

// --- every JSON-producing command emits VALID UTF-8 with a trailing newline
// (spec "Output Contract"; acceptance bullet 12). ---

test "inventory JSON is valid UTF-8 and ends in exactly one newline" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/uni", "uni", "Description with unicode: \u{00e9}\u{2603}.");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    const json = try renderJson(inv, arena);

    try testing.expect(std.unicode.utf8ValidateSlice(json));
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(json[json.len - 2] != '\n');
}

// --- duplicate skill across canonical + imports: precedence canonical <
// imported (source becomes imported); promoted OR-accumulated; source_repository
// taken from the imported entry (spec "list" merge behavior, Phase 3 scope). ---

test "skill in both canonical and imports merges to imported with import metadata" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    // Same frontmatter name in both roots; different descriptions to prove the
    // canonical scan ran first but did not clobber import provenance.
    try fx.writeSkill("canonical/dup", "dup", "Canonical copy.");
    try fx.writeSkill("imports/dup", "dup", "Imported draft.");
    try fx.writeManifest("imports/dup", .{
        .source_type = .repository,
        .source_repository = .{ .repository = "https://example.test/r.git", .skill_path = "dup" },
        .imported_at = 1710000000,
        .content_hash = "sha256:abc",
        .promoted = true,
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    const s = inv.skills[0];
    try testing.expectEqual(types.SkillSource.imported, s.source);
    try testing.expect(s.promoted);
    try testing.expect(s.source_repository != null);
    try testing.expectEqualStrings("https://example.test/r.git", s.source_repository.?.repository);
    // Description precedence: the merge keeps the FIRST non-null description and
    // the canonical scan runs first (discovery.zig: canonical sets description,
    // imports only fills when still null). Pin "Canonical copy." so a regression
    // that lets imports overwrite the description is caught -- the "different
    // descriptions" fixture above is otherwise decorative
    // (spec "list": discovery merge behavior / "Inventory": skills[].description).
    try testing.expect(s.description != null);
    try testing.expectEqualStrings("Canonical copy.", s.description.?);
}

// --- source_repositories grouping across multiple repositories and skills,
// sorted by repository, and within a repo by (skill_name, skill_path)
// (spec "Inventory": source_repositories grouping; Phase 3 sort contract). ---

test "source_repositories groups by repo and sorts by (skill_name, skill_path)" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    // repo-b with two skills (zeta before alpha by name => alpha sorts first).
    try fx.writeSkill("imports/zeta", "zeta", "Z.");
    try fx.writeManifest("imports/zeta", .{
        .source_type = .repository,
        .source_repository = .{ .repository = "https://b.test/r.git", .skill_path = "z" },
        .imported_at = 1,
        .content_hash = "sha256:1",
        .promoted = false,
    });
    try fx.writeSkill("imports/alpha", "alpha", "A.");
    try fx.writeManifest("imports/alpha", .{
        .source_type = .repository,
        .source_repository = .{ .repository = "https://b.test/r.git", .skill_path = "a" },
        .imported_at = 1,
        .content_hash = "sha256:2",
        .promoted = false,
    });
    // repo-a with one skill (repository sorts before b.test).
    try fx.writeSkill("imports/mid", "mid", "M.");
    try fx.writeManifest("imports/mid", .{
        .source_type = .repository,
        .source_repository = .{ .repository = "https://a.test/r.git", .skill_path = "m" },
        .imported_at = 1,
        .content_hash = "sha256:3",
        .promoted = false,
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 2), inv.source_repositories.len);

    // Groups sorted by repository: a.test before b.test.
    try testing.expectEqualStrings("https://a.test/r.git", inv.source_repositories[0].repository);
    try testing.expectEqualStrings("https://b.test/r.git", inv.source_repositories[1].repository);

    const b_group = inv.source_repositories[1];
    try testing.expectEqual(@as(usize, 2), b_group.skills.len);
    // Within a repo, sorted by skill_name: alpha before zeta.
    try testing.expectEqualStrings("alpha", b_group.skills[0].skill_name);
    try testing.expectEqualStrings("a", b_group.skills[0].skill_path);
    try testing.expectEqualStrings("zeta", b_group.skills[1].skill_name);
    try testing.expectEqualStrings("z", b_group.skills[1].skill_path);
}
