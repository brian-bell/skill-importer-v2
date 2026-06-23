//! Error model (zig-clean-room-cli.md "Error model"). Zig error sets carry no
//! payload, but the spec requires stderr to name the failing operation and the
//! specific path/URL/repo/skill (cli-clean-room-spec.md "Output Contract").
//! So operations return a tagged `Result(T)` carrying an `ErrorInfo`.

const std = @import("std");
const types = @import("types.zig");

/// Every distinct failure the spec describes. `main.zig` maps these to a stderr
/// message and exit code 1 (spec "Output Contract": exit codes 0 success, 1
/// everything else).
pub const ErrorKind = enum {
    // --- argument / parse ---
    parse_error,

    // --- frontmatter / metadata validation (spec "Skill Metadata") ---
    missing_open_delimiter,
    missing_close_delimiter,
    missing_name,
    invalid_name,
    missing_description,

    // --- discovery (spec "list") ---
    discovery_error,
    malformed_manifest,

    // --- generic skill resolution (spec enable/disable/promote/etc.) ---
    unknown_skill,
    agent_only_skill,
    not_promoted,
    already_promoted,
    canonical_only_skill,

    // --- collisions (spec "Collision Rules") ---
    import_collision,
    canonical_collision,
    frontmatter_name_collision,

    // --- filesystem safety (spec "Filesystem Safety") ---
    unsafe_agent_entry,
    unsupported_entry,
    imports_root_inside_source,
    reserved_manifest_in_source,

    // --- url import (spec "import url") ---
    fetch_failed,
    size_exceeded,
    invalid_utf8,
    timeout,

    // --- repository import (spec "import repository") ---
    duplicate_selection,
    missing_selection,
    duplicate_skill_name,
    depth_exceeded,
    empty_repository,
    git_unavailable,
    repository_error,

    // --- delete-specific (spec "delete") ---
    enabled_import,

    // --- unexpected I/O surfacing partial actions (spec "Filesystem Safety") ---
    io_error,

    // --- allocator exhaustion. Distinct from io_error: an OOM is not a
    // filesystem failure, so it must not be reported as one (spec "Output
    // Contract": error text names the failing operation). ---
    out_of_memory,
};

/// Rich error payload. All strings are arena-owned by the caller's operation
/// arena. `partial_actions` records actions that completed before an unexpected
/// I/O failure (spec "Filesystem Safety": "should report the actions that
/// completed before the failure"); it is test-observable but is NOT serialized
/// into user-facing JSON.
pub const ErrorInfo = struct {
    kind: ErrorKind,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    field: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    url: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    partial_actions: std.ArrayList(types.SkillAction) = .empty,

    pub fn deinit(self: *ErrorInfo, gpa: std.mem.Allocator) void {
        self.partial_actions.deinit(gpa);
    }
};

/// Tagged result returned by every operation. `Ok` payloads are spec result
/// structs from types.zig.
pub fn Result(comptime Ok: type) type {
    return union(enum) {
        ok: Ok,
        err: ErrorInfo,

        const Self = @This();

        pub fn isOk(self: Self) bool {
            return self == .ok;
        }

        pub fn unwrap(self: Self) Ok {
            return self.ok;
        }
    };
}
