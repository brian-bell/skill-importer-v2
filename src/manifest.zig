//! import.json read/write (cli-clean-room-spec.md "Import Manifest").
//!
//! On disk: 2-space indentation, NO trailing newline (zig-clean-room-cli.md
//! "Decisions locked in"). `source_repository` is optional and omitted for
//! non-repository imports (spec "Import Manifest"), so optional null fields are
//! NOT emitted.

const std = @import("std");
const types = @import("types.zig");

pub const Parsed = std.json.Parsed(types.ImportManifest);

/// Serialize a manifest to its on-disk bytes (2-space indent, no trailing
/// newline). Caller owns the returned slice. Absent optional fields (e.g.
/// `source_repository` for non-repository imports) are omitted, per spec.
pub fn toBytes(gpa: std.mem.Allocator, m: types.ImportManifest) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(m, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, &aw.writer);
    return gpa.dupe(u8, aw.writer.buffered());
}

/// Parse import.json bytes, ignoring unknown fields (spec "Import Manifest").
/// Returns a `std.json.Parsed`; the caller must `deinit()` it to free the arena
/// that backs the manifest's string slices.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Parsed {
    return std.json.parseFromSlice(
        types.ImportManifest,
        gpa,
        bytes,
        .{ .ignore_unknown_fields = true },
    );
}
