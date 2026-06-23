//! Tests for import.json read/write (cli-clean-room-spec.md "Import Manifest").

const std = @import("std");
const testing = std.testing;
const manifest = @import("manifest.zig");
const types = @import("types.zig");

// spec "Import Manifest": on-disk import.json uses 2-space indentation and has
// NO trailing newline (zig-clean-room-cli.md "Decisions locked in": "on-disk
// `import.json` has no trailing newline").
test "write: 2-space indent, no trailing newline" {
    const m: types.ImportManifest = .{
        .source_type = .markdown,
        .source_location = "clipboard",
        .imported_at = 1710000000,
        .content_hash = "sha256:abc",
        .promoted = false,
    };
    const bytes = try manifest.toBytes(testing.allocator, m);
    defer testing.allocator.free(bytes);

    try testing.expect(bytes.len > 0);
    try testing.expect(bytes[bytes.len - 1] != '\n');
    // 2-space indent: a nested field line begins with exactly two spaces.
    try testing.expect(std.mem.indexOf(u8, bytes, "\n  \"source_type\"") != null);
}

// spec "Import Manifest": source_repository is "Optional. Present for repository
// imports and omitted for other source types." With emit_null_optional_fields,
// our writer must NOT emit a null source_repository key.
test "write: omits source_repository when absent" {
    const m: types.ImportManifest = .{
        .source_type = .url,
        .source_location = "https://example.test/x.md",
        .imported_at = 1710000000,
        .content_hash = "sha256:def",
        .promoted = false,
    };
    const bytes = try manifest.toBytes(testing.allocator, m);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "source_repository") == null);
}

test "write: emits source_repository for repository imports" {
    const m: types.ImportManifest = .{
        .source_type = .repository,
        .source_location = "https://example.test/skills.git#alpha",
        .source_repository = .{
            .repository = "https://example.test/skills.git",
            .skill_path = "alpha",
        },
        .imported_at = 1710000000,
        .content_hash = "sha256:ghi",
        .promoted = false,
    };
    const bytes = try manifest.toBytes(testing.allocator, m);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"source_repository\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "https://example.test/skills.git") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"skill_path\": \"alpha\"") != null);
}

// spec "Import Manifest": read with ignore_unknown_fields; round-trip preserves
// fields, including an omitted optional source_repository.
test "round-trip: optional source_repository omitted" {
    const original: types.ImportManifest = .{
        .source_type = .local_path,
        .source_location = "/some/path/SKILL.md",
        .imported_at = 1710000123,
        .content_hash = "sha256:roundtrip",
        .promoted = true,
    };
    const bytes = try manifest.toBytes(testing.allocator, original);
    defer testing.allocator.free(bytes);

    var parsed = try manifest.parse(testing.allocator, bytes);
    defer parsed.deinit();
    const m = parsed.value;

    try testing.expectEqual(types.ImportSourceType.local_path, m.source_type);
    try testing.expectEqualStrings("/some/path/SKILL.md", m.source_location.?);
    try testing.expect(m.source_repository == null);
    try testing.expectEqual(@as(i64, 1710000123), m.imported_at);
    try testing.expectEqualStrings("sha256:roundtrip", m.content_hash);
    try testing.expectEqual(true, m.promoted);
}

test "round-trip: repository manifest preserves source_repository" {
    const original: types.ImportManifest = .{
        .source_type = .repository,
        .source_location = "https://example.test/skills.git#helpers/alpha",
        .source_repository = .{
            .repository = "https://example.test/skills.git",
            .skill_path = "helpers/alpha",
        },
        .imported_at = 1710000999,
        .content_hash = "sha256:repo",
        .promoted = false,
    };
    const bytes = try manifest.toBytes(testing.allocator, original);
    defer testing.allocator.free(bytes);

    var parsed = try manifest.parse(testing.allocator, bytes);
    defer parsed.deinit();
    const sr = parsed.value.source_repository.?;
    try testing.expectEqualStrings("https://example.test/skills.git", sr.repository);
    try testing.expectEqualStrings("helpers/alpha", sr.skill_path);
}

// spec "list": "malformed `import.json` for an otherwise valid imported skill is
// an error." parse surfaces a Zig error for non-JSON / structurally invalid input.
test "parse: malformed json returns an error" {
    const bad = "{ this is not json";
    try testing.expectError(error.SyntaxError, manifest.parse(testing.allocator, bad));
}

// spec "list": "malformed `import.json` for an otherwise valid imported skill is
// an error." A manifest that is syntactically-valid JSON but missing a REQUIRED
// field (spec "Import Manifest" required fields: source_type, imported_at,
// content_hash, promoted) is the realistic on-disk failure mode and must error.
test "parse: missing required content_hash returns error.MissingField" {
    const bad =
        \\{
        \\  "source_type": "markdown",
        \\  "source_location": "clipboard",
        \\  "imported_at": 1710000000,
        \\  "promoted": false
        \\}
    ;
    try testing.expectError(error.MissingField, manifest.parse(testing.allocator, bad));
}

// spec "Import Manifest": `promoted` is a required field; a manifest omitting it
// is structurally malformed and parse must error (spec "list": malformed
// import.json is an error).
test "parse: missing required promoted returns error.MissingField" {
    const bad =
        \\{
        \\  "source_type": "markdown",
        \\  "source_location": "clipboard",
        \\  "imported_at": 1710000000,
        \\  "content_hash": "sha256:x"
        \\}
    ;
    try testing.expectError(error.MissingField, manifest.parse(testing.allocator, bad));
}

// spec "Import Manifest": `source_type` is a closed enum {markdown, local_path,
// url, repository}. An unknown value must NOT map leniently; parse must error
// (spec "list": malformed import.json is an error).
test "parse: unknown source_type returns error.InvalidEnumTag" {
    const bad =
        \\{
        \\  "source_type": "ftp",
        \\  "source_location": "ftp://example.test/x.md",
        \\  "imported_at": 1710000000,
        \\  "content_hash": "sha256:x",
        \\  "promoted": false
        \\}
    ;
    try testing.expectError(error.InvalidEnumTag, manifest.parse(testing.allocator, bad));
}

// spec "Import Manifest": read with ignore_unknown_fields — extra keys do not
// fail the parse.
test "parse: ignores unknown fields" {
    const json =
        \\{
        \\  "source_type": "markdown",
        \\  "source_location": "clipboard",
        \\  "imported_at": 1710000000,
        \\  "content_hash": "sha256:x",
        \\  "promoted": false,
        \\  "future_field": "ignored",
        \\  "another": 42
        \\}
    ;
    var parsed = try manifest.parse(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqual(types.ImportSourceType.markdown, parsed.value.source_type);
}
