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

// --- H1(b): an agent_only skill (a real directory in an agent root with no
// SKILL.md metadata) has NO description, so the inventory must OMIT the
// `description` key entirely (not emit it as null). This also locks that
// `source_repository` is omitted for a non-repository skill. Exact-string
// golden => any omit-vs-null drift breaks this. ---
test "agent_only skill omits description and source_repository keys (not null)" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    // A bare directory in the codex agent root, with no canonical/imported
    // backing and no parsable SKILL.md metadata => agent_only, no description.
    try fx.realDir(.codex, "ghost-skill");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    const json = try renderJson(inv, arena);

    try testing.expectEqualStrings(
        \\{
        \\  "skills": [
        \\    {
        \\      "name": "ghost-skill",
        \\      "source": "agent_only",
        \\      "promoted": false,
        \\      "enablement": {
        \\        "claude_code": false,
        \\        "codex": true
        \\      },
        \\      "agent_entries": {
        \\        "claude_code": "missing",
        \\        "codex": "skill_directory"
        \\      }
        \\    }
        \\  ],
        \\  "source_repositories": []
        \\}
        \\
    , json);
    // Belt-and-suspenders: no null tokens anywhere (description/source_repository
    // must be OMITTED, not emitted as null).
    try testing.expect(std.mem.indexOf(u8, json, "null") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"description\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"source_repository\"") == null);
}

// --- H1(b): a skill enabled in BOTH agents renders enablement {true,true} with
// both agent_entries non-missing. Locks that the two enablement booleans and the
// two agent_entries are independent and both populated. Single trailing newline
// (spec "Output Contract"). ---
test "skill enabled in both agents renders enablement true,true with both entries present" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/dual-skill", "dual-skill", "Enabled in both agents.");
    try fx.managedSymlink(.claude, "dual-skill", .canonical, "dual-skill");
    try fx.managedSymlink(.codex, "dual-skill", .canonical, "dual-skill");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    const json = try renderJson(inv, arena);

    try testing.expectEqualStrings(
        \\{
        \\  "skills": [
        \\    {
        \\      "name": "dual-skill",
        \\      "description": "Enabled in both agents.",
        \\      "source": "canonical",
        \\      "promoted": false,
        \\      "enablement": {
        \\        "claude_code": true,
        \\        "codex": true
        \\      },
        \\      "agent_entries": {
        \\        "claude_code": "canonical_symlink",
        \\        "codex": "canonical_symlink"
        \\      }
        \\    }
        \\  ],
        \\  "source_repositories": []
        \\}
        \\
    , json);
    // Exactly one trailing newline.
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(json[json.len - 2] != '\n');
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

// --- broken_symlink (Finding #9): a symlink whose target CANNOT BE RESOLVED for
// a reason OTHER than FileNotFound (here a self-referential loop => SymLinkLoop)
// is still broken, not external. Per spec "Inventory": broken_symlink has
// enablement FALSE; spec "Terms": an External entry is a symlink to a target
// OUTSIDE managed roots, i.e. one that resolves but lands elsewhere. A symlink
// whose target does not resolve at all is broken, never external. ---

test "broken_symlink: a symlink-loop target (stat error, not FileNotFound) is broken not external" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    // A self-referential symlink: claude/loopy -> claude/loopy. A no-follow stat
    // reports `.sym_link`; following it yields error.SymLinkLoop (NOT
    // FileNotFound). The target is unresolvable => broken_symlink.
    try fx.symlink("loopy", "claude/loopy");

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

// ===========================================================================
// H3 — manifest/discovery malformed + edge cases.
// ===========================================================================

// --- H3(1): an import.json that is syntactically-VALID JSON but SEMANTICALLY
// malformed because a REQUIRED field is missing (spec "Import Manifest" required
// fields: source_type, imported_at, content_hash, promoted) must FAIL discovery
// for an otherwise-valid imported skill (spec "list": "malformed import.json ...
// is an error"). manifest_test covers this at the parse layer; this locks it
// end-to-end through discover() and that the error names the skill + import.json
// path. A regression that lets a missing required field slip through (e.g. by
// adding a default to ImportManifest) would turn this into a silent success. ---
test "H3: semantically-malformed import.json (missing required field) fails discovery" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("imports/missing-field", "missing-field", "Valid skill, bad manifest.");
    // Syntactically valid JSON, but `content_hash` and `promoted` are absent.
    try fx.writeRawManifest("imports/missing-field",
        \\{
        \\  "source_type": "markdown",
        \\  "source_location": "clipboard",
        \\  "imported_at": 1710000000
        \\}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var res = discovery.discover(arena, io, rootsOf(&roots));
    switch (res) {
        .ok => return error.UnexpectedSuccess,
        .err => |*e| {
            defer e.deinit(arena);
            try testing.expectEqual(@import("result.zig").ErrorKind.malformed_manifest, e.kind);
            // The error must name the offending skill and its import.json path
            // (spec "Output Contract": include the specific path/skill name).
            try testing.expect(e.name != null);
            try testing.expectEqualStrings("missing-field", e.name.?);
            try testing.expect(e.path != null);
            try testing.expect(std.mem.endsWith(u8, e.path.?, "import.json"));
        },
    }
}

// --- H3(1): an import.json whose `source_type` carries an UNKNOWN/invalid enum
// value (spec "Import Manifest": source_type is the closed set {markdown,
// local_path, url, repository}) is semantically malformed and must FAIL
// discovery, even though the JSON is otherwise well-formed and ignore_unknown_
// fields is on. ignore_unknown_fields governs unknown KEYS, never an invalid
// enum VALUE for a known key; a regression that mapped bad enums leniently would
// turn this into a silent success. ---
test "H3: import.json with invalid source_type enum value fails discovery" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("imports/bad-enum", "bad-enum", "Valid skill, bad enum.");
    try fx.writeRawManifest("imports/bad-enum",
        \\{
        \\  "source_type": "ftp",
        \\  "source_location": "ftp://example.test/x.md",
        \\  "imported_at": 1710000000,
        \\  "content_hash": "sha256:x",
        \\  "promoted": false
        \\}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectDiscoverError(&roots, arena, .malformed_manifest);
}

// --- H3(2): a directory under canonical/ with a PRESENT-but-INVALID SKILL.md
// (here: missing the closing `---` delimiter, spec "Skill Metadata" validation
// failure) is NOT a recognized skill and is EXCLUDED from discovery WITHOUT
// erroring (spec "list": skills are identified by VALID SKILL.md metadata;
// readSkill returns null for invalid frontmatter). A regression that errored on
// an invalid SKILL.md, or that admitted the directory as a skill, breaks this. ---
test "H3: invalid SKILL.md under canonical is excluded without erroring" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    // A real canonical skill (so the inventory is non-empty and we prove the
    // BAD one was dropped, not that discovery short-circuited).
    try fx.writeSkill("canonical/good", "good", "A valid canonical skill.");
    // A directory with a SKILL.md that has an opening but no closing delimiter.
    try fx.writeSupportFile("canonical/broken", "SKILL.md", "---\nname: broken\ndescription: no close\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    try testing.expectEqualStrings("good", inv.skills[0].name);
    try testing.expectEqual(types.SkillSource.canonical, inv.skills[0].source);
}

// --- H3(2): a directory under imports/ with a PRESENT-but-INVALID SKILL.md
// (here: missing the `description` field, spec "Skill Metadata": description must
// be present) is EXCLUDED from discovery WITHOUT erroring, and crucially WITHOUT
// reaching the import.json malformed-manifest check (a non-skill directory is
// skipped before its manifest is even read). ---
test "H3: invalid SKILL.md under imports is excluded without erroring" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("imports/real", "real", "A valid imported skill.");
    // Invalid SKILL.md (no description) AND a malformed import.json: since the
    // directory is not a recognized skill, discovery must skip it ENTIRELY and
    // never reach the manifest, so this must NOT raise malformed_manifest.
    try fx.writeSupportFile("imports/invalid", "SKILL.md", "---\nname: invalid\n---\n");
    try fx.writeRawManifest("imports/invalid", "{ not even json ");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    try testing.expectEqualStrings("real", inv.skills[0].name);
    try testing.expectEqual(types.SkillSource.imported, inv.skills[0].source);
}

// --- H3(3): a stray regular file in an agent root is NOT a managed skill and
// produces NO inventory entry (discovery.classifyAgentEntry returns null for a
// non-directory/non-symlink entry). Only the real skill remains. ---
test "H3: stray regular file in an agent root produces no inventory entry" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/keeper", "keeper", "Kept.");
    try fx.managedSymlink(.claude, "keeper", .canonical, "keeper");
    // A stray regular file directly in an agent root (e.g. a README or .DS_Store).
    try fx.strayFile(.claude, "README.md", "not a skill");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    try testing.expectEqualStrings("keeper", inv.skills[0].name);
    // The stray file did not become a phantom skill.
    for (inv.skills) |s| try testing.expect(!std.mem.eql(u8, s.name, "README.md"));
}

// --- H3(3): an imports/ directory that contains import.json but NO SKILL.md is
// not a recognized skill (spec "Terms": a skill is a directory containing
// SKILL.md) and is SKIPPED with no inventory entry. The orphan import.json must
// NOT trigger a malformed_manifest error either: readSkill returns null first,
// so the manifest is never consulted. ---
test "H3: imports dir with import.json but no SKILL.md is skipped" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("imports/real", "real", "Has SKILL.md.");
    // An orphan directory: import.json present, SKILL.md absent.
    try fx.writeManifest("imports/orphan", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:orphan",
        .promoted = false,
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    try testing.expectEqualStrings("real", inv.skills[0].name);
}

// --- H3(4): a CANONICAL skill that ALSO has an agent-root entry keeps
// source == canonical (the agent scan must NOT downgrade an established
// canonical/imported source to agent_only). The agent entry is still classified
// and enablement reflects it. Regression: scanAgent's getOrPut must reuse the
// existing Merged (source already canonical) and only set the agent status. ---
test "H3: canonical skill with an agent entry keeps source canonical" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/example-skill", "example-skill", "Canonical with agent entry.");
    // A real directory (not a managed symlink) in the agent root, same name.
    try fx.realDir(.codex, "example-skill");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    const s = inv.skills[0];
    // Source stays canonical even though an agent-root entry exists.
    try testing.expectEqual(types.SkillSource.canonical, s.source);
    try testing.expectEqual(types.AgentEntryStatus.skill_directory, s.agent_entries.codex);
    try testing.expect(s.enablement.codex);
    // The canonical description survives.
    try testing.expectEqualStrings("Canonical with agent entry.", s.description.?);
}

// --- H3(5): one skill with DIFFERENT statuses in the two agents in a single
// inventory: claude_code is a managed canonical_symlink (enabled), codex is a
// broken_symlink (disabled). Locks that the two agent_entries and the two
// enablement booleans are independently populated for the SAME skill from the
// SAME inventory pass (spec "Inventory": agent_entries/enablement keys). ---
test "H3: same skill carries distinct claude_code and codex statuses" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);
    try fx.writeSkill("canonical/split-skill", "split-skill", "Different per agent.");
    // claude: correct managed canonical symlink -> canonical_symlink, enabled.
    try fx.managedSymlink(.claude, "split-skill", .canonical, "split-skill");
    // codex: a broken symlink (target does not exist) -> broken_symlink, disabled.
    try fx.symlink("nowhere/split-skill", "codex/split-skill");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inv = try discover(&roots, arena);
    try testing.expectEqual(@as(usize, 1), inv.skills.len);
    const s = inv.skills[0];
    try testing.expectEqual(types.SkillSource.canonical, s.source);
    try testing.expectEqual(types.AgentEntryStatus.canonical_symlink, s.agent_entries.claude_code);
    try testing.expectEqual(types.AgentEntryStatus.broken_symlink, s.agent_entries.codex);
    try testing.expect(s.enablement.claude_code);
    try testing.expect(!s.enablement.codex);
}
