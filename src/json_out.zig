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
