//! Spec JSON emitters (cli-clean-room-spec.md "JSON Schemas"). Phase 1 provides
//! the emitter skeleton plus a low-level helper that writes an enum as its
//! snake_case wire token. Full inventory / import / operation emitters land in
//! Phase 3+.
//!
//! Wire spelling rule: every domain enum's `@tagName` IS the spec vocabulary, so
//! enum values serialize directly. The exhaustive test below locks every spelling
//! against the spec text.

const std = @import("std");
const types = @import("types.zig");

/// JSON whitespace used for all stdout payloads (spec "Output Contract":
/// pretty-printed or otherwise deterministic).
pub const json_options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

/// Emit the full `list --format json` inventory (spec "JSON Schemas > Inventory").
/// Key order is the declaration order of the `types` structs, which mirrors the
/// spec field-for-field: name, description?, source, source_repository?, promoted,
/// enablement{claude_code,codex}, agent_entries{claude_code,codex}; and the repo
/// groups. Optional null fields (`description`, `source_repository`) are OMITTED,
/// not null (spec "Inventory": those keys appear only when present). The payload
/// ends in exactly one trailing newline (spec "Output Contract").
pub fn writeInventory(w: *std.Io.Writer, inv: types.Inventory) std.Io.Writer.Error!void {
    try std.json.Stringify.value(inv, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, w);
    try w.writeByte('\n');
}

/// Emit a markdown/path/url import result (spec "JSON Schemas > Import Result").
/// Key order mirrors the spec: skill_name, skill_path, manifest_path, manifest
/// {source_type, source_location?, source_repository?, imported_at, content_hash,
/// promoted}, actions[{action, path}]. Absent optional manifest fields are
/// omitted (spec "Import Manifest"). Ends in exactly one trailing newline (spec
/// "Output Contract").
pub fn writeImportResult(w: *std.Io.Writer, r: types.ImportResult) std.Io.Writer.Error!void {
    try std.json.Stringify.value(r, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, w);
    try w.writeByte('\n');
}

/// Emit a repository import result (spec "JSON Schemas > Repository Import
/// Result"). The result is a tagged union over `kind`; each variant struct
/// carries the `kind` discriminator as its first field, so emitting the ACTIVE
/// variant directly (not the union, which would wrap it in a `{"imported": ...}`
/// envelope) yields the spec's flat shape:
///   - imported:        {kind, skill_name, skill_path, manifest_path, manifest, actions}
///   - selection:       {kind, repository, skills[{name, description?, relative_path}]}
///   - imported_batch:  {kind, imports[{skill_name, ...}]}
/// Absent optional fields (manifest source_location/source_repository,
/// choice description) are omitted, not null. Ends in exactly one trailing
/// newline (spec "Output Contract").
pub fn writeRepositoryImportResult(w: *std.Io.Writer, r: types.RepositoryImportResult) std.Io.Writer.Error!void {
    const opts: std.json.Stringify.Options = .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    };
    switch (r) {
        .imported => |v| try std.json.Stringify.value(v, opts, w),
        .imported_batch => |v| try std.json.Stringify.value(v, opts, w),
        .selection => |v| try std.json.Stringify.value(v, opts, w),
    }
    try w.writeByte('\n');
}

/// Emit an enable/disable/promote/unpromote/delete result (spec "JSON Schemas >
/// Skill Operation Result"). Key order mirrors the spec: skill_name, then each
/// action {action, agent?, path, target?, source?}. The optional `agent`,
/// `target`, and `source` fields are OMITTED (not null) when absent: `agent`
/// only for agent-root actions, `target` only for symlink/skip actions involving
/// an agent entry, `source` only for copy/promotion actions. Ends in exactly one
/// trailing newline (spec "Output Contract").
pub fn writeSkillOperationResult(w: *std.Io.Writer, r: types.SkillOperationResult) std.Io.Writer.Error!void {
    try std.json.Stringify.value(r, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, w);
    try w.writeByte('\n');
}

/// Write an enum value as its snake_case wire token (a bare JSON string).
/// `std.json.Stringify` serializes a Zig enum as its `@tagName`, which is exactly
/// the spec spelling for every domain enum.
pub fn writeEnumToken(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    var stringify: std.json.Stringify = .{ .writer = w, .options = json_options };
    try stringify.write(value);
}

/// Render an enum value's wire token into freshly allocated bytes (without the
/// surrounding JSON quotes). Caller owns the returned slice.
pub fn enumTokenAlloc(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeEnumToken(&aw.writer, value);
    const written = aw.writer.buffered();
    // Strip the surrounding JSON quotes that Stringify emits for a string token.
    std.debug.assert(written.len >= 2 and written[0] == '"' and written[written.len - 1] == '"');
    return gpa.dupe(u8, written[1 .. written.len - 1]);
}

// ---------------------------------------------------------------------------
// Tests: lock EVERY enum spelling against the spec wire vocabulary.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectToken(value: anytype, expected: []const u8) !void {
    const got = try enumTokenAlloc(testing.allocator, value);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "SkillSource tokens (spec Inventory: source values)" {
    try expectToken(types.SkillSource.canonical, "canonical");
    try expectToken(types.SkillSource.imported, "imported");
    try expectToken(types.SkillSource.agent_only, "agent_only");
}

test "AgentEntryStatus tokens (spec Inventory: agent_entries values)" {
    try expectToken(types.AgentEntryStatus.missing, "missing");
    try expectToken(types.AgentEntryStatus.skill_directory, "skill_directory");
    try expectToken(types.AgentEntryStatus.canonical_symlink, "canonical_symlink");
    try expectToken(types.AgentEntryStatus.imported_symlink, "imported_symlink");
    try expectToken(types.AgentEntryStatus.external_symlink, "external_symlink");
    try expectToken(types.AgentEntryStatus.broken_symlink, "broken_symlink");
}

test "ImportSourceType tokens (spec Import Manifest: source_type)" {
    try expectToken(types.ImportSourceType.markdown, "markdown");
    try expectToken(types.ImportSourceType.local_path, "local_path");
    try expectToken(types.ImportSourceType.url, "url");
    try expectToken(types.ImportSourceType.repository, "repository");
}

test "ImportActionKind tokens (spec Import Result: action values)" {
    try expectToken(types.ImportActionKind.create_directory, "create_directory");
    try expectToken(types.ImportActionKind.write_skill, "write_skill");
    try expectToken(types.ImportActionKind.copy_file, "copy_file");
    try expectToken(types.ImportActionKind.write_manifest, "write_manifest");
}

test "SkillActionKind tokens (spec Skill Operation Result: action values)" {
    try expectToken(types.SkillActionKind.create_directory, "create_directory");
    try expectToken(types.SkillActionKind.create_symlink, "create_symlink");
    try expectToken(types.SkillActionKind.remove_symlink, "remove_symlink");
    try expectToken(types.SkillActionKind.copy_file, "copy_file");
    try expectToken(types.SkillActionKind.write_manifest, "write_manifest");
    try expectToken(types.SkillActionKind.remove_directory, "remove_directory");
    try expectToken(types.SkillActionKind.skip_unchanged, "skip_unchanged");
}

test "Agent JSON tokens (spec Inventory: enablement/agent_entries keys)" {
    try testing.expectEqualStrings("claude_code", types.Agent.claude_code.jsonName());
    try testing.expectEqualStrings("codex", types.Agent.codex.jsonName());
    // Agent serializes to its JSON spelling via Stringify too.
    try expectToken(types.Agent.claude_code, "claude_code");
    try expectToken(types.Agent.codex, "codex");
}

test "Agent CLI tokens are hyphenated (spec enable/disable: --agent values)" {
    try testing.expectEqualStrings("claude-code", types.Agent.claude_code.cliName());
    try testing.expectEqualStrings("codex", types.Agent.codex.cliName());
}

test "RepoImportKind tokens (spec Repository Import Result: kind)" {
    try expectToken(types.RepoImportKind.imported, "imported");
    try expectToken(types.RepoImportKind.imported_batch, "imported_batch");
    try expectToken(types.RepoImportKind.selection, "selection");
}

// ---------------------------------------------------------------------------
// Skill Operation Result wire-level contracts (spec "JSON Schemas > Skill
// Operation Result"; "Output Contract"). Locks key order, omit-vs-null for the
// optional `agent`/`target`/`source` fields, and the single trailing newline.
// ---------------------------------------------------------------------------

fn renderOpResult(r: types.SkillOperationResult) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try writeSkillOperationResult(&aw.writer, r);
    return aw.toOwnedSlice();
}

test "SkillOperationResult: enable create_symlink emits action,agent,path,target in order; no source key" {
    // spec "Skill Operation Result": wire key order action, agent, path, target;
    // `agent` present for agent-root actions, `target` present for symlink
    // actions, `source` OMITTED (not null) when absent.
    const r: types.SkillOperationResult = .{
        .skill_name = "example-skill",
        .actions = &.{.{
            .action = .create_symlink,
            .agent = .codex,
            .path = "/abs/.agents/skills/example-skill",
            .target = "/abs/agent-skills/example-skill",
        }},
    };
    const json = try renderOpResult(r);
    defer testing.allocator.free(json);

    // Key order within the action object: action < agent < path < target.
    const i_action = std.mem.indexOf(u8, json, "\"action\"").?;
    const i_agent = std.mem.indexOf(u8, json, "\"agent\"").?;
    const i_path = std.mem.indexOf(u8, json, "\"path\"").?;
    const i_target = std.mem.indexOf(u8, json, "\"target\"").?;
    try testing.expect(i_action < i_agent);
    try testing.expect(i_agent < i_path);
    try testing.expect(i_path < i_target);
    // `source` is absent => OMITTED, not emitted as null.
    try testing.expect(std.mem.indexOf(u8, json, "\"source\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "null") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"agent\": \"codex\"") != null);
    // Exactly one trailing newline (spec "Output Contract").
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(json[json.len - 2] != '\n');
}

test "SkillOperationResult: collection action omits agent (spec: agent omitted for collection actions)" {
    // spec "Skill Operation Result": "`agent` is ... omitted for collection
    // actions." A remove_directory on the collection (no agent) must NOT emit
    // an `agent` key or `agent: null`.
    const r: types.SkillOperationResult = .{
        .skill_name = "example-skill",
        .actions = &.{.{
            .action = .remove_directory,
            .agent = null,
            .path = "/abs/agent-skills/example-skill",
        }},
    };
    const json = try renderOpResult(r);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"agent\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"target\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "null") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"action\": \"remove_directory\"") != null);
}

test "SkillOperationResult: disable skip_unchanged omits target when missing-entry (spec: target absent)" {
    // spec "Skill Operation Result": "`target` is present for symlink actions and
    // skip actions involving an agent entry." A disable skip for a MISSING entry
    // has no target => the `target` key must be OMITTED, not null.
    const r: types.SkillOperationResult = .{
        .skill_name = "example-skill",
        .actions = &.{.{
            .action = .skip_unchanged,
            .agent = .claude_code,
            .path = "/abs/.claude/skills/example-skill",
            .target = null,
        }},
    };
    const json = try renderOpResult(r);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"target\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "null") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"agent\": \"claude_code\"") != null);
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(json[json.len - 2] != '\n');
}
