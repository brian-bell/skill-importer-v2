//! Tests for SKILL.md frontmatter parsing + skill-name validation.
//! Source of truth: cli-clean-room-spec.md "Skill Metadata" and "Terms".

const std = @import("std");
const testing = std.testing;
const frontmatter = @import("frontmatter.zig");
const result = @import("result.zig");

// --- Happy path (spec "Skill Metadata": recognize name:/description: before
// the closing delimiter; values are trimmed; unknown fields ignored). ---

test "parse: name and description between --- delimiters" {
    const src =
        \\---
        \\name: example-skill
        \\description: Example description.
        \\---
        \\
        \\# Body
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(r.isOk());
    const meta = r.ok;
    try testing.expectEqualStrings("example-skill", meta.name);
    try testing.expectEqualStrings("Example description.", meta.description);
}

test "parse: values are trimmed of surrounding whitespace" {
    const src =
        \\---
        \\name:    spaced-skill
        \\description:   Trimmed desc.
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(r.isOk());
    try testing.expectEqualStrings("spaced-skill", r.ok.name);
    try testing.expectEqualStrings("Trimmed desc.", r.ok.description);
}

test "parse: unknown frontmatter fields are ignored" {
    const src =
        \\---
        \\version: 3
        \\name: keep
        \\license: MIT
        \\description: Has extras.
        \\tags: a, b, c
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(r.isOk());
    try testing.expectEqualStrings("keep", r.ok.name);
    try testing.expectEqualStrings("Has extras.", r.ok.description);
}

// --- Validation failures (spec "Skill Metadata": "Import validation fails ...
// when ..."). ---

test "parse: missing opening --- delimiter fails" {
    // spec: "The opening `---` delimiter is missing."
    const src =
        \\name: no-open
        \\description: d
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.missing_open_delimiter, r.err.kind);
}

test "parse: missing closing --- delimiter fails" {
    // spec: "The closing `---` delimiter is missing."
    const src =
        \\---
        \\name: no-close
        \\description: d
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.missing_close_delimiter, r.err.kind);
}

test "parse: missing name fails" {
    // spec: "`name` is missing or empty."
    const src =
        \\---
        \\description: only-desc
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.missing_name, r.err.kind);
}

test "parse: empty name fails" {
    // spec: "`name` is missing or empty."
    const src =
        \\---
        \\name:
        \\description: d
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.missing_name, r.err.kind);
}

test "parse: name with path separator fails as invalid_name" {
    // spec "Skill name" / "Skill Metadata": "`name` is not a single
    // directory-safe path segment."
    const src =
        \\---
        \\name: dir/sub
        \\description: d
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.invalid_name, r.err.kind);
}

test "parse: name '.' fails as invalid_name" {
    // spec "Skill name": "not `.` or `..`".
    const src =
        \\---
        \\name: .
        \\description: d
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.invalid_name, r.err.kind);
}

test "parse: name '..' fails as invalid_name" {
    // spec "Skill name": "not `.` or `..`".
    const src =
        \\---
        \\name: ..
        \\description: d
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.invalid_name, r.err.kind);
}

test "parse: missing description fails" {
    // spec: "`description` is missing or empty."
    const src =
        \\---
        \\name: has-name
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.missing_description, r.err.kind);
}

test "parse: empty description fails" {
    // spec: "`description` is missing or empty."
    const src =
        \\---
        \\name: has-name
        \\description:
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.missing_description, r.err.kind);
}

// --- validateSkillName as a standalone unit (spec "Terms": Skill name rules).

test "validateSkillName: accepts a plain segment" {
    try testing.expect(frontmatter.validateSkillName("example-skill"));
    try testing.expect(frontmatter.validateSkillName("a_b.c"));
}

test "validateSkillName: rejects empty, dot, dotdot, separators" {
    try testing.expect(!frontmatter.validateSkillName(""));
    try testing.expect(!frontmatter.validateSkillName("."));
    try testing.expect(!frontmatter.validateSkillName(".."));
    try testing.expect(!frontmatter.validateSkillName("a/b"));
    try testing.expect(!frontmatter.validateSkillName("a\\b"));
}
