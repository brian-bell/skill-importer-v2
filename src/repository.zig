//! Repository scan / selection / batch import for `import repository`
//! (cli-clean-room-spec.md "import repository", "Collision Rules" >
//! "Repository batch import", "JSON Schemas > Repository Import Result").
//!
//! Flow (spec "import repository" + "Filesystem Safety" plan-then-execute):
//!   1. Check out the repository into a fresh temp dir (injected provider).
//!   2. Scan for valid skills: BFS to `scan_depth` (no-follow). The repository
//!      ROOT may itself be a skill; if the root has an INVALID SKILL.md we FAIL
//!      (do not skip it and import nested skills). Nested invalid SKILL.md dirs
//!      are ignored. Discovered skills are sorted by `file_name`.
//!   3. Selection:
//!        - no `--select`, exactly one valid skill  -> import it.
//!        - no `--select`, more than one valid skill -> return a `selection`
//!          result WITHOUT writing storage.
//!        - `--select` given: normalize `.`/`./name`; duplicate normalized
//!          selections are errors; an unmatched selection is an error.
//!   4. Import (single or batch). A batch preflights ALL selected skills
//!      (duplicate names, imports-root collisions) BEFORE writing any storage,
//!      and rolls back previously-written imports if a later write fails
//!      (reverse order), removing any roots it created.
//!
//! Manifests for repository imports use (spec "import repository"):
//!   source_type        = repository
//!   source_location     = <repository>#<relative-skill-path>
//!   source_repository   = { repository, skill_path }   (skill_path "." for root)

const std = @import("std");
const types = @import("types.zig");
const result = @import("result.zig");
const frontmatter = @import("frontmatter.zig");
const manifest_mod = @import("manifest.zig");
const hash = @import("hash.zig");
const git = @import("git.zig");

/// Repository scan depth limit (zig-clean-room-cli.md "Decisions locked in":
/// depth 8; spec "import repository" allows another explicit, documented,
/// tested limit). A skill directory is "at depth N" when its path under the
/// repository root has N components: the root skill is depth 0, a top-level
/// child `a` is depth 1, `a/b` depth 2, ... Skills beyond depth 8 are skipped.
pub const scan_depth: usize = 8;

pub const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    imports_root: []const u8,
    canonical_root: []const u8,
    clock: types.Clock,
};

const Result = result.Result(types.RepositoryImportResult);

/// One valid skill discovered in the checked-out repository.
const Discovered = struct {
    /// Frontmatter name.
    name: []const u8,
    description: []const u8,
    /// Repository-relative path, `.` for the root skill, else `a/b/...`.
    rel_path: []const u8,
    /// Absolute path of the skill directory in the checkout.
    abs_path: []const u8,
    content_hash: []const u8,
    /// The repository argument (spec: source_repository.repository).
    repository: []const u8,
    /// `<repository>#<rel_path>` (spec: manifest source_location).
    source_location: []const u8,
};

// --- public entry point ----------------------------------------------------

/// `import repository` (spec). `provider` is a `git.Provider` (or any value with
/// a compatible `checkout`); `select` holds raw `--select` values (possibly
/// empty). All output strings are owned by `c.arena`.
pub fn import(c: *Context, provider: git.Provider, repository: []const u8, select: []const []const u8) Result {
    return importImpl(c, provider, repository, select) catch |err| switch (err) {
        error.OutOfMemory => .{ .err = .{ .kind = .io_error, .reason = "out of memory" } },
        else => .{ .err = .{ .kind = .repository_error, .repository = dup(c, repository), .reason = @errorName(err) } },
    };
}

fn importImpl(c: *Context, provider: git.Provider, repository: []const u8, select: []const []const u8) !Result {
    const cwd = std.Io.Dir.cwd();

    // 1. Check out the repository into a fresh temp dir alongside the imports
    //    root (kept inside the same tree so tests stay hermetic). Cleaned up at
    //    the end regardless of outcome.
    const checkout = try makeCheckoutDir(c);
    defer cwd.deleteTree(c.io, checkout) catch {};

    provider.checkout(repository, checkout) catch |err| return switch (err) {
        error.GitUnavailable => .{ .err = .{ .kind = .git_unavailable, .repository = dup(c, repository), .reason = "git not installed" } },
        error.RepositoryError => .{ .err = .{ .kind = .repository_error, .repository = dup(c, repository) } },
    };

    // 2. Scan. An invalid ROOT SKILL.md fails the whole operation (spec).
    var discovered: std.ArrayList(Discovered) = .empty;
    switch (try scan(c, checkout, repository, &discovered)) {
        .ok => {},
        .err => |e| return .{ .err = e },
    }

    if (discovered.items.len == 0) {
        return .{ .err = .{ .kind = .empty_repository, .repository = dup(c, repository) } };
    }

    // 3. Selection.
    if (select.len == 0) {
        if (discovered.items.len == 1) {
            // Exactly one valid skill, no --select -> import it.
            return try singleImport(c, discovered.items[0]);
        }
        // More than one valid skill, no --select -> selection result, no storage.
        return try selectionResult(c, repository, discovered.items);
    }

    // --select given: normalize, reject duplicates, match against discovered.
    const chosen = switch (try resolveSelections(c, select, discovered.items)) {
        .ok => |list| list,
        .err => |e| return .{ .err = e },
    };
    return try batchImport(c, chosen);
}

// --- scan ------------------------------------------------------------------

/// BFS scan of the checkout to `scan_depth`, collecting valid skills. Returns a
/// classified error only for an invalid ROOT SKILL.md (spec); nested invalid
/// SKILL.md dirs are ignored. `discovered` is appended in BFS order then sorted
/// by `file_name` (the last path component; the root's is the empty string,
/// which sorts first).
const QueueItem = struct { rel: []const u8, depth: usize };

fn scan(c: *Context, checkout: []const u8, repository: []const u8, discovered: *std.ArrayList(Discovered)) !result.Result(void) {
    const cwd = std.Io.Dir.cwd();

    // Root skill first (spec: "root-skill-first then nested"). An invalid root
    // SKILL.md fails (spec: do not skip to nested). A VALID root skill that
    // cannot be hashed (e.g. a convenience symlink in the root trips
    // UnsupportedEntry, or a transient I/O error) must ALSO fail as a
    // repository_error — never silently drop the root and degrade to a
    // selection/empty result.
    switch (try readSkillAt(c, checkout)) {
        .present => |md| appendDiscovered(c, discovered, md, checkout, ".", repository) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .err = .{
                .kind = .repository_error,
                .repository = dup(c, repository),
                .path = dup(c, "."),
                .reason = "repository root skill could not be hashed",
            } },
        },
        .invalid => return .{ .err = .{ .kind = .repository_error, .repository = dup(c, repository), .path = dup(c, "SKILL.md"), .reason = "repository root SKILL.md is invalid" } },
        .absent => {},
    }

    // BFS over nested directories up to scan_depth. A directory whose path under
    // the root has N components is "at depth N": the root is depth 0, a top-level
    // child depth 1. We enqueue children only while depth < scan_depth, so a
    // skill directory can sit at depth up to scan_depth (depth 8 included, 9
    // skipped).
    var queue: std.ArrayList(QueueItem) = .empty;
    try enqueueChildren(c, cwd, checkout, "", 1, &queue);

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        const abs = try std.fs.path.join(c.arena, &.{ checkout, item.rel });

        // Nested skill: ignore INVALID content (spec: IgnoreInvalid for nested).
        // An UnsupportedEntry (e.g. a symlink in the skill dir) is treated as
        // invalid/not-importable and skipped, but any OTHER hash error is an
        // unexpected I/O failure that must surface as a repository_error rather
        // than silently dropping an otherwise-valid skill (it would later be
        // misreported as missing_selection / empty_repository).
        switch (try readSkillAt(c, abs)) {
            .present => |md| appendDiscovered(c, discovered, md, abs, item.rel, repository) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnsupportedEntry => {},
                else => return .{ .err = .{
                    .kind = .repository_error,
                    .repository = dup(c, repository),
                    .path = dup(c, item.rel),
                    .reason = "skill directory could not be hashed",
                } },
            },
            .invalid, .absent => {},
        }

        if (item.depth < scan_depth) {
            try enqueueChildren(c, cwd, checkout, item.rel, item.depth + 1, &queue);
        }
    }

    // Sort by file_name (last path component). The root skill ("." => "") sorts
    // first.
    std.mem.sort(Discovered, discovered.items, {}, lessThanByFileName);
    return .{ .ok = {} };
}

/// Enqueue the immediate child directories of `<checkout>/<parent_rel>` at
/// `child_depth` (no-follow: symlinked directories are skipped). Missing parents
/// are tolerated.
fn enqueueChildren(
    c: *Context,
    cwd: std.Io.Dir,
    checkout: []const u8,
    parent_rel: []const u8,
    child_depth: usize,
    queue: *std.ArrayList(QueueItem),
) !void {
    const parent_abs = if (parent_rel.len == 0)
        try c.arena.dupe(u8, checkout)
    else
        try std.fs.path.join(c.arena, &.{ checkout, parent_rel });

    var dir = cwd.openDir(c.io, parent_abs, .{ .iterate = true }) catch return;
    defer dir.close(c.io);

    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        // No-follow: only descend into real directories, never symlinks.
        if (entry.kind != .directory) continue;
        const child_rel = if (parent_rel.len == 0)
            try c.arena.dupe(u8, entry.name)
        else
            try std.fs.path.join(c.arena, &.{ parent_rel, entry.name });
        try queue.append(c.arena, .{ .rel = child_rel, .depth = child_depth });
    }
}

/// Hash a skill directory for the repository content_hash, EXCLUDING version-
/// control metadata (`.git`) so the digest is deterministic across clones and a
/// `.git` symlink does not trip `error.UnsupportedEntry` (spec "import
/// repository"). The error is propagated to the caller, which classifies it:
/// `error.UnsupportedEntry` is "invalid skill content" (skipped for NESTED
/// skills per IgnoreInvalid; a FAIL for the ROOT), while any other error is an
/// unexpected I/O failure that must surface as a repository_error rather than
/// making a valid skill vanish.
fn appendDiscovered(
    c: *Context,
    discovered: *std.ArrayList(Discovered),
    md: frontmatter.Metadata,
    abs_path: []const u8,
    rel_path: []const u8,
    repository: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(c.io, abs_path, .{ .iterate = true });
    defer dir.close(c.io);
    const content_hash = try hash.hashDirectoryExcludingGit(c.arena, c.io, dir);
    const source_location = try std.fmt.allocPrint(c.arena, "{s}#{s}", .{ repository, rel_path });
    try discovered.append(c.arena, .{
        .name = try c.arena.dupe(u8, md.name),
        .description = try c.arena.dupe(u8, md.description),
        .rel_path = try c.arena.dupe(u8, rel_path),
        .abs_path = try c.arena.dupe(u8, abs_path),
        .content_hash = content_hash,
        .repository = try c.arena.dupe(u8, repository),
        .source_location = source_location,
    });
}

const SkillRead = union(enum) {
    present: frontmatter.Metadata,
    invalid,
    absent,
};

/// Read `<abs_dir>/SKILL.md`: `.absent` if no SKILL.md, `.invalid` if present but
/// frontmatter does not validate, `.present` with arena-duped metadata otherwise.
fn readSkillAt(c: *Context, abs_dir: []const u8) !SkillRead {
    const p = try std.fs.path.join(c.arena, &.{ abs_dir, "SKILL.md" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };
    return switch (frontmatter.parse(c.arena, bytes)) {
        .ok => |md| .{ .present = .{
            .name = try c.arena.dupe(u8, md.name),
            .description = try c.arena.dupe(u8, md.description),
        } },
        .err => .invalid,
    };
}

fn lessThanByFileName(_: void, a: Discovered, b: Discovered) bool {
    return std.mem.lessThan(u8, fileName(a.rel_path), fileName(b.rel_path));
}

fn fileName(rel: []const u8) []const u8 {
    if (std.mem.eql(u8, rel, ".")) return "";
    return std.fs.path.basename(rel);
}

// --- selection -------------------------------------------------------------

fn selectionResult(c: *Context, repository: []const u8, discovered: []const Discovered) !Result {
    var skills: std.ArrayList(types.RepositorySkillChoice) = .empty;
    for (discovered) |d| {
        try skills.append(c.arena, .{
            .name = d.name,
            .description = d.description,
            .relative_path = d.rel_path,
        });
    }
    return .{ .ok = .{ .selection = .{
        .repository = dup(c, repository),
        .skills = skills.items,
    } } };
}

/// Normalize `--select` values, reject duplicates, and match against discovered
/// skills (spec "import repository"). Returns the chosen `Discovered`s in the
/// order the selections were given.
fn resolveSelections(c: *Context, select: []const []const u8, discovered: []const Discovered) !result.Result([]const Discovered) {
    var normalized: std.ArrayList([]const u8) = .empty;
    var chosen: std.ArrayList(Discovered) = .empty;

    for (select) |raw| {
        const norm = normalizeSelection(raw);
        // Duplicate normalized selections are errors (spec).
        for (normalized.items) |prev| {
            if (std.mem.eql(u8, prev, norm)) {
                return .{ .err = .{ .kind = .duplicate_selection, .path = dup(c, norm) } };
            }
        }
        try normalized.append(c.arena, try c.arena.dupe(u8, norm));

        // Match against a discovered skill by normalized relative path.
        const match = findByRel(discovered, norm) orelse {
            return .{ .err = .{ .kind = .missing_selection, .path = dup(c, norm) } };
        };
        try chosen.append(c.arena, match);
    }
    return .{ .ok = chosen.items };
}

/// Normalize a selection per spec: `.` stays `.`; a leading `./` is stripped
/// (`./name` -> `name`). Trailing slashes are trimmed.
fn normalizeSelection(raw: []const u8) []const u8 {
    var s = raw;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "./")) return ".";
    if (std.mem.startsWith(u8, s, "./")) s = s[2..];
    if (s.len == 0) return ".";
    return s;
}

fn findByRel(discovered: []const Discovered, rel: []const u8) ?Discovered {
    for (discovered) |d| {
        if (std.mem.eql(u8, d.rel_path, rel)) return d;
    }
    return null;
}

// --- import (single + batch) -----------------------------------------------

fn singleImport(c: *Context, d: Discovered) !Result {
    // Imports-root collision preflight (spec "Collision Rules").
    switch (try importsCollision(c, d.name)) {
        .ok => {},
        .err => |e| return .{ .err = e },
    }
    var created_root = false;
    const bi = writeSkill(c, d, &created_root) catch |err| {
        // Leave no partial storage on failure (spec "Filesystem Safety"): remove
        // the partially-written skill dir, and the imports root if WE created it.
        const partial = std.fs.path.join(c.arena, &.{ c.imports_root, d.name }) catch c.imports_root;
        std.Io.Dir.cwd().deleteTree(c.io, partial) catch {};
        if (created_root) std.Io.Dir.cwd().deleteTree(c.io, c.imports_root) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .err = .{ .kind = .io_error, .name = dup(c, d.name), .reason = "write repository skill" } };
    };
    return .{ .ok = .{ .imported = .{
        .skill_name = bi.skill_name,
        .skill_path = bi.skill_path,
        .manifest_path = bi.manifest_path,
        .manifest = bi.manifest,
        .actions = bi.actions,
    } } };
}

/// Batch import (spec "Repository batch import"): preflight ALL selected skills
/// (duplicate names + imports-root collisions) before writing any storage, then
/// write each; on a later failure roll back previously-written imports in
/// reverse order plus any roots this batch created.
fn batchImport(c: *Context, chosen: []const Discovered) !Result {
    // Preflight: duplicate selected skill names (spec).
    for (chosen, 0..) |a, i| {
        for (chosen[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                return .{ .err = .{ .kind = .duplicate_skill_name, .name = dup(c, a.name) } };
            }
        }
    }
    // Preflight: imports-root collisions (spec).
    for (chosen) |d| {
        switch (try importsCollision(c, d.name)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    }

    // Execute, tracking written skill dirs (for reverse-order rollback) and
    // whether THIS batch created the imports root.
    var imports: std.ArrayList(types.RepositoryBatchImport) = .empty;
    var written_dirs: std.ArrayList([]const u8) = .empty;
    var batch_created_root = false;

    for (chosen) |d| {
        var created_root = false;
        const bi = writeSkill(c, d, &created_root) catch |err| {
            // Remove the partially-written CURRENT skill dir first, then roll back
            // previously-written imports (reverse order) + the root if this batch
            // created it (spec "Filesystem Safety": leave no partial storage).
            const partial = std.fs.path.join(c.arena, &.{ c.imports_root, d.name }) catch c.imports_root;
            std.Io.Dir.cwd().deleteTree(c.io, partial) catch {};
            rollbackBatch(c, written_dirs.items, batch_created_root or created_root);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .err = .{ .kind = .io_error, .name = dup(c, d.name), .reason = "write batch skill" } };
        };
        if (created_root) batch_created_root = true;
        try written_dirs.append(c.arena, bi.skill_path);
        try imports.append(c.arena, bi);
    }

    return .{ .ok = .{ .imported_batch = .{ .imports = imports.items } } };
}

/// Reverse-order rollback of written skill directories, then the imports root if
/// this batch created it (spec "Repository batch import").
fn rollbackBatch(c: *Context, written_dirs: []const []const u8, created_root: bool) void {
    const cwd = std.Io.Dir.cwd();
    var i: usize = written_dirs.len;
    while (i > 0) {
        i -= 1;
        cwd.deleteTree(c.io, written_dirs[i]) catch {};
    }
    if (created_root) cwd.deleteTree(c.io, c.imports_root) catch {};
}

/// Write one repository skill into `<imports_root>/<name>`: recursively copy the
/// checkout skill dir, write the repository manifest, and return the import
/// record + actions. `created_root_out` is set true iff the imports root did not
/// exist before this call.
fn writeSkill(c: *Context, d: Discovered, created_root_out: *bool) !types.RepositoryBatchImport {
    const cwd = std.Io.Dir.cwd();

    const root_existed = blk: {
        cwd.access(c.io, c.imports_root, .{}) catch break :blk false;
        break :blk true;
    };
    created_root_out.* = !root_existed;

    const skill_dir = try std.fs.path.join(c.arena, &.{ c.imports_root, d.name });
    const manifest_path = try std.fs.path.join(c.arena, &.{ skill_dir, "import.json" });

    const manifest: types.ImportManifest = .{
        .source_type = .repository,
        .source_location = d.source_location,
        .source_repository = .{ .repository = d.repository, .skill_path = d.rel_path },
        .imported_at = c.clock.now(),
        .content_hash = d.content_hash,
        .promoted = false,
    };

    var actions: std.ArrayList(types.ImportAction) = .empty;

    try cwd.createDirPath(c.io, skill_dir);
    try actions.append(c.arena, .{ .action = .create_directory, .path = skill_dir });

    var src = try cwd.openDir(c.io, d.abs_path, .{ .iterate = true });
    defer src.close(c.io);
    var dst = try cwd.openDir(c.io, skill_dir, .{});
    defer dst.close(c.io);
    try copyDirRecording(c, src, dst, skill_dir, "", &actions);

    const bytes = try manifest_mod.toBytes(c.arena, manifest);
    try cwd.writeFile(c.io, .{ .sub_path = manifest_path, .data = bytes });
    try actions.append(c.arena, .{ .action = .write_manifest, .path = manifest_path });

    return .{
        .skill_name = try c.arena.dupe(u8, d.name),
        .skill_path = skill_dir,
        .manifest_path = manifest_path,
        .manifest = manifest,
        .actions = actions.items,
    };
}

fn copyDirRecording(
    c: *Context,
    src: std.Io.Dir,
    dst: std.Io.Dir,
    skill_dir: []const u8,
    rel: []const u8,
    actions: *std.ArrayList(types.ImportAction),
) !void {
    var it = src.iterate();
    while (try it.next(c.io)) |entry| {
        // Exclude version-control metadata (`.git`) from the copy so the imported
        // skill never carries a clone's `.git` directory/symlink, matching the
        // content_hash which also excludes it (spec "import repository";
        // deterministic, clone-independent imports). `.git` anywhere is skipped.
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        switch (entry.kind) {
            .file => {
                try src.copyFile(entry.name, dst, entry.name, c.io, .{});
                const abs = try joinRel(c, skill_dir, rel, entry.name);
                try actions.append(c.arena, .{ .action = .copy_file, .path = abs });
            },
            .directory => {
                try dst.createDirPath(c.io, entry.name);
                var sub_src = try src.openDir(c.io, entry.name, .{ .iterate = true });
                defer sub_src.close(c.io);
                var sub_dst = try dst.openDir(c.io, entry.name, .{});
                defer sub_dst.close(c.io);
                const sub_rel = try joinRel(c, "", rel, entry.name);
                try copyDirRecording(c, sub_src, sub_dst, skill_dir, sub_rel, actions);
            },
            else => return error.UnsupportedEntry,
        }
    }
}

fn joinRel(c: *Context, base: []const u8, rel: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0) {
        if (rel.len == 0) return c.arena.dupe(u8, name);
        return std.fs.path.join(c.arena, &.{ rel, name });
    }
    if (rel.len == 0) return std.fs.path.join(c.arena, &.{ base, name });
    return std.fs.path.join(c.arena, &.{ base, rel, name });
}

// --- collisions ------------------------------------------------------------

/// Refuse a collision within the imports root by directory name OR by SKILL.md
/// frontmatter name (spec "Collision Rules"). Canonical collisions are allowed.
fn importsCollision(c: *Context, name: []const u8) !result.Result(void) {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(c.io, c.imports_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .ok = {} },
        else => return err,
    };
    defer dir.close(c.io);

    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, name)) {
            return .{ .err = .{ .kind = .import_collision, .name = dup(c, name) } };
        }
        if (try frontmatterName(c, dir, entry.name)) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                return .{ .err = .{ .kind = .import_collision, .name = dup(c, name) } };
            }
        }
    }
    return .{ .ok = {} };
}

fn frontmatterName(c: *Context, dir: std.Io.Dir, sub: []const u8) !?[]const u8 {
    const p = try std.fs.path.join(c.arena, &.{ sub, "SKILL.md" });
    const bytes = dir.readFileAlloc(c.io, p, c.arena, .unlimited) catch return null;
    return switch (frontmatter.parse(c.arena, bytes)) {
        .ok => |m| m.name,
        .err => null,
    };
}

// --- checkout dir ----------------------------------------------------------

/// Monotonic per-process counter giving each checkout a distinct directory name
/// so concurrent operations within one process never collide.
var checkout_seq: std.atomic.Value(u64) = .init(0);

/// Create a fresh, unique checkout directory beside the imports root (inside the
/// same temp tree under test, so nothing real is touched). The parent of the
/// imports root is created if needed; the checkout dir itself is created empty.
fn makeCheckoutDir(c: *Context) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const parent = std.fs.path.dirname(c.imports_root) orelse ".";
    try cwd.createDirPath(c.io, parent);
    const seq = checkout_seq.fetchAdd(1, .monotonic);
    // Combine a per-process id (pointer-derived), a real wall-clock nanosecond
    // reading, and a sequence so two processes sharing the parent do not collide.
    // The injected domain `clock` is deliberately NOT used here: it backs the
    // manifest `imported_at` (spec "Import Manifest"), and consuming a tick for a
    // checkout-dir name would couple the import timestamp to an unrelated naming
    // concern (and break clocks that advance per call).
    const mono = std.Io.Clock.now(.awake, c.io).nanoseconds;
    const tag = @intFromPtr(c) ^ @as(usize, @bitCast(@as(isize, @truncate(mono))));
    const name = try std.fmt.allocPrint(c.arena, ".skill-importer-checkout-{x}-{d}", .{ tag, seq });
    const path = try std.fs.path.join(c.arena, &.{ parent, name });
    // Start from a clean slate in case a stale dir lingers from a crashed run.
    cwd.deleteTree(c.io, path) catch {};
    try cwd.createDirPath(c.io, path);
    return path;
}

// --- helpers ---------------------------------------------------------------

fn dup(c: *Context, s: []const u8) []const u8 {
    return c.arena.dupe(u8, s) catch s;
}
