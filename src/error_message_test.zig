//! Tests for `main.errorMessage` (cli-clean-room-spec.md "Output Contract":
//! "Error text should include the failing operation and the specific path, URL,
//! repository, or skill name where applicable"). Only the `kind` was asserted in
//! other suites; these lock that the actionable PAYLOAD (repository / path /
//! skill name) actually reaches the stderr string. A regression that dropped the
//! payload — reporting only the generic kind message — fails here.
//!
//! Safety: pure string rendering, no filesystem access.

const std = @import("std");
const testing = std.testing;

const main = @import("main.zig");
const result = @import("result.zig");

fn render(arena: std.mem.Allocator, e: result.ErrorInfo) ![]const u8 {
    return main.errorMessage(arena, e);
}

// A repository error must name the specific repository (spec "Output Contract").
test "errorMessage: repository_error names the repository" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const msg = try render(arena, .{
        .kind = .repository_error,
        .repository = "https://example.test/skills.git",
    });
    try testing.expect(std.mem.indexOf(u8, msg, "https://example.test/skills.git") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "repository:") != null);
}

// An invalid repository-root SKILL.md surfaces both the repository AND the
// offending path plus the reason (repository.zig scan error payload).
test "errorMessage: repository_error with path and reason names all three" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const msg = try render(arena, .{
        .kind = .repository_error,
        .repository = "https://example.test/skills.git",
        .path = "SKILL.md",
        .reason = "repository root SKILL.md is invalid",
    });
    try testing.expect(std.mem.indexOf(u8, msg, "https://example.test/skills.git") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "SKILL.md") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "repository root SKILL.md is invalid") != null);
}

// An imports-root collision during a repository import must name the colliding
// skill (repository.zig importsCollision payload: `.name`).
test "errorMessage: import_collision names the skill" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const msg = try render(arena, .{
        .kind = .import_collision,
        .name = "repo-alpha",
    });
    try testing.expect(std.mem.indexOf(u8, msg, "repo-alpha") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "skill:") != null);
}

// git_unavailable still names the repository so the operator knows what failed
// (repository.zig maps GitUnavailable with `.repository`).
test "errorMessage: git_unavailable names the repository" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const msg = try render(arena, .{
        .kind = .git_unavailable,
        .repository = "https://example.test/skills.git",
        .reason = "git not installed",
    });
    try testing.expect(std.mem.indexOf(u8, msg, "https://example.test/skills.git") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "git not installed") != null);
}
