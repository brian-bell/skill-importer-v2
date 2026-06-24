//! Discovery for the `list` command (cli-clean-room-spec.md "list" +
//! "JSON Schemas > Inventory").
//!
//! Scans the four roots (canonical, imports, claude_code, codex). Missing roots
//! are treated as empty, not an error (spec "list": "Missing roots are treated
//! as empty"). Canonical and imported skills are identified by a valid SKILL.md;
//! a malformed `import.json` for an otherwise-valid imported skill is an error
//! (spec "list": discovery behavior). Agent-root entries are classified by entry
//! type and symlink target. Duplicate skills across roots are merged with
//! precedence canonical < imported < agent_only; `promoted` is OR-accumulated;
//! `source_repository` comes from the imported entry. Output is name-sorted, and
//! repository-imported skills are grouped in `source_repositories`, sorted by
//! `(skill_name, skill_path)`.

const std = @import("std");
const types = @import("types.zig");
const result = @import("result.zig");
const frontmatter = @import("frontmatter.zig");
const manifest = @import("manifest.zig");
const managed_entry = @import("managed_entry.zig");

/// Absolute paths of the four roots (cli-clean-room-spec.md "Root Resolution").
pub const Roots = struct {
    canonical: []const u8,
    imports: []const u8,
    claude_code: []const u8,
    codex: []const u8,
};

/// Per-skill accumulator while merging across roots. Keyed by skill name.
/// `canonical_dir`/`imports_dir` are the ON-DISK directory names this skill
/// occupies in the canonical / imports root, which may differ from the
/// frontmatter `name` (Finding #7); ops resolves real paths from these.
const Merged = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    source: types.SkillSource,
    source_repository: ?types.SourceRepository = null,
    promoted: bool = false,
    claude: types.AgentEntryStatus = .missing,
    codex: types.AgentEntryStatus = .missing,
    canonical_dir: ?[]const u8 = null,
    imports_dir: ?[]const u8 = null,
};

/// Discover the full inventory. All returned strings/slices are owned by `arena`.
/// A `result.err` payload is returned for classified failures (e.g. malformed
/// manifest, spec "list"); unexpected I/O surfaces as `discovery_error`.
pub fn discover(arena: std.mem.Allocator, io: std.Io, roots: Roots) result.Result(types.Inventory) {
    return discoverImpl(arena, io, roots) catch |err| switch (err) {
        error.OutOfMemory => .{ .err = .{ .kind = .io_error, .reason = "out of memory" } },
        else => .{ .err = .{ .kind = .discovery_error, .reason = @errorName(err) } },
    };
}

fn discoverImpl(arena: std.mem.Allocator, io: std.Io, roots: Roots) anyerror!result.Result(types.Inventory) {
    const cwd = std.Io.Dir.cwd();

    // name -> *Merged, preserving insertion but emitted name-sorted at the end.
    var map: std.StringArrayHashMapUnmanaged(*Merged) = .empty;

    // --- canonical root: valid SKILL.md => source canonical ---
    {
        var dir = try openRoot(io, cwd, roots.canonical);
        if (dir) |*d| {
            defer d.close(io);
            var it = d.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .directory) continue;
                const md = try readSkill(arena, io, d.*, entry.name) orelse continue;
                const m = try getOrPut(arena, &map, md.name);
                m.source = .canonical;
                if (m.description == null) m.description = md.description;
                // Record the ON-DISK directory name (may differ from md.name) so
                // ops resolves the real `<canonical>/<dir>` path (Finding #7).
                if (m.canonical_dir == null) m.canonical_dir = try arena.dupe(u8, entry.name);
            }
        }
    }

    // --- imports root: valid SKILL.md => source imported; import.json optional
    // but malformed import.json for a valid imported skill is an error. ---
    {
        var dir = try openRoot(io, cwd, roots.imports);
        if (dir) |*d| {
            defer d.close(io);
            var it = d.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .directory) continue;
                const md = try readSkill(arena, io, d.*, entry.name) orelse continue;
                const m = try getOrPut(arena, &map, md.name);
                // imported takes precedence over canonical (canonical < imported).
                m.source = .imported;
                if (m.description == null) m.description = md.description;
                // Record the ON-DISK directory name (may differ from md.name) so
                // ops resolves the real `<imports>/<dir>` path (Finding #7).
                if (m.imports_dir == null) m.imports_dir = try arena.dupe(u8, entry.name);

                // Optional import.json; malformed => discovery failure (spec "list").
                const man = readManifest(arena, io, d.*, entry.name) catch {
                    return .{ .err = .{
                        .kind = .malformed_manifest,
                        .name = try arena.dupe(u8, md.name),
                        .path = try joinAbs(arena, roots.imports, entry.name, "import.json"),
                    } };
                };
                if (man) |mm| {
                    if (mm.promoted) m.promoted = true;
                    if (mm.source_repository) |sr| {
                        m.source_repository = .{
                            .repository = try arena.dupe(u8, sr.repository),
                            .skill_path = try arena.dupe(u8, sr.skill_path),
                        };
                    }
                }
            }
        }
    }

    // --- agent roots: classify each entry; create agent_only entries on demand. ---
    try scanAgent(arena, io, cwd, roots, .claude_code, &map);
    try scanAgent(arena, io, cwd, roots, .codex, &map);

    // --- build sorted skill entries ---
    var names: std.ArrayList([]const u8) = .empty;
    for (map.keys()) |k| try names.append(arena, k);
    std.mem.sort([]const u8, names.items, {}, lessThanStr);

    var skills: std.ArrayList(types.SkillEntry) = .empty;
    for (names.items) |name| {
        const m = map.get(name).?;
        try skills.append(arena, .{
            .name = m.name,
            .description = m.description,
            .source = m.source,
            .source_repository = m.source_repository,
            .promoted = m.promoted,
            .enablement = .{
                .claude_code = m.claude.enabled(),
                .codex = m.codex.enabled(),
            },
            .agent_entries = .{
                .claude_code = m.claude,
                .codex = m.codex,
            },
            .canonical_dir = m.canonical_dir,
            .imports_dir = m.imports_dir,
        });
    }

    // --- source_repositories grouping (spec "Inventory": group imported repo
    // skills by repository, sorted by (skill_name, skill_path)). ---
    const groups = try buildRepoGroups(arena, skills.items);

    return .{ .ok = .{ .skills = skills.items, .source_repositories = groups } };
}

/// Classify every entry of one agent root and merge into `map`. Skills found
/// only through an agent root become `agent_only` (spec "Terms": Agent-only).
fn scanAgent(
    arena: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    roots: Roots,
    agent: types.Agent,
    map: *std.StringArrayHashMapUnmanaged(*Merged),
) !void {
    const root_path = switch (agent) {
        .claude_code => roots.claude_code,
        .codex => roots.codex,
    };
    var dir = (try openRoot(io, cwd, root_path)) orelse return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const status = (try classifyAgentEntry(arena, io, entry, root_path, roots)) orelse continue;
        // A skill seen ONLY via an agent root is agent_only (getOrPut default);
        // storage roots already set canonical/imported, which take precedence and
        // are never downgraded here.
        const m = try getOrPut(arena, map, entry.name);
        switch (agent) {
            .claude_code => m.claude = status,
            .codex => m.codex = status,
        }
    }
}

/// Classify a single agent-root entry into an AgentEntryStatus
/// (spec "Inventory": agent_entries values). Returns null for entries that do
/// not represent a skill (e.g. a stray regular file), which are skipped.
///
/// Thin adapter over `managed_entry.classify`: the no-follow classify, broken-
/// link probe (Finding #9), and symlinked-ancestor canonicalization live in that
/// shared module; this only maps a `Classification` onto the inventory token.
fn classifyAgentEntry(
    arena: std.mem.Allocator,
    io: std.Io,
    entry: std.Io.Dir.Entry,
    root_path: []const u8,
    roots: Roots,
) !?types.AgentEntryStatus {
    const link_path = try std.fs.path.join(arena, &.{ root_path, entry.name });
    switch (try managed_entry.classify(arena, io, link_path)) {
        // Iteration only yields existing entries, so `.missing` is unreachable in
        // practice; map it to "skip" for totality.
        .missing => return null,
        .real_directory => return .skill_directory,
        // A stray regular file (or other non-skill entry) is not a managed skill
        // and has no inventory token; skip it.
        .real_file => return null,
        // An unresolvable link is broken, NOT external (Finding #9): broken has
        // enablement false; External (a resolvable link landing outside the roots)
        // has enablement true.
        .broken_symlink => return .broken_symlink,
        .symlink => |target| {
            // Membership against the roots, canonicalized with the SAME policy
            // managed_entry applied to the target, so a managed link reached
            // through a symlinked ancestor is not misreported as external_symlink
            // (spec "Inventory": canonical_symlink/imported_symlink; "Terms":
            // External entry).
            const canon = try managed_entry.canonicalize(arena, io, roots.canonical);
            const imports = try managed_entry.canonicalize(arena, io, roots.imports);
            if (managed_entry.isInside(target, canon)) return .canonical_symlink;
            if (managed_entry.isInside(target, imports)) return .imported_symlink;
            return .external_symlink;
        },
    }
}

/// Open `path` as an iterable directory. A missing root yields null (spec "list":
/// "Missing roots are treated as empty"); any other I/O error propagates so it
/// can surface as `discovery_error` rather than being silently treated as empty.
fn openRoot(io: std.Io, cwd: std.Io.Dir, path: []const u8) !?std.Io.Dir {
    return cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Read and validate `<sub>/SKILL.md`; null if no SKILL.md (not a skill dir).
/// Invalid frontmatter for a present SKILL.md returns null too (the directory is
/// simply not a recognized skill); strings are arena-duped.
fn readSkill(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub: []const u8) !?frontmatter.Metadata {
    const path = try std.fs.path.join(arena, &.{ sub, "SKILL.md" });
    const bytes = dir.readFileAlloc(io, path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return switch (frontmatter.parse(arena, bytes)) {
        .ok => |md| .{
            .name = try arena.dupe(u8, md.name),
            .description = try arena.dupe(u8, md.description),
        },
        .err => null,
    };
}

/// Read `<sub>/import.json` if present. Null if absent; error if present but
/// malformed (spec "list": malformed import.json is an error).
fn readManifest(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub: []const u8) !?types.ImportManifest {
    const path = try std.fs.path.join(arena, &.{ sub, "import.json" });
    const bytes = dir.readFileAlloc(io, path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var parsed = try manifest.parse(arena, bytes);
    defer parsed.deinit();
    // Copy out of the parse arena into the operation arena.
    return .{
        .source_type = parsed.value.source_type,
        .source_location = if (parsed.value.source_location) |s| try arena.dupe(u8, s) else null,
        .source_repository = if (parsed.value.source_repository) |sr| .{
            .repository = try arena.dupe(u8, sr.repository),
            .skill_path = try arena.dupe(u8, sr.skill_path),
        } else null,
        .imported_at = parsed.value.imported_at,
        .content_hash = try arena.dupe(u8, parsed.value.content_hash),
        .promoted = parsed.value.promoted,
    };
}

/// Get the merged accumulator for `name`, creating an `agent_only` default.
fn getOrPut(arena: std.mem.Allocator, map: *std.StringArrayHashMapUnmanaged(*Merged), name: []const u8) !*Merged {
    if (map.get(name)) |m| return m;
    const owned = try arena.dupe(u8, name);
    const m = try arena.create(Merged);
    m.* = .{ .name = owned, .source = .agent_only };
    try map.put(arena, owned, m);
    return m;
}

fn joinAbs(arena: std.mem.Allocator, a: []const u8, b: []const u8, c: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ a, b, c });
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Build `source_repositories`: group imported skills that carry repository
/// metadata by repository, each group's skills sorted by (skill_name,skill_path),
/// and groups sorted by repository (spec "Inventory").
fn buildRepoGroups(arena: std.mem.Allocator, skills: []const types.SkillEntry) ![]types.SourceRepositoryGroup {
    var repos: std.StringArrayHashMapUnmanaged(std.ArrayList(types.RepositorySkillRef)) = .empty;
    for (skills) |s| {
        const sr = s.source_repository orelse continue;
        const gop = try repos.getOrPut(arena, sr.repository);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, .{
            .skill_name = s.name,
            .skill_path = sr.skill_path,
        });
    }

    var repo_names: std.ArrayList([]const u8) = .empty;
    for (repos.keys()) |k| try repo_names.append(arena, k);
    std.mem.sort([]const u8, repo_names.items, {}, lessThanStr);

    var groups: std.ArrayList(types.SourceRepositoryGroup) = .empty;
    for (repo_names.items) |repo| {
        const refs = repos.get(repo).?;
        std.mem.sort(types.RepositorySkillRef, refs.items, {}, lessThanRef);
        try groups.append(arena, .{ .repository = repo, .skills = refs.items });
    }
    return groups.items;
}

fn lessThanRef(_: void, a: types.RepositorySkillRef, b: types.RepositorySkillRef) bool {
    const by_name = std.mem.order(u8, a.skill_name, b.skill_name);
    if (by_name != .eq) return by_name == .lt;
    return std.mem.lessThan(u8, a.skill_path, b.skill_path);
}
