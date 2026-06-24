//! enable / disable planner + executor (cli-clean-room-spec.md "enable",
//! "disable", "Filesystem Safety", "JSON Schemas > Skill Operation Result").
//!
//! Both commands follow the spec's plan-then-execute discipline
//! (spec "Filesystem Safety"):
//!   1. Resolve the skill across roots (discovery) and reject unknown /
//!      agent-only / (enable only) unpromoted skills.
//!   2. Deduplicate the requested agents in first-seen order (spec enable/disable).
//!   3. PREFLIGHT every requested agent's current entry. If ANY requested agent
//!      has an unsafe entry, fail before mutating ANY agent (spec: "no earlier
//!      agent may be mutated if a later requested agent has an unsafe entry").
//!   4. Execute only after preflight succeeds; record the action list.
//!
//! enable links to the CANONICAL promoted copy `<canonical>/<name>`, never the
//! draft import directory (spec "enable": "Promoted imports are enabled by
//! symlinking to the canonical promoted copy, not to the draft import directory").

const std = @import("std");
const types = @import("types.zig");
const result = @import("result.zig");
const discovery = @import("discovery.zig");
const fsutil = @import("fsutil.zig");
const managed_entry = @import("managed_entry.zig");
const frontmatter = @import("frontmatter.zig");
const manifest_mod = @import("manifest.zig");

const Result = result.Result(types.SkillOperationResult);

/// Injected dependencies for an enable/disable operation. All output strings are
/// owned by `arena`.
pub const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    canonical_root: []const u8,
    imports_root: []const u8,
    claude_code_root: []const u8,
    codex_root: []const u8,

    fn roots(self: Context) discovery.Roots {
        return .{
            .canonical = self.canonical_root,
            .imports = self.imports_root,
            .claude_code = self.claude_code_root,
            .codex = self.codex_root,
        };
    }

    fn agentRoot(self: Context, agent: types.Agent) []const u8 {
        return switch (agent) {
            .claude_code => self.claude_code_root,
            .codex => self.codex_root,
        };
    }
};

// --- public entry points ---------------------------------------------------

/// `enable` (spec): enable a canonical skill or promoted import for one or more
/// agents by creating managed symlinks to the canonical copy.
pub fn enable(c: *Context, skill_name: []const u8, agents: []const types.Agent) Result {
    return run(c, skill_name, agents, .enable);
}

/// `disable` (spec): disable a managed skill for one or more agents by removing
/// the managed symlink.
pub fn disable(c: *Context, skill_name: []const u8, agents: []const types.Agent) Result {
    return run(c, skill_name, agents, .disable);
}

const Mode = enum { enable, disable };

fn run(c: *Context, skill_name: []const u8, agents: []const types.Agent, mode: Mode) Result {
    return runImpl(c, skill_name, agents, mode) catch |err| switch (err) {
        error.OutOfMemory => .{ .err = .{ .kind = .io_error, .reason = "out of memory" } },
        else => .{ .err = .{ .kind = .io_error, .name = dup(c, skill_name), .reason = @errorName(err) } },
    };
}

fn runImpl(c: *Context, skill_name: []const u8, agents: []const types.Agent, mode: Mode) anyerror!Result {
    // 1. Resolve the skill across roots (spec enable/disable: unknown/agent-only).
    const entry = switch (resolve(c, skill_name)) {
        .ok => |e| e,
        .err => |e| return .{ .err = e },
    };

    switch (entry.source) {
        .agent_only => return .{ .err = .{ .kind = .agent_only_skill, .name = dup(c, skill_name) } },
        .imported => if (mode == .enable and !entry.promoted) {
            // enable rejects unpromoted imports (spec "enable": "Unpromoted
            // imports fail."). disable allows legacy enabled unpromoted imports
            // (spec "disable").
            return .{ .err = .{ .kind = .not_promoted, .name = dup(c, skill_name) } };
        },
        .canonical => {},
    }

    // 2. Deduplicate agents in first-seen order (spec enable/disable).
    const deduped = try dedupeAgents(c.arena, agents);

    // The canonical promoted copy is the managed symlink target for enable, and
    // the "correct" target for a canonical/promoted skill on disable. Resolve the
    // path from the ON-DISK directory name, which may differ from the frontmatter
    // skill name (Finding #7); fall back to the skill name when the skill is not
    // present in that root.
    const canonical_target = try std.fs.path.join(c.arena, &.{ c.canonical_root, entry.canonical_dir orelse skill_name });
    const imports_target = try std.fs.path.join(c.arena, &.{ c.imports_root, entry.imports_dir orelse skill_name });

    // 3. PREFLIGHT every requested agent (spec "Filesystem Safety": preflight all
    // before mutating any). A single unsafe entry fails the whole operation,
    // untouched.
    var plans: std.ArrayList(AgentPlan) = .empty;
    for (deduped) |agent| {
        const plan = switch (try preflight(c, skill_name, agent, mode, canonical_target, imports_target)) {
            .ok => |p| p,
            .err => |e| return .{ .err = e },
        };
        try plans.append(c.arena, plan);
    }

    // 4. Execute (spec: only after preflight succeeds). On an execute-phase I/O
    //    error, surface the actions that completed before the failure (spec
    //    "Filesystem Safety": report the completed actions; Findings #10/#12),
    //    mirroring promote/unpromote/delete.
    var actions: std.ArrayList(types.SkillAction) = .empty;
    for (plans.items) |plan| {
        execute(c, plan, &actions) catch |err| {
            return executeError(c, skill_name, err, &actions);
        };
    }

    return .{ .ok = .{
        .skill_name = dup(c, skill_name),
        .actions = try actions.toOwnedSlice(c.arena),
    } };
}

// --- skill resolution ------------------------------------------------------

const Resolved = struct {
    source: types.SkillSource,
    promoted: bool,
    /// On-disk dir name in the canonical / imports root (Finding #7); may differ
    /// from `skill_name`. Null when the skill is not present in that root.
    canonical_dir: ?[]const u8,
    imports_dir: ?[]const u8,
};

/// Resolve a skill by name via discovery (spec enable/disable: a skill must be
/// known in canonical/imports/agent storage). Unknown => error.
fn resolve(c: *Context, skill_name: []const u8) result.Result(Resolved) {
    const inv = switch (discovery.discover(c.arena, c.io, c.roots())) {
        .ok => |i| i,
        .err => |e| return .{ .err = e },
    };
    for (inv.skills) |s| {
        if (std.mem.eql(u8, s.name, skill_name)) {
            return .{ .ok = .{
                .source = s.source,
                .promoted = s.promoted,
                .canonical_dir = s.canonical_dir,
                .imports_dir = s.imports_dir,
            } };
        }
    }
    return .{ .err = .{ .kind = .unknown_skill, .name = dup(c, skill_name) } };
}

// --- per-agent planning ----------------------------------------------------

const PlanKind = enum { create, skip, remove };

const AgentPlan = struct {
    agent: types.Agent,
    kind: PlanKind,
    /// Absolute path of the agent entry `<agent_root>/<skill_name>`.
    link_path: []const u8,
    /// Symlink target for create plans (the canonical copy).
    target: []const u8,
    /// Whether the agent root must be created before the symlink (spec "enable":
    /// "create the agent root if needed").
    needs_root: bool,
};

/// Preflight one agent's entry against the requested mode (spec enable/disable
/// behavior + "Filesystem Safety"). Returns the action plan for that agent or a
/// classified error for an unsafe entry, WITHOUT mutating anything.
fn preflight(
    c: *Context,
    skill_name: []const u8,
    agent: types.Agent,
    mode: Mode,
    canonical_target: []const u8,
    imports_target: []const u8,
) anyerror!result.Result(AgentPlan) {
    const agent_root = c.agentRoot(agent);
    const link_path = try std.fs.path.join(c.arena, &.{ agent_root, skill_name });

    // Classify the current entry against the managed roots (shared classifier:
    // no-follow classify + broken-link probe + symlinked-ancestor canonicalize;
    // spec "Filesystem Safety": never dereference/replace external entries).
    const cls = try managed_entry.classify(c.arena, c.io, link_path);

    switch (mode) {
        .enable => {
            // Preflight the LINK TARGET: the canonical promoted copy we are about
            // to point at must exist as a real directory. A promoted import whose
            // canonical copy was deleted out-of-band still reports promoted=true
            // from its draft manifest (discovery), so it passes the not_promoted
            // check above — but linking to the missing `<canonical>/<name>` would
            // create a DANGLING symlink reported as a successful create
            // (Finding #4). Refuse instead, leaving the agent entry untouched, so
            // the operator can repair (e.g. re-promote) the canonical copy.
            if (!try targetIsDirectory(c, canonical_target)) {
                return .{ .err = .{
                    .kind = .unsupported_entry,
                    .name = dup(c, skill_name),
                    .path = dup(c, canonical_target),
                    .reason = "canonical promoted copy is missing or not a directory; re-promote the skill",
                } };
            }
            return enablePlan(c, skill_name, agent, cls, canonical_target);
        },
        .disable => switch (cls) {
            // Missing entry => nothing to remove (spec "disable": skip_unchanged).
            .missing => return .{ .ok = .{
                .agent = agent,
                .kind = .skip,
                .link_path = link_path,
                .target = "",
                .needs_root = false,
            } },
            // A BROKEN symlink (target does not resolve) is an unsafe External
            // entry and must be left untouched, NOT removed (spec "disable":
            // "Unsafe entries are rejected and left untouched"; spec "Terms": a
            // broken symlink is an External entry). The classifier reports it as
            // `.broken_symlink` BEFORE any pointing-at test, so a dangling managed
            // link that still matches a target lexically is not removed
            // (Finding #8).
            .broken_symlink => return unsafe(c, link_path, agent),
            .symlink => |target| {
                // A managed symlink for THIS skill (pointing at the canonical copy
                // or the draft import dir for a legacy-enabled unpromoted import)
                // is removed; anything else is unsafe (spec "disable"). The
                // classifier already canonicalized `target`, so compare against the
                // canonicalized expected targets.
                const canon_canonical = try managed_entry.canonicalize(c.arena, c.io, canonical_target);
                const canon_imports = try managed_entry.canonicalize(c.arena, c.io, imports_target);
                if (std.mem.eql(u8, target, canon_canonical) or
                    std.mem.eql(u8, target, canon_imports))
                {
                    return .{ .ok = .{
                        .agent = agent,
                        .kind = .remove,
                        .link_path = link_path,
                        .target = "",
                        .needs_root = false,
                    } };
                }
                return unsafe(c, link_path, agent);
            },
            .real_directory, .real_file => return unsafe(c, link_path, agent),
        },
    }
}

/// Build the enable action plan for one agent entry, given the entry kind and the
/// validated canonical link target (spec "enable").
fn enablePlan(
    c: *Context,
    skill_name: []const u8,
    agent: types.Agent,
    cls: managed_entry.Classification,
    canonical_target: []const u8,
) anyerror!result.Result(AgentPlan) {
    const agent_root = c.agentRoot(agent);
    const link_path = try std.fs.path.join(c.arena, &.{ agent_root, skill_name });
    switch (cls) {
        .missing => {
            const needs_root = !rootExists(c, agent_root);
            return .{ .ok = .{
                .agent = agent,
                .kind = .create,
                .link_path = link_path,
                .target = canonical_target,
                .needs_root = needs_root,
            } };
        },
        .symlink => |target| {
            // Already the correct managed symlink => skip_unchanged; any other
            // symlink target (external or WRONG managed target) is unsafe and
            // is left untouched (spec "enable"). The classifier already
            // canonicalized `target`; compare against the canonicalized target.
            const canon_canonical = try managed_entry.canonicalize(c.arena, c.io, canonical_target);
            if (std.mem.eql(u8, target, canon_canonical)) {
                return .{ .ok = .{
                    .agent = agent,
                    .kind = .skip,
                    .link_path = link_path,
                    .target = canonical_target,
                    .needs_root = false,
                } };
            }
            return unsafe(c, link_path, agent);
        },
        // A real directory, regular file, or broken symlink is unsafe
        // (spec "enable"; the canonical link target was already proven to exist,
        // so a managed link to it cannot be broken — a broken link points
        // elsewhere and is left untouched).
        .real_directory, .real_file, .broken_symlink => return unsafe(c, link_path, agent),
    }
}

/// True iff `path` resolves (following symlinks) to a real directory. Used to
/// preflight the enable link target so a missing/file canonical promoted copy
/// fails instead of producing a dangling managed symlink (Finding #4).
fn targetIsDirectory(c: *Context, path: []const u8) !bool {
    const st = std.Io.Dir.cwd().statFile(c.io, path, .{ .follow_symlinks = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    return st.kind == .directory;
}

fn unsafe(c: *Context, link_path: []const u8, agent: types.Agent) result.Result(AgentPlan) {
    _ = agent;
    return .{ .err = .{ .kind = .unsafe_agent_entry, .path = dup(c, link_path) } };
}

// --- execution -------------------------------------------------------------

/// Execute a single agent plan, appending the resulting action(s). The executor
/// records `create_directory` BEFORE `create_symlink` (spec "Skill Operation
/// Result" action order; zig-clean-room-cli.md Phase 5a).
fn execute(c: *Context, plan: AgentPlan, actions: *std.ArrayList(types.SkillAction)) anyerror!void {
    const cwd = std.Io.Dir.cwd();
    switch (plan.kind) {
        .create => {
            if (plan.needs_root) {
                const agent_root = c.agentRoot(plan.agent);
                try cwd.createDirPath(c.io, agent_root);
                try actions.append(c.arena, .{
                    .action = .create_directory,
                    .agent = plan.agent,
                    .path = try c.arena.dupe(u8, agent_root),
                });
            }
            try cwd.symLink(c.io, plan.target, plan.link_path, .{});
            try actions.append(c.arena, .{
                .action = .create_symlink,
                .agent = plan.agent,
                .path = plan.link_path,
                .target = plan.target,
            });
        },
        .remove => {
            try cwd.deleteFile(c.io, plan.link_path);
            try actions.append(c.arena, .{
                .action = .remove_symlink,
                .agent = plan.agent,
                .path = plan.link_path,
            });
        },
        .skip => {
            // skip_unchanged (spec "Skill Operation Result"). For an enable skip,
            // the target is the agent entry's symlink target; for a disable skip
            // (missing entry) no target.
            try actions.append(c.arena, .{
                .action = .skip_unchanged,
                .agent = plan.agent,
                .path = plan.link_path,
                .target = if (plan.target.len == 0) null else plan.target,
            });
        },
    }
}

// --- helpers ---------------------------------------------------------------

/// Deduplicate agents preserving first-seen order (spec enable/disable: "Agent
/// requests are deduplicated in first-seen order").
fn dedupeAgents(arena: std.mem.Allocator, agents: []const types.Agent) ![]const types.Agent {
    var out: std.ArrayList(types.Agent) = .empty;
    for (agents) |a| {
        var seen = false;
        for (out.items) |b| {
            if (a == b) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(arena, a);
    }
    return out.toOwnedSlice(arena);
}

/// True iff `path` exists (as anything, no-follow) — used to decide whether the
/// agent root needs creating.
fn rootExists(c: *Context, path: []const u8) bool {
    const kind = fsutil.classify(c.io, std.Io.Dir.cwd(), path) catch return false;
    return kind != .missing;
}

fn dup(c: *Context, s: []const u8) []const u8 {
    return c.arena.dupe(u8, s) catch s;
}

// ===========================================================================
// promote / unpromote / delete (cli-clean-room-spec.md "promote", "unpromote",
// "delete", "Collision Rules", "Filesystem Safety").
//
// All three follow the spec's plan-then-execute discipline: resolve + classify
// the skill, preflight every destination/agent entry for safety, then execute
// only after preflight succeeds and record an action list.
// ===========================================================================

/// Resolve the FULL inventory entry for a skill (not just source/promoted) so
/// promote/unpromote/delete can inspect agent entries (e.g. a legacy managed
/// import symlink for delete) and the imported source_repository.
fn resolveEntry(c: *Context, skill_name: []const u8) result.Result(types.SkillEntry) {
    const inv = switch (discovery.discover(c.arena, c.io, c.roots())) {
        .ok => |i| i,
        .err => |e| return .{ .err = e },
    };
    for (inv.skills) |s| {
        if (std.mem.eql(u8, s.name, skill_name)) return .{ .ok = s };
    }
    return .{ .err = .{ .kind = .unknown_skill, .name = dup(c, skill_name) } };
}

fn opRun(
    c: *Context,
    skill_name: []const u8,
    comptime impl: fn (*Context, []const u8) anyerror!Result,
) Result {
    return impl(c, skill_name) catch |err| switch (err) {
        error.OutOfMemory => .{ .err = .{ .kind = .io_error, .reason = "out of memory" } },
        else => .{ .err = .{ .kind = .io_error, .name = dup(c, skill_name), .reason = @errorName(err) } },
    };
}

/// Build an `io_error` result for an execute-phase failure, carrying the actions
/// that completed BEFORE the failure in `partial_actions` (spec "Filesystem
/// Safety": "Partially completed operations caused by unexpected I/O errors
/// should report the actions that completed before the failure"). The accumulated
/// `actions` list (arena-backed) is moved into the error payload.
fn executeError(
    c: *Context,
    skill_name: []const u8,
    err: anyerror,
    actions: *std.ArrayList(types.SkillAction),
) Result {
    if (err == error.OutOfMemory) {
        return .{ .err = .{ .kind = .io_error, .name = dup(c, skill_name), .reason = "out of memory" } };
    }
    return .{ .err = .{
        .kind = .io_error,
        .name = dup(c, skill_name),
        .reason = @errorName(err),
        .partial_actions = actions.*,
    } };
}

// --- promote ---------------------------------------------------------------

/// `promote` (spec): copy an imported draft skill from the imports root into the
/// canonical root and mark the draft manifest promoted=true. With `overwrite`,
/// an existing matching-name canonical destination is replaced via stage-then-
/// swap so the old copy survives until the replacement is ready.
pub fn promote(c: *Context, skill_name: []const u8, overwrite: bool) Result {
    return promoteRun(c, skill_name, overwrite) catch |err| switch (err) {
        error.OutOfMemory => .{ .err = .{ .kind = .io_error, .reason = "out of memory" } },
        else => .{ .err = .{ .kind = .io_error, .name = dup(c, skill_name), .reason = @errorName(err) } },
    };
}

fn promoteRun(c: *Context, skill_name: []const u8, overwrite: bool) anyerror!Result {
    const cwd = std.Io.Dir.cwd();

    // 1. Resolve + classify (spec promote: unknown/canonical/agent-only/already-
    //    promoted fail).
    const entry = switch (resolveEntry(c, skill_name)) {
        .ok => |e| e,
        .err => |e| return .{ .err = e },
    };
    switch (entry.source) {
        .canonical => return .{ .err = .{ .kind = .canonical_only_skill, .name = dup(c, skill_name) } },
        .agent_only => return .{ .err = .{ .kind = .agent_only_skill, .name = dup(c, skill_name) } },
        .imported => if (entry.promoted) {
            return .{ .err = .{ .kind = .already_promoted, .name = dup(c, skill_name) } };
        },
    }

    // The import source is the REAL on-disk directory (may differ from the
    // frontmatter skill name, Finding #7); the canonical destination is keyed by
    // skill name (spec promote: copied to `<canonical>/<skill-name>`).
    const import_dir = try std.fs.path.join(c.arena, &.{ c.imports_root, entry.imports_dir orelse skill_name });
    const dest_dir = try std.fs.path.join(c.arena, &.{ c.canonical_root, skill_name });

    // 2a. Existing canonical destination: fail without --overwrite (spec promote +
    //     "Collision Rules"). With --overwrite, an existing dest whose SKILL.md
    //     frontmatter name differs still fails (spec promote).
    const dest_exists = (try fsutil.classify(c.io, cwd, dest_dir)) != .missing;
    if (dest_exists) {
        if (!overwrite) {
            return .{ .err = .{ .kind = .canonical_collision, .name = dup(c, skill_name), .path = dest_dir } };
        }
        const dest_name = try frontmatterNameOf(c, dest_dir);
        if (dest_name == null or !std.mem.eql(u8, dest_name.?, skill_name)) {
            return .{ .err = .{ .kind = .canonical_collision, .name = dup(c, skill_name), .path = dest_dir } };
        }
    }

    // 2b. Frontmatter-name collision ANYWHERE else in canonical (spec "Collision
    //     Rules": refuse frontmatter name collisions anywhere in canonical,
    //     including a colliding dir with a different directory name). The dest dir
    //     itself (same name) is excluded — that is the overwrite target.
    switch (try frontmatterCollisionElsewhere(c, skill_name)) {
        .ok => {},
        .err => |e| return .{ .err = e },
    }

    // 2c. Unsupported entries (symlinks etc.) inside the import dir must fail
    //     (spec promote). Detected up front by scanning the tree.
    if (try treeHasUnsupportedEntry(c, import_dir)) {
        return .{ .err = .{
            .kind = .unsupported_entry,
            .name = dup(c, skill_name),
            .path = dup(c, import_dir),
            .reason = "import directory contains a symlink or unsupported entry",
        } };
    }

    // 2d. Preflight agent entries for this skill: any unsafe entry (real dir/file/
    //     broken/external/wrong-target symlink) fails BEFORE mutation (spec
    //     promote). Managed symlinks pointing at the import dir are relink targets.
    const dest_canon = try managed_entry.canonicalize(c.arena, c.io, dest_dir);
    const import_canon = try managed_entry.canonicalize(c.arena, c.io, import_dir);
    var relinks: std.ArrayList(types.Agent) = .empty;
    for ([_]types.Agent{ .claude_code, .codex }) |agent| {
        switch (try preflightPromoteAgent(c, skill_name, agent, dest_canon, import_canon)) {
            .ok => |needs_relink| if (needs_relink) try relinks.append(c.arena, agent),
            .err => |e| return .{ .err = e },
        }
    }

    // 3. Execute. On an execute-phase I/O error, surface the actions that
    //    completed before the failure (spec "Filesystem Safety": report the
    //    completed actions).
    var actions: std.ArrayList(types.SkillAction) = .empty;
    executePromote(c, skill_name, import_dir, dest_dir, dest_exists, relinks.items, &actions) catch |err| {
        return executeError(c, skill_name, err, &actions);
    };

    return .{ .ok = .{
        .skill_name = dup(c, skill_name),
        .actions = try actions.toOwnedSlice(c.arena),
    } };
}

/// Execute phase of promote: stage-then-swap the canonical copy, relink managed
/// import symlinks, and flip the draft manifest. Appends an action per completed
/// step into `actions` so a mid-flight failure can report the partial progress.
fn executePromote(
    c: *Context,
    skill_name: []const u8,
    import_dir: []const u8,
    dest_dir: []const u8,
    dest_exists: bool,
    relinks: []const types.Agent,
    actions: *std.ArrayList(types.SkillAction),
) anyerror!void {
    const cwd = std.Io.Dir.cwd();

    // Stage the new copy in a sibling staging dir on the same mount, then swap
    // (spec promote: "the existing canonical copy must not be removed until the
    // replacement copy is known to be valid and ready").
    const canonical_created = (try fsutil.classify(c.io, cwd, c.canonical_root)) == .missing;
    try cwd.createDirPath(c.io, c.canonical_root);
    if (canonical_created) {
        try actions.append(c.arena, .{ .action = .create_directory, .path = dup(c, c.canonical_root) });
    }

    const staging_dir = try std.fs.path.join(c.arena, &.{ c.canonical_root, try std.fmt.allocPrint(c.arena, ".{s}.staging", .{skill_name}) });
    // Clean any leftover staging from a previous interrupted run.
    cwd.deleteTree(c.io, staging_dir) catch {};
    try cwd.createDirPath(c.io, staging_dir);
    {
        var src = try cwd.openDir(c.io, import_dir, .{ .iterate = true });
        defer src.close(c.io);
        var dst = try cwd.openDir(c.io, staging_dir, .{});
        defer dst.close(c.io);
        // Record copy_file action paths against the FINAL destination
        // (<canonical>/<name>/...), not the transient staging dir — after the
        // swap the staging path no longer exists (spec promote / Skill Operation
        // Result copy_file 'path' / Filesystem Safety step 5).
        copyExcludingManifest(c, src, dst, dest_dir, "", actions) catch |err| {
            cwd.deleteTree(c.io, staging_dir) catch {};
            return err;
        };
    }

    // Swap: move any existing dest aside, move staging into place, drop the old.
    if (dest_exists) {
        const backup_dir = try std.fs.path.join(c.arena, &.{ c.canonical_root, try std.fmt.allocPrint(c.arena, ".{s}.old", .{skill_name}) });
        cwd.deleteTree(c.io, backup_dir) catch {};
        try cwd.rename(dest_dir, cwd, backup_dir, c.io);
        cwd.rename(staging_dir, cwd, dest_dir, c.io) catch |err| {
            // Restore the original on swap failure (replacement not ready).
            cwd.rename(backup_dir, cwd, dest_dir, c.io) catch {};
            cwd.deleteTree(c.io, staging_dir) catch {};
            return err;
        };
        cwd.deleteTree(c.io, backup_dir) catch {};
    } else {
        try cwd.rename(staging_dir, cwd, dest_dir, c.io);
    }

    // Relink managed import symlinks to the canonical copy (spec promote).
    for (relinks) |agent| {
        const link_path = try std.fs.path.join(c.arena, &.{ c.agentRoot(agent), skill_name });
        try cwd.deleteFile(c.io, link_path);
        try actions.append(c.arena, .{ .action = .remove_symlink, .agent = agent, .path = dup(c, link_path) });
        try cwd.symLink(c.io, dest_dir, link_path, .{});
        try actions.append(c.arena, .{ .action = .create_symlink, .agent = agent, .path = dup(c, link_path), .target = dest_dir });
    }

    // Set the draft manifest promoted=true (spec promote).
    try setManifestPromoted(c, import_dir, true, actions);
}

/// Preflight one agent entry for promote. Returns ok(true) when the entry is a
/// managed symlink pointing at the import dir (=> relink target), ok(false) when
/// the entry is missing or already points at the canonical copy (nothing to do),
/// or an unsafe-entry error otherwise (spec promote: unsafe agent entries fail
/// before mutation).
fn preflightPromoteAgent(
    c: *Context,
    skill_name: []const u8,
    agent: types.Agent,
    dest_canon: []const u8,
    import_canon: []const u8,
) anyerror!result.Result(bool) {
    const link_path = try std.fs.path.join(c.arena, &.{ c.agentRoot(agent), skill_name });
    switch (try managed_entry.classify(c.arena, c.io, link_path)) {
        .missing => return .{ .ok = false },
        // A real dir/file or a broken (unresolvable) symlink is unsafe and fails
        // before mutation (spec promote). A broken managed link is left untouched.
        .real_directory, .real_file, .broken_symlink => return .{ .err = .{ .kind = .unsafe_agent_entry, .path = dup(c, link_path) } },
        .symlink => |target| {
            // The classifier already canonicalized `target`; the caller pre-
            // canonicalized both expected targets, so compare with plain equality.
            if (std.mem.eql(u8, target, import_canon)) return .{ .ok = true };
            if (std.mem.eql(u8, target, dest_canon)) return .{ .ok = false };
            return .{ .err = .{ .kind = .unsafe_agent_entry, .path = dup(c, link_path) } };
        },
    }
}

// --- unpromote -------------------------------------------------------------

/// `unpromote` (spec): remove the canonical promoted copy of an imported skill,
/// remove managed agent symlinks to that copy, and mark the draft manifest
/// promoted=false.
pub fn unpromote(c: *Context, skill_name: []const u8) Result {
    return opRun(c, skill_name, unpromoteRun);
}

fn unpromoteRun(c: *Context, skill_name: []const u8) anyerror!Result {
    const entry = switch (resolveEntry(c, skill_name)) {
        .ok => |e| e,
        .err => |e| return .{ .err = e },
    };
    switch (entry.source) {
        .canonical => return .{ .err = .{ .kind = .canonical_only_skill, .name = dup(c, skill_name) } },
        .agent_only => return .{ .err = .{ .kind = .agent_only_skill, .name = dup(c, skill_name) } },
        .imported => if (!entry.promoted) {
            return .{ .err = .{ .kind = .not_promoted, .name = dup(c, skill_name) } };
        },
    }

    // The import source (manifest to flip) and the canonical copy to remove are
    // resolved from the REAL on-disk directory names, which may differ from the
    // frontmatter skill name (Finding #7).
    const import_dir = try std.fs.path.join(c.arena, &.{ c.imports_root, entry.imports_dir orelse skill_name });
    const dest_dir = try std.fs.path.join(c.arena, &.{ c.canonical_root, entry.canonical_dir orelse skill_name });

    // Execute; on an execute-phase I/O error report the completed actions (spec
    // "Filesystem Safety").
    var actions: std.ArrayList(types.SkillAction) = .empty;
    executeUnpromote(c, skill_name, import_dir, dest_dir, &actions) catch |err| {
        return executeError(c, skill_name, err, &actions);
    };

    return .{ .ok = .{
        .skill_name = dup(c, skill_name),
        .actions = try actions.toOwnedSlice(c.arena),
    } };
}

/// Execute phase of unpromote: remove managed agent symlinks to the canonical
/// copy, remove the canonical copy, and flip the draft manifest. Appends an
/// action per completed step for partial-failure reporting.
fn executeUnpromote(
    c: *Context,
    skill_name: []const u8,
    import_dir: []const u8,
    dest_dir: []const u8,
    actions: *std.ArrayList(types.SkillAction),
) anyerror!void {
    const cwd = std.Io.Dir.cwd();
    const dest_canon = try managed_entry.canonicalize(c.arena, c.io, dest_dir);

    // Remove managed agent symlinks pointing at the canonical copy (spec
    // unpromote). Any OTHER agent entry (external/broken/real) is left untouched
    // (spec "Filesystem Safety"). The canonical copy still exists at this point,
    // so a managed link to it resolves; the classifier reports it as `.symlink`
    // with `target` canonicalized for direct comparison.
    for ([_]types.Agent{ .claude_code, .codex }) |agent| {
        const link_path = try std.fs.path.join(c.arena, &.{ c.agentRoot(agent), skill_name });
        switch (try managed_entry.classify(c.arena, c.io, link_path)) {
            .symlink => |target| if (std.mem.eql(u8, target, dest_canon)) {
                try cwd.deleteFile(c.io, link_path);
                try actions.append(c.arena, .{ .action = .remove_symlink, .agent = agent, .path = dup(c, link_path) });
            },
            else => {},
        }
    }

    // Remove the canonical copy (spec unpromote).
    if ((try fsutil.classify(c.io, cwd, dest_dir)) != .missing) {
        try cwd.deleteTree(c.io, dest_dir);
        try actions.append(c.arena, .{ .action = .remove_directory, .path = dest_dir });
    }

    // Mark the draft manifest promoted=false (spec unpromote).
    try setManifestPromoted(c, import_dir, false, actions);
}

// --- delete ----------------------------------------------------------------

/// `delete` (spec): delete an unpromoted imported draft skill. Promoted imports
/// fail (unpromote first); legacy-enabled imports fail (disable first); unrelated
/// same-name agent entries do not block and are left untouched.
pub fn delete(c: *Context, skill_name: []const u8) Result {
    return opRun(c, skill_name, deleteRun);
}

fn deleteRun(c: *Context, skill_name: []const u8) anyerror!Result {
    const entry = switch (resolveEntry(c, skill_name)) {
        .ok => |e| e,
        .err => |e| return .{ .err = e },
    };
    switch (entry.source) {
        .canonical => return .{ .err = .{ .kind = .canonical_only_skill, .name = dup(c, skill_name) } },
        .agent_only => return .{ .err = .{ .kind = .agent_only_skill, .name = dup(c, skill_name) } },
        .imported => if (entry.promoted) {
            // Promoted imports must be unpromoted first (spec delete).
            return .{ .err = .{ .kind = .already_promoted, .name = dup(c, skill_name) } };
        },
    }

    // Legacy-enabled: a managed symlink to the IMPORT dir in any agent root blocks
    // deletion (spec delete: "Imports enabled through legacy managed import
    // symlinks fail; disable first"). Note this is the imported_symlink status,
    // distinct from an unrelated same-name unsafe entry (real dir / external /
    // broken symlink), which does NOT block and is left untouched.
    if (entry.agent_entries.claude_code == .imported_symlink or
        entry.agent_entries.codex == .imported_symlink)
    {
        return .{ .err = .{ .kind = .enabled_import, .name = dup(c, skill_name) } };
    }

    // The draft to delete is the REAL on-disk directory, which may differ from
    // the frontmatter skill name (Finding #7).
    const import_dir = try std.fs.path.join(c.arena, &.{ c.imports_root, entry.imports_dir orelse skill_name });

    // Execute; on an execute-phase I/O error report whatever completed (spec
    // "Filesystem Safety"). The single remove_directory action is appended only
    // after it succeeds, so a failed deleteTree reports no partial action.
    var actions: std.ArrayList(types.SkillAction) = .empty;
    executeDelete(c, import_dir, &actions) catch |err| {
        return executeError(c, skill_name, err, &actions);
    };

    return .{ .ok = .{
        .skill_name = dup(c, skill_name),
        .actions = try actions.toOwnedSlice(c.arena),
    } };
}

/// Execute phase of delete: remove the imports-root draft directory.
fn executeDelete(c: *Context, import_dir: []const u8, actions: *std.ArrayList(types.SkillAction)) anyerror!void {
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(c.io, import_dir);
    try actions.append(c.arena, .{ .action = .remove_directory, .path = import_dir });
}

// --- promote/unpromote/delete helpers --------------------------------------

/// Read the SKILL.md frontmatter `name` of an existing canonical directory, or
/// null if absent / invalid.
fn frontmatterNameOf(c: *Context, dir_path: []const u8) !?[]const u8 {
    const skill_path = try std.fs.path.join(c.arena, &.{ dir_path, "SKILL.md" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, skill_path, c.arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return switch (frontmatter.parse(c.arena, bytes)) {
        .ok => |m| try c.arena.dupe(u8, m.name),
        .err => null,
    };
}

/// Refuse a frontmatter-name collision anywhere ELSE in the canonical root: a
/// canonical directory (with a DIFFERENT directory name than `skill_name`) whose
/// SKILL.md frontmatter name equals `skill_name` (spec "Collision Rules"). The
/// same-name directory is the overwrite target and is excluded here.
fn frontmatterCollisionElsewhere(c: *Context, skill_name: []const u8) anyerror!result.Result(void) {
    var dir = std.Io.Dir.cwd().openDir(c.io, c.canonical_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .ok = {} },
        else => return err,
    };
    defer dir.close(c.io);

    // The promote stage-then-swap uses reserved sibling temp directories
    // `.<name>.staging` / `.<name>.old` (executePromote). A crash-interrupted run
    // can leave a `.<name>.staging` dir behind containing a valid SKILL.md whose
    // frontmatter name == `skill_name`. That reserved path is the operation's OWN
    // transient directory, not a colliding canonical skill, so it must be excluded
    // from the collision scan (Finding #11) — otherwise the leftover would raise a
    // false frontmatter_name_collision and permanently block re-promotion. Genuine
    // collisions (any other directory) are still detected.
    const staging_name = try std.fmt.allocPrint(c.arena, ".{s}.staging", .{skill_name});
    const backup_name = try std.fmt.allocPrint(c.arena, ".{s}.old", .{skill_name});

    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, skill_name)) continue; // overwrite target
        // Reserved promote temporaries for THIS skill: ignore (Finding #11). The
        // execute phase cleans any stale staging dir before re-staging.
        if (std.mem.eql(u8, entry.name, staging_name) or
            std.mem.eql(u8, entry.name, backup_name)) continue;
        const sub_dir = try std.fs.path.join(c.arena, &.{ c.canonical_root, entry.name });
        const existing = (try frontmatterNameOf(c, sub_dir)) orelse continue;
        if (std.mem.eql(u8, existing, skill_name)) {
            return .{ .err = .{
                .kind = .frontmatter_name_collision,
                .name = dup(c, skill_name),
                .path = sub_dir,
            } };
        }
    }
    return .{ .ok = {} };
}

/// True iff the tree rooted at `dir_path` contains any entry that is neither a
/// regular file nor a directory (e.g. a symlink) — an unsupported entry for the
/// promotion copy (spec promote).
fn treeHasUnsupportedEntry(c: *Context, dir_path: []const u8) anyerror!bool {
    var dir = try std.Io.Dir.cwd().openDir(c.io, dir_path, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        switch (entry.kind) {
            .file => {},
            .directory => {
                const sub = try std.fs.path.join(c.arena, &.{ dir_path, entry.name });
                if (try treeHasUnsupportedEntry(c, sub)) return true;
            },
            else => return true,
        }
    }
    return false;
}

/// Recursively copy `src` into `dst`, EXCLUDING a top-level `import.json` (spec
/// promote: "Promotion ... excludes top-level import.json"). Records a copy_file
/// action per regular file. `rel` is the path under the destination root used to
/// build absolute action paths; only the top level excludes import.json.
fn copyExcludingManifest(
    c: *Context,
    src: std.Io.Dir,
    dst: std.Io.Dir,
    dest_root: []const u8,
    rel: []const u8,
    actions: *std.ArrayList(types.SkillAction),
) anyerror!void {
    const at_top = rel.len == 0;
    var it = src.iterate();
    while (try it.next(c.io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (at_top and std.mem.eql(u8, entry.name, "import.json")) continue;
                try src.copyFile(entry.name, dst, entry.name, c.io, .{});
                const abs = try joinAbsRel(c, dest_root, rel, entry.name);
                try actions.append(c.arena, .{ .action = .copy_file, .path = abs });
            },
            .directory => {
                try dst.createDirPath(c.io, entry.name);
                var sub_src = try src.openDir(c.io, entry.name, .{ .iterate = true });
                defer sub_src.close(c.io);
                var sub_dst = try dst.openDir(c.io, entry.name, .{});
                defer sub_dst.close(c.io);
                const sub_rel = if (rel.len == 0) entry.name else try std.fs.path.join(c.arena, &.{ rel, entry.name });
                try copyExcludingManifest(c, sub_src, sub_dst, dest_root, sub_rel, actions);
            },
            else => return error.UnsupportedEntry,
        }
    }
}

fn joinAbsRel(c: *Context, base: []const u8, rel: []const u8, name: []const u8) ![]const u8 {
    if (rel.len == 0) return std.fs.path.join(c.arena, &.{ base, name });
    return std.fs.path.join(c.arena, &.{ base, rel, name });
}

/// Read the draft manifest, set its `promoted` flag, and rewrite import.json
/// (2-space indent, no trailing newline). Records a write_manifest action.
fn setManifestPromoted(
    c: *Context,
    import_dir: []const u8,
    promoted: bool,
    actions: *std.ArrayList(types.SkillAction),
) anyerror!void {
    const manifest_path = try std.fs.path.join(c.arena, &.{ import_dir, "import.json" });
    const cwd = std.Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(c.io, manifest_path, c.arena, .unlimited) catch |err| switch (err) {
        // No manifest to update (a draft may predate import.json); nothing to do.
        error.FileNotFound => return,
        else => return err,
    };
    var parsed = try manifest_mod.parse(c.arena, bytes);
    defer parsed.deinit();
    const m: types.ImportManifest = .{
        .source_type = parsed.value.source_type,
        .source_location = if (parsed.value.source_location) |s| try c.arena.dupe(u8, s) else null,
        .source_repository = if (parsed.value.source_repository) |sr| .{
            .repository = try c.arena.dupe(u8, sr.repository),
            .skill_path = try c.arena.dupe(u8, sr.skill_path),
        } else null,
        .imported_at = parsed.value.imported_at,
        .content_hash = try c.arena.dupe(u8, parsed.value.content_hash),
        .promoted = promoted,
    };
    const out = try manifest_mod.toBytes(c.arena, m);
    try cwd.writeFile(c.io, .{ .sub_path = manifest_path, .data = out });
    try actions.append(c.arena, .{ .action = .write_manifest, .path = dup(c, manifest_path) });
}
