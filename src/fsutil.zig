//! Filesystem utilities (zig-clean-room-cli.md "Risks": isolate 0.16 fs churn +
//! symlink no-follow here). No-follow classify, lexical target resolution,
//! symlink-preserving recursive copy, existing-ancestor canonicalize.

const std = @import("std");

/// No-follow classification of a filesystem entry. Symlinks are reported as
/// `.symlink` regardless of whether their target exists or what kind it is
/// (zig-clean-room-cli.md "statFile follows symlinks ... classify by entry
/// kind").
pub const EntryKind = enum { missing, file, directory, symlink };

/// Classify `sub_path` relative to `dir` WITHOUT following a final symlink.
/// A nonexistent entry is `.missing`; any other unexpected kind maps to
/// `.symlink`-style "other" only for true symlinks (named pipes etc. are not
/// expected in skill storage and surface as `.file`-unlike — we report the
/// stat's kind directly).
pub fn classify(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !EntryKind {
    const st = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    return switch (st.kind) {
        .sym_link => .symlink,
        .directory => .directory,
        .file => .file,
        else => .file,
    };
}

/// Lexically resolve a symlink's `target` against the absolute directory that
/// contains the link (`link_dir`), via `std.fs.path.resolve` — never `realpath`,
/// which requires existence and dereferences (zig-clean-room-cli.md: "Resolve
/// symlink targets lexically ... never realpath"). The target need not exist.
/// Caller owns the result.
pub fn resolveLinkTarget(gpa: std.mem.Allocator, link_dir: []const u8, target: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(target)) {
        return std.fs.path.resolve(gpa, &.{target});
    }
    return std.fs.path.resolve(gpa, &.{ link_dir, target });
}

/// Recursively copy the contents of `src` into `dst`. Regular files are copied;
/// subdirectories are created and recursed; SYMLINKS ARE RECREATED via
/// readLink+symLink because `copyFile` dereferences them (zig-clean-room-cli.md
/// fsutil scope). `dst` must already exist.
pub fn copyTree(io: std.Io, src: std.Io.Dir, dst: std.Io.Dir) !void {
    var it = src.iterate();
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                try src.copyFile(entry.name, dst, entry.name, io, .{});
            },
            .directory => {
                try dst.createDirPath(io, entry.name);
                var sub_src = try src.openDir(io, entry.name, .{ .iterate = true });
                defer sub_src.close(io);
                var sub_dst = try dst.openDir(io, entry.name, .{});
                defer sub_dst.close(io);
                try copyTree(io, sub_src, sub_dst);
            },
            .sym_link => {
                const n = try src.readLink(io, entry.name, &link_buf);
                try dst.symLink(io, link_buf[0..n], entry.name, .{});
            },
            else => return error.UnsupportedEntry,
        }
    }
}

/// Canonicalize a possibly-not-yet-existing absolute `path`: realpath the
/// nearest existing ancestor, then re-append the missing components lexically.
/// This yields a stable absolute path for a destination that does not fully
/// exist yet (used for symlink-target equality during enable/disable). Hand-
/// rolled because `realpath` requires the whole path to exist. Caller owns the
/// result.
pub fn canonicalizeExistingAncestor(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    // Walk up until an ancestor exists, collecting the missing trailing
    // components (in reverse).
    var tail: std.ArrayList([]const u8) = .empty;
    defer tail.deinit(gpa);

    var cursor: []const u8 = path;
    const cwd = std.Io.Dir.cwd();
    while (true) {
        // realPathFileAlloc resolves symlinks and requires existence; if the
        // cursor exists it is our canonical anchor.
        if (cwd.realPathFileAlloc(io, cursor, gpa)) |anchor_z| {
            // realPathFileAlloc returns a sentinel-terminated [:0]u8 (allocated
            // as len+1); copy to a plain []u8 so the caller's free size matches.
            defer gpa.free(anchor_z);
            const anchor = try gpa.dupe(u8, anchor_z);
            // Re-join the missing tail (collected innermost-last) onto anchor.
            if (tail.items.len == 0) return anchor;
            defer gpa.free(anchor);
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(gpa);
            try parts.append(gpa, anchor);
            var i: usize = tail.items.len;
            while (i > 0) {
                i -= 1;
                try parts.append(gpa, tail.items[i]);
            }
            return std.fs.path.join(gpa, parts.items);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const parent = std.fs.path.dirname(cursor) orelse {
            // No existing ancestor at all: return the lexically-resolved path.
            return std.fs.path.resolve(gpa, &.{path});
        };
        const base = std.fs.path.basename(cursor);
        try tail.append(gpa, base);
        cursor = parent;
    }
}
