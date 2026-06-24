//! Deterministic, recording recursive directory copy. Entries are copied in
//! sorted order so the recorded action stream is deterministic (Finding #13)
//! regardless of filesystem readdir order. Regular files are copied and emitted;
//! directories are created and recursed; symlinks / unsupported entries are
//! rejected.
//!
//! This is the single home for "recursively copy a directory, deterministically,
//! recording a copy_file action per regular file, skipping some entries" — a rule
//! previously implemented three times (import.zig / repository.zig / ops.zig) with
//! the determinism fix applied unevenly. The three callers now differ only in (a)
//! which entries they exclude (`Exclude`) and (b) which action type they record
//! (`Sink`).
//!
//! Distinct from `fsutil.copyTree`, which RECREATES symlinks and records nothing.

const std = @import("std");

/// Called once per copied regular file with its absolute destination path. The
/// caller wraps its own action type (ImportAction vs SkillAction). May fail; the
/// error aborts the copy and propagates, so already-emitted actions form the
/// partial record (used by promote's partial-action reporting).
pub const Sink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, abs_path: []const u8) anyerror!void,
    pub fn emit(self: Sink, abs_path: []const u8) anyerror!void {
        return self.emitFn(self.ctx, abs_path);
    }
};

/// Decide whether to skip an entry by name. `at_top` is true only for entries
/// directly under the copy root.
pub const Exclude = struct {
    ctx: *anyopaque = undefined,
    skipFn: *const fn (ctx: *anyopaque, name: []const u8, at_top: bool) bool,
    pub fn skip(self: Exclude, name: []const u8, at_top: bool) bool {
        return self.skipFn(self.ctx, name, at_top);
    }
};

/// Exclude nothing (import path / markdown directory copy).
pub const exclude_none: Exclude = .{ .skipFn = skipNothing };

/// Skip `.git` anywhere (repository: clone-independent imports).
pub fn excludeGit() Exclude {
    return .{ .skipFn = skipGit };
}

/// Skip a TOP-LEVEL `import.json` only (promote: the draft manifest is not
/// carried into the canonical copy, but a nested import.json is content).
pub fn excludeTopImportJson() Exclude {
    return .{ .skipFn = skipTopImportJson };
}

fn skipNothing(_: *anyopaque, _: []const u8, _: bool) bool {
    return false;
}

fn skipGit(_: *anyopaque, name: []const u8, _: bool) bool {
    return std.mem.eql(u8, name, ".git");
}

fn skipTopImportJson(_: *anyopaque, name: []const u8, at_top: bool) bool {
    return at_top and std.mem.eql(u8, name, "import.json");
}

/// Recursively copy `src` into `dst`. `dest_root` is the absolute path of the
/// destination root used to build emitted action paths; `rel` is "" at the top
/// level. Regular files are copied and emitted via `sink`; directories are
/// created and recursed in sorted order; symlinks / unsupported entries raise
/// `error.UnsupportedEntry`. All allocations are arena-owned.
pub fn copyTree(
    arena: std.mem.Allocator,
    io: std.Io,
    src: std.Io.Dir,
    dst: std.Io.Dir,
    dest_root: []const u8,
    rel: []const u8,
    exclude: Exclude,
    sink: Sink,
) anyerror!void {
    const at_top = rel.len == 0;
    // Collect entries, then sort by name, so emitted copy_file actions come out in
    // a DETERMINISTIC order rather than filesystem readdir order (Finding #13; spec
    // "Output Contract": deterministic output). Entry names are invalidated by the
    // next iteration step, so each is duped into the arena by collectSortedEntries.
    const entries = try collectSortedEntries(arena, io, src);
    for (entries) |entry| {
        if (exclude.skip(entry.name, at_top)) continue;
        switch (entry.kind) {
            .file => {
                try src.copyFile(entry.name, dst, entry.name, io, .{});
                const abs = try joinRel(arena, dest_root, rel, entry.name);
                try sink.emit(abs);
            },
            .directory => {
                try dst.createDirPath(io, entry.name);
                var sub_src = try src.openDir(io, entry.name, .{ .iterate = true });
                defer sub_src.close(io);
                var sub_dst = try dst.openDir(io, entry.name, .{});
                defer sub_dst.close(io);
                const sub_rel = try joinRel(arena, "", rel, entry.name);
                try copyTree(arena, io, sub_src, sub_dst, dest_root, sub_rel, exclude, sink);
            },
            else => return error.UnsupportedEntry,
        }
    }
}

/// A directory entry whose `name` is owned by the arena (stable across iteration).
const SortedEntry = struct { name: []const u8, kind: std.Io.File.Kind };

/// Read every entry of `src` into an arena-owned slice sorted ascending by name,
/// so directory traversal is deterministic (Finding #13).
fn collectSortedEntries(arena: std.mem.Allocator, io: std.Io, src: std.Io.Dir) ![]SortedEntry {
    var list: std.ArrayList(SortedEntry) = .empty;
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        try list.append(arena, .{ .name = try arena.dupe(u8, entry.name), .kind = entry.kind });
    }
    const items = try list.toOwnedSlice(arena);
    std.mem.sort(SortedEntry, items, {}, struct {
        fn lessThan(_: void, a: SortedEntry, b: SortedEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return items;
}

/// Build an emitted action path. `base` is the destination root (or "" when
/// building a relative sub-path for recursion); `rel` is the path under the root
/// so far; `name` is the current entry.
fn joinRel(arena: std.mem.Allocator, base: []const u8, rel: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0) {
        if (rel.len == 0) return arena.dupe(u8, name);
        return std.fs.path.join(arena, &.{ rel, name });
    }
    if (rel.len == 0) return std.fs.path.join(arena, &.{ base, name });
    return std.fs.path.join(arena, &.{ base, rel, name });
}
