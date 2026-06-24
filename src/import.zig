//! markdown / path / url imports (cli-clean-room-spec.md "import markdown",
//! "import path", "import url", "Collision Rules", "Filesystem Safety").
//!
//! Each import validates source metadata, enforces collision rules, then stores
//! the skill atomically: a failure during storage rolls back so no partial
//! import directory survives (spec: "leave no partial storage on failure" /
//! "do not create import storage").
//!
//! Collision rules (spec "Collision Rules"):
//!   - refuse a collision within the imports root by directory name OR by
//!     SKILL.md frontmatter name;
//!   - allow a collision with the canonical root (replacement drafts).
//!
//! Directory imports additionally (spec "import path"):
//!   - require SKILL.md, recursively copy regular files + directories,
//!   - reject symlinks / unsupported entries,
//!   - reject a reserved `import.json` in the source,
//!   - reject an imports root located inside the source directory.

const std = @import("std");
const types = @import("types.zig");
const result = @import("result.zig");
const frontmatter = @import("frontmatter.zig");
const manifest_mod = @import("manifest.zig");
const hash = @import("hash.zig");
const fsutil = @import("fsutil.zig");
const net = @import("net.zig");
const recording_copy = @import("recording_copy.zig");

/// Injected dependencies for an import operation. All output strings are owned
/// by `arena`.
pub const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    imports_root: []const u8,
    canonical_root: []const u8,
    clock: types.Clock,
};

/// What content to materialize into the new import directory, plus the manifest
/// source metadata that distinguishes markdown/local_path/url.
const Plan = struct {
    /// Validated frontmatter metadata (borrows `skill_bytes`).
    name: []const u8,
    /// The SKILL.md bytes to write (for non-directory imports).
    skill_bytes: ?[]const u8,
    /// For directory imports: the absolute source directory to copy recursively.
    src_dir: ?[]const u8,
    source_type: types.ImportSourceType,
    source_location: ?[]const u8,
    content_hash: []const u8,
};

const Result = result.Result(types.ImportResult);

// --- public entry points ---------------------------------------------------

/// `import markdown` (spec): store `markdown_bytes` (read from stdin by the CLI).
/// `source_location` is the optional `--source-location` value.
pub fn markdown(c: *Context, markdown_bytes: []const u8, source_location: ?[]const u8) Result {
    const md = switch (frontmatter.parse(c.arena, markdown_bytes)) {
        .ok => |m| m,
        .err => |e| return .{ .err = e },
    };
    const content_hash = hash.hashString(c.arena, markdown_bytes) catch
        return oom();
    const plan: Plan = .{
        .name = md.name,
        .skill_bytes = markdown_bytes,
        .src_dir = null,
        .source_type = .markdown,
        .source_location = source_location,
        .content_hash = content_hash,
    };
    return store(c, plan);
}

/// `import path` (spec): a local Markdown file or a local skill directory.
pub fn path(c: *Context, src_path: []const u8) Result {
    const kind = fsutil.classify(c.io, std.Io.Dir.cwd(), src_path) catch
        return ioErr("classify source path", src_path);
    return switch (kind) {
        .file => importFile(c, src_path),
        .directory => importDirectory(c, src_path),
        .missing => .{ .err = .{ .kind = .io_error, .path = dup(c, src_path), .reason = "source path not found" } },
        .symlink => .{ .err = .{ .kind = .unsupported_entry, .path = dup(c, src_path), .reason = "source path is a symlink" } },
    };
}

/// `import url` (spec): fetch markdown from `url`, validate, store. On any fetch/
/// size/UTF-8/validation failure, no storage is created.
pub fn url(c: *Context, fetcher: net.Fetcher, target_url: []const u8) Result {
    const body = fetcher.fetch(c.arena, target_url) catch |err| return .{ .err = .{
        .kind = switch (err) {
            error.SizeExceeded => .size_exceeded,
            error.InvalidUtf8 => .invalid_utf8,
            error.Timeout => .timeout,
            error.OutOfMemory => return oom(),
            error.FetchFailed => .fetch_failed,
        },
        .url = dup(c, target_url),
    } };

    const md = switch (frontmatter.parse(c.arena, body)) {
        .ok => |m| m,
        .err => |e| {
            var e2 = e;
            e2.url = dup(c, target_url);
            return .{ .err = e2 };
        },
    };
    const content_hash = hash.hashString(c.arena, body) catch return oom();
    const plan: Plan = .{
        .name = md.name,
        .skill_bytes = body,
        .src_dir = null,
        .source_type = .url,
        .source_location = dup(c, target_url),
        .content_hash = content_hash,
    };
    return store(c, plan);
}

// --- path sub-cases --------------------------------------------------------

fn importFile(c: *Context, src_path: []const u8) Result {
    const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, src_path, c.arena, .unlimited) catch
        return ioErr("read source file", src_path);
    const md = switch (frontmatter.parse(c.arena, bytes)) {
        .ok => |m| m,
        .err => |e| return .{ .err = e },
    };
    const content_hash = hash.hashString(c.arena, bytes) catch return oom();
    const plan: Plan = .{
        .name = md.name,
        .skill_bytes = bytes,
        .src_dir = null,
        .source_type = .local_path,
        .source_location = dup(c, src_path),
        .content_hash = content_hash,
    };
    return store(c, plan);
}

fn importDirectory(c: *Context, src_dir: []const u8) Result {
    // Open the source directory.
    var dir = std.Io.Dir.cwd().openDir(c.io, src_dir, .{ .iterate = true }) catch
        return ioErr("open source directory", src_dir);
    defer dir.close(c.io);

    // Must contain SKILL.md with valid frontmatter (spec "import path").
    const skill_bytes = dir.readFileAlloc(c.io, "SKILL.md", c.arena, .unlimited) catch
        return .{ .err = .{ .kind = .io_error, .path = dup(c, src_dir), .reason = "directory has no SKILL.md" } };
    const md = switch (frontmatter.parse(c.arena, skill_bytes)) {
        .ok => |m| m,
        .err => |e| return .{ .err = e },
    };

    // Reject a reserved import.json in the source (spec "import path").
    if (existsIn(c, dir, "import.json")) {
        return .{ .err = .{ .kind = .reserved_manifest_in_source, .path = dup(c, src_dir) } };
    }

    // The imports root must not be inside the source directory (spec "import
    // path"): canonicalize both and compare.
    if (importsRootInsideSource(c, src_dir)) {
        return .{ .err = .{ .kind = .imports_root_inside_source, .path = dup(c, src_dir) } };
    }

    // Reject symlinks / unsupported entries anywhere in the tree (spec "import
    // path"). hashDirectory walks the tree and returns UnsupportedEntry for any
    // non-file/non-dir entry, so it doubles as the guard + content hash.
    const content_hash = hash.hashDirectory(c.arena, c.io, dir) catch |err| switch (err) {
        error.UnsupportedEntry => return .{ .err = .{
            .kind = .unsupported_entry,
            .path = dup(c, src_dir),
            .reason = "source directory contains a symlink or unsupported entry",
        } },
        error.OutOfMemory => return oom(),
        else => return ioErr("hash source directory", src_dir),
    };

    const plan: Plan = .{
        .name = md.name,
        .skill_bytes = null,
        .src_dir = dup(c, src_dir),
        .source_type = .local_path,
        .source_location = dup(c, src_dir),
        .content_hash = content_hash,
    };
    return store(c, plan);
}

// --- core store (plan -> execute, with rollback) ---------------------------

fn store(c: *Context, plan: Plan) Result {
    if (!frontmatter.validateSkillName(plan.name)) {
        return .{ .err = .{ .kind = .invalid_name, .name = dup(c, plan.name) } };
    }

    // Collision preflight within the imports root (spec "Collision Rules").
    switch (importsCollision(c, plan.name)) {
        .ok => {},
        .err => |e| return .{ .err = e },
    }

    const skill_dir = std.fs.path.join(c.arena, &.{ c.imports_root, plan.name }) catch return oom();
    const manifest_path = std.fs.path.join(c.arena, &.{ skill_dir, "import.json" }) catch return oom();

    // Build the manifest ONCE so the bytes written to disk and the manifest
    // returned to the caller are identical (spec "JSON Schemas > Import Result":
    // the result manifest IS what is persisted in import.json). In particular
    // `imported_at` is read from a SINGLE clock.now() call; computing it twice
    // (once for disk, once for the result) could diverge under a real wall clock.
    const manifest: types.ImportManifest = .{
        .source_type = plan.source_type,
        .source_location = plan.source_location,
        .source_repository = null,
        .imported_at = c.clock.now(),
        .content_hash = plan.content_hash,
        .promoted = false,
    };

    var actions: std.ArrayList(types.ImportAction) = .empty;

    // Track whether WE created the skill directory INDEPENDENTLY of the action
    // list. The `create_directory` action is appended AFTER createDirPath
    // succeeds, so if that append itself OOMs the action list is still empty —
    // inspecting actions.items[0] would then wrongly skip rollback and leave an
    // empty <imports-root>/<name> behind (Finding #14; spec "Filesystem Safety":
    // "leave no partial storage on failure"). This flag is set the moment the
    // directory is created, so rollback always fires.
    var created_dir = false;

    // Execute; on any failure roll back the created skill directory so no
    // partial import survives (spec "Filesystem Safety"). Only delete the skill
    // directory if WE created it — never remove a pre-existing entry that the
    // create step failed against (spec: do not remove external entries).
    executeStore(c, plan, manifest, skill_dir, manifest_path, &actions, &created_dir) catch |err| {
        if (created_dir) rollback(c, skill_dir);
        if (err == error.OutOfMemory) return oom();
        return ioErr("write import storage", skill_dir);
    };

    return .{ .ok = .{
        .skill_name = dup(c, plan.name),
        .skill_path = skill_dir,
        .manifest_path = manifest_path,
        .manifest = manifest,
        .actions = actions.toOwnedSlice(c.arena) catch return oom(),
    } };
}

fn executeStore(
    c: *Context,
    plan: Plan,
    manifest: types.ImportManifest,
    skill_dir: []const u8,
    manifest_path: []const u8,
    actions: *std.ArrayList(types.ImportAction),
    created_dir: *bool,
) !void {
    const cwd = std.Io.Dir.cwd();

    // create_directory. Record that WE created the directory BEFORE appending the
    // action, so rollback fires even if the append OOMs (Finding #14).
    try cwd.createDirPath(c.io, skill_dir);
    created_dir.* = true;
    try actions.append(c.arena, .{ .action = .create_directory, .path = skill_dir });

    if (plan.src_dir) |src_dir| {
        // Directory import: recursively copy, recording a copy_file action per
        // regular file (spec "Import action values": copy_file).
        var src = try cwd.openDir(c.io, src_dir, .{ .iterate = true });
        defer src.close(c.io);
        var dst = try cwd.openDir(c.io, skill_dir, .{});
        defer dst.close(c.io);
        var snk: CopyFileSink = .{ .arena = c.arena, .actions = actions };
        try recording_copy.copyTree(c.arena, c.io, src, dst, skill_dir, "", recording_copy.exclude_none, snk.sink());
    } else {
        // Single-file import: write SKILL.md (write_skill action).
        const skill_path = try std.fs.path.join(c.arena, &.{ skill_dir, "SKILL.md" });
        try cwd.writeFile(c.io, .{ .sub_path = skill_path, .data = plan.skill_bytes.? });
        try actions.append(c.arena, .{ .action = .write_skill, .path = skill_path });
    }

    // write_manifest (no trailing newline on disk). Serialize the SAME manifest
    // value that store() returns, so the on-disk imported_at/content_hash match
    // the result exactly.
    const bytes = try manifest_mod.toBytes(c.arena, manifest);
    try cwd.writeFile(c.io, .{ .sub_path = manifest_path, .data = bytes });
    try actions.append(c.arena, .{ .action = .write_manifest, .path = manifest_path });
}

/// Adapts `recording_copy.copyTree`'s `Sink` to an import action list: each copied
/// regular file appends a `copy_file` action with its absolute destination path
/// (spec "Import action values": copy_file). The emitted path is arena-owned by
/// copyTree, so it is appended directly.
const CopyFileSink = struct {
    arena: std.mem.Allocator,
    actions: *std.ArrayList(types.ImportAction),
    fn sink(self: *CopyFileSink) recording_copy.Sink {
        return .{ .ctx = self, .emitFn = emit };
    }
    fn emit(ctx: *anyopaque, abs_path: []const u8) anyerror!void {
        const self: *CopyFileSink = @ptrCast(@alignCast(ctx));
        try self.actions.append(self.arena, .{ .action = .copy_file, .path = abs_path });
    }
};

/// Best-effort removal of a partially-written import directory (rollback).
fn rollback(c: *Context, skill_dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(c.io, skill_dir) catch {};
}

// --- collision detection ---------------------------------------------------

/// Refuse a collision within the imports root by directory name OR by SKILL.md
/// frontmatter name (spec "Collision Rules"). Canonical collisions are allowed
/// and not checked here.
fn importsCollision(c: *Context, name: []const u8) result.Result(void) {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(c.io, c.imports_root, .{ .iterate = true }) catch |err| switch (err) {
        // Missing imports root => no collision possible (spec: missing roots are
        // empty).
        error.FileNotFound => return .{ .ok = {} },
        else => return .{ .err = .{ .kind = .io_error, .path = dup(c, c.imports_root), .reason = "open imports root" } },
    };
    defer dir.close(c.io);

    var it = dir.iterate();
    while (it.next(c.io) catch |err| {
        return .{ .err = .{ .kind = .io_error, .reason = @errorName(err) } };
    }) |entry| {
        if (entry.kind != .directory) continue;
        // Collision by directory name.
        if (std.mem.eql(u8, entry.name, name)) {
            return .{ .err = .{ .kind = .import_collision, .name = dup(c, name) } };
        }
        // Collision by frontmatter name of an existing imported skill.
        if (frontmatterName(c, dir, entry.name)) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                return .{ .err = .{ .kind = .import_collision, .name = dup(c, name) } };
            }
        }
    }
    return .{ .ok = {} };
}

/// Read the frontmatter `name` of `<dir>/<sub>/SKILL.md`, or null if absent /
/// invalid.
fn frontmatterName(c: *Context, dir: std.Io.Dir, sub: []const u8) ?[]const u8 {
    const p = std.fs.path.join(c.arena, &.{ sub, "SKILL.md" }) catch return null;
    const bytes = dir.readFileAlloc(c.io, p, c.arena, .unlimited) catch return null;
    return switch (frontmatter.parse(c.arena, bytes)) {
        .ok => |m| m.name,
        .err => null,
    };
}

// --- guards ----------------------------------------------------------------

/// True iff `sub` exists directly under `dir` (no-follow).
fn existsIn(c: *Context, dir: std.Io.Dir, sub: []const u8) bool {
    _ = dir.statFile(c.io, sub, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// True iff the imports root resolves to a path inside (or equal to) the source
/// directory (spec "import path"). Both are canonicalized through any existing
/// ancestors so symlinked temp roots compare correctly.
fn importsRootInsideSource(c: *Context, src_dir: []const u8) bool {
    const src = fsutil.canonicalizeExistingAncestor(c.arena, c.io, src_dir) catch
        std.fs.path.resolve(c.arena, &.{src_dir}) catch return false;
    const imports = fsutil.canonicalizeExistingAncestor(c.arena, c.io, c.imports_root) catch
        std.fs.path.resolve(c.arena, &.{c.imports_root}) catch return false;
    if (!std.mem.startsWith(u8, imports, src)) return false;
    if (imports.len == src.len) return true;
    return imports[src.len] == std.fs.path.sep;
}

// --- small helpers ---------------------------------------------------------

fn dup(c: *Context, s: []const u8) []const u8 {
    return c.arena.dupe(u8, s) catch s;
}

fn oom() Result {
    return .{ .err = .{ .kind = .out_of_memory, .reason = "out of memory" } };
}

fn ioErr(reason: []const u8, p: []const u8) Result {
    return .{ .err = .{ .kind = .io_error, .path = p, .reason = reason } };
}
