//! SKILL.md frontmatter parsing + skill-name validation
//! (cli-clean-room-spec.md "Skill Metadata" and "Terms").
//!
//! The importer "only needs to recognize `name:` and `description:` lines before
//! the closing delimiter. Values are trimmed. Unknown frontmatter fields may be
//! ignored." Validation fails (spec "Skill Metadata") when the opening or closing
//! `---` is missing, `name` is missing/empty/not a single directory-safe path
//! segment, or `description` is missing/empty.

const std = @import("std");
const result = @import("result.zig");

/// Parsed frontmatter metadata. The returned slices point into the caller-owned
/// `source` buffer (no allocation), so they live exactly as long as `source`.
pub const Metadata = struct {
    name: []const u8,
    description: []const u8,
};

const whitespace = " \t\r\n";

/// Parse leading YAML-like frontmatter from a SKILL.md `source`.
///
/// `gpa` is currently unused (results borrow `source`); it is part of the
/// signature for uniformity with other Result-returning operations and to allow
/// future owned-string errors without churning callers.
pub fn parse(gpa: std.mem.Allocator, source: []const u8) result.Result(Metadata) {
    _ = gpa;

    var lines = std.mem.splitScalar(u8, source, '\n');

    // Opening delimiter: the first non-empty line must be exactly `---` (after
    // trimming trailing CR / surrounding spaces). Leading blank lines before the
    // delimiter are tolerated.
    const first = firstNonBlankLine(&lines) orelse
        return .{ .err = .{ .kind = .missing_open_delimiter } };
    if (!isDelimiter(first))
        return .{ .err = .{ .kind = .missing_open_delimiter } };

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var saw_close = false;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (isDelimiter(line)) {
            saw_close = true;
            break;
        }
        // Recognize only `name:` and `description:`; ignore everything else
        // (spec: "Unknown frontmatter fields may be ignored.").
        if (fieldValue(line, "name")) |v| {
            name = std.mem.trim(u8, v, whitespace);
        } else if (fieldValue(line, "description")) |v| {
            description = std.mem.trim(u8, v, whitespace);
        }
    }

    if (!saw_close)
        return .{ .err = .{ .kind = .missing_close_delimiter } };

    // Name: missing or empty -> missing_name (spec); present but not a single
    // directory-safe segment -> invalid_name (spec "Skill name").
    const n = name orelse return .{ .err = .{ .kind = .missing_name } };
    if (n.len == 0) return .{ .err = .{ .kind = .missing_name } };
    if (!validateSkillName(n)) return .{ .err = .{ .kind = .invalid_name } };

    const d = description orelse return .{ .err = .{ .kind = .missing_description } };
    if (d.len == 0) return .{ .err = .{ .kind = .missing_description } };

    return .{ .ok = .{ .name = n, .description = d } };
}

/// True iff `name` is a single directory-safe path segment: non-empty, not `.`
/// or `..`, containing no path separators, and free of NUL / ASCII control
/// characters (spec "Terms": Skill name must be a directory-safe path segment).
pub fn validateSkillName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.eql(u8, name, "..")) return false;
    // Reject both POSIX and Windows separators so storage is safe on any host.
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    // Reject NUL (truncates C path APIs) and all ASCII control characters
    // (C0 controls 0x00-0x1F and DEL 0x7F); none are directory-safe.
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// Return the next line that is non-blank after trimming surrounding whitespace,
/// or null at end of input.
fn firstNonBlankLine(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, whitespace);
        if (line.len != 0) return line;
    }
    return null;
}

/// True iff a (CR-trimmed) line is exactly the `---` delimiter once surrounding
/// whitespace is removed.
fn isDelimiter(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, line, whitespace), "---");
}

/// If `line` is `<key>:<value>`, return the raw (untrimmed) value; otherwise null.
fn fieldValue(line: []const u8, key: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, key)) return null;
    const rest = trimmed[key.len..];
    if (rest.len == 0 or rest[0] != ':') return null;
    return rest[1..];
}
