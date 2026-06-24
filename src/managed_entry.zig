//! One classification of a filesystem path against the managed roots. Concentrates
//! the no-follow classify, the broken-link probe, lexical symlink-target
//! resolution, and the existing-ancestor canonicalization policy that discovery
//! and ops both need (cli-clean-room-spec.md "Inventory" / "Filesystem Safety").
//!
//! This is the single deep module behind the "is this entry a managed symlink
//! pointing inside the canonical/imports roots, accounting for symlinked
//! ancestors, and is it broken?" policy that was previously implemented twice
//! (discovery.classifyAgentEntry + ops.symlinkPointsAt/symlinkResolves/...).
//! `discovery` and `ops` are thin adapters mapping `Classification` onto their
//! own vocabulary. Leaf module: depends only on `std` + `fsutil`.

const std = @import("std");
const fsutil = @import("fsutil.zig");

/// The classification of a single filesystem path, no-follow on the final
/// component. `discovery` maps this onto AgentEntryStatus; `ops` maps it onto a
/// safe/unsafe preflight verdict.
pub const Classification = union(enum) {
    missing,
    real_directory,
    real_file,
    /// A symlink whose target cannot be resolved end-to-end (dangling / loop /
    /// access-denied through the chain). Distinct from a resolvable `symlink`
    /// that lands outside the roots (Finding #9): a broken link is disabled,
    /// never External.
    broken_symlink,
    /// A resolvable symlink. The payload is its target, canonicalized through
    /// existing ancestors (so a managed link reached via /tmp->/private/tmp or a
    /// symlinked $HOME is not misclassified).
    symlink: []const u8,
};

/// Classify `link_path` (absolute) WITHOUT following a final symlink, resolving
/// and canonicalizing the target when it is a symlink. All allocations are
/// arena-owned.
pub fn classify(arena: std.mem.Allocator, io: std.Io, link_path: []const u8) !Classification {
    const cwd = std.Io.Dir.cwd();
    // No-follow kind of the final component (fsutil.classify maps any unexpected
    // kind, e.g. a FIFO, to `.file`).
    switch (try fsutil.classify(io, cwd, link_path)) {
        .missing => return .missing,
        .directory => return .real_directory,
        .file => return .real_file,
        .symlink => {},
    }

    // A symlink: broken unless its target RESOLVES end-to-end (follow the link).
    // Only a successful follow-stat means the target is reachable; ANY error
    // means it cannot be resolved — FileNotFound (dangling), SymLinkLoop,
    // AccessDenied through the chain, etc. An unresolvable link is broken, NOT a
    // resolvable symlink that lands outside the roots (Finding #9): the former is
    // disabled / unsafe-to-remove, the latter is External.
    const resolves = blk: {
        _ = cwd.statFile(io, link_path, .{ .follow_symlinks = true }) catch break :blk false;
        break :blk true;
    };
    if (!resolves) return .broken_symlink;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try cwd.readLink(io, link_path, &buf);
    // Resolve the target with the SAME policy as the roots it will be compared
    // against (canonicalizeExistingAncestor realpaths existing ancestors, so any
    // intermediate symlink component is resolved). Canonicalizing only one side
    // would prefix-compare a realpath against an un-resolved spelling and
    // misclassify a managed symlink reached through a symlinked ancestor (e.g.
    // macOS /tmp->/private/tmp, a symlinked $HOME).
    const link_dir = try canonicalize(arena, io, std.fs.path.dirname(link_path) orelse ".");
    const lexical_target = try fsutil.resolveLinkTarget(arena, link_dir, buf[0..n]);
    const target = try canonicalize(arena, io, lexical_target);
    return .{ .symlink = target };
}

/// Canonicalize `path` through existing ancestors, falling back to a lexical
/// resolve for a not-yet-existing path. (The `canonOrLexical` /
/// `canonRootOrLexical` policy.)
pub fn canonicalize(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return fsutil.canonicalizeExistingAncestor(arena, io, path) catch
        std.fs.path.resolve(arena, &.{path});
}

/// True iff `path` is `root` itself or lies strictly inside it (component-aware:
/// a sibling like `<root>-evil` is NOT inside `<root>`).
pub fn isInside(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == std.fs.path.sep;
}
