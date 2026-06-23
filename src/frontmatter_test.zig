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

// --- Exact-key matching: prefix / look-alike keys must NOT be read as the real
// `name`/`description` keys. The match must be on the exact key up to the colon
// (spec "Skill Metadata": "only needs to recognize `name:` and `description:`
// lines"). A regression to loose prefix-matching must fail these tests. ---

test "parse: 'username:' is not read as 'name'" {
    // `username:` shares no real `name` field; the only true name is `real-name`.
    const src =
        \\---
        \\username: imposter
        \\name: real-name
        \\description: d
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(r.isOk());
    try testing.expectEqualStrings("real-name", r.ok.name);
}

test "parse: 'name_x:' is not read as 'name'" {
    const src =
        \\---
        \\name_x: imposter
        \\name: real-name
        \\description: d
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(r.isOk());
    try testing.expectEqualStrings("real-name", r.ok.name);
}

test "parse: 'namespace:' is not read as 'name'" {
    const src =
        \\---
        \\namespace: imposter
        \\name: real-name
        \\description: d
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(r.isOk());
    try testing.expectEqualStrings("real-name", r.ok.name);
}

test "parse: only a look-alike 'name' key means name is missing" {
    // With no exact `name:` key, the only keys being look-alikes must leave the
    // name unset, so parsing fails with missing_name rather than borrowing the
    // imposter's value.
    const src =
        \\---
        \\namespace: imposter
        \\name_x: also-imposter
        \\description: d
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(!r.isOk());
    try testing.expectEqual(result.ErrorKind.missing_name, r.err.kind);
}

test "parse: 'description_long:' is not read as 'description'" {
    const src =
        \\---
        \\name: has-name
        \\description_long: imposter
        \\description: real desc
        \\---
    ;
    const r = frontmatter.parse(testing.allocator, src);
    try testing.expect(r.isOk());
    try testing.expectEqualStrings("real desc", r.ok.description);
}

test "parse: only a look-alike 'description' key means description is missing" {
    const src =
        \\---
        \\name: has-name
        \\description_long: imposter
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

test "validateSkillName: rejects an embedded NUL byte" {
    // A NUL byte truncates C path APIs and is never directory-safe (spec
    // "Terms": Skill name must be a directory-safe path segment).
    try testing.expect(!frontmatter.validateSkillName("foo\x00bar"));
    try testing.expect(!frontmatter.validateSkillName("\x00"));
    try testing.expect(!frontmatter.validateSkillName("trailing\x00"));
}

test "validateSkillName: rejects ASCII control characters" {
    // Newlines, tabs, CR, ESC, DEL and other C0 controls are not directory-safe.
    try testing.expect(!frontmatter.validateSkillName("foo\nbar"));
    try testing.expect(!frontmatter.validateSkillName("foo\tbar"));
    try testing.expect(!frontmatter.validateSkillName("foo\rbar"));
    try testing.expect(!frontmatter.validateSkillName("foo\x1bbar")); // ESC
    try testing.expect(!frontmatter.validateSkillName("foo\x7fbar")); // DEL
    try testing.expect(!frontmatter.validateSkillName("foo\x01bar")); // SOH
    try testing.expect(!frontmatter.validateSkillName("\x1fend")); // US
}

test "validateSkillName: still accepts ordinary printable segments" {
    try testing.expect(frontmatter.validateSkillName("a b"));
    try testing.expect(frontmatter.validateSkillName("Skill-123_v2.md"));
}
