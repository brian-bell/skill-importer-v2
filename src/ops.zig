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
    // the "correct" target for a canonical/promoted skill on disable.
    const canonical_target = try std.fs.path.join(c.arena, &.{ c.canonical_root, skill_name });
    const imports_target = try std.fs.path.join(c.arena, &.{ c.imports_root, skill_name });

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

    // 4. Execute (spec: only after preflight succeeds).
    var actions: std.ArrayList(types.SkillAction) = .empty;
    for (plans.items) |plan| {
        try execute(c, plan, &actions);
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
            return .{ .ok = .{ .source = s.source, .promoted = s.promoted } };
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
    const cwd = std.Io.Dir.cwd();

    // Classify the current entry without following the final symlink (spec
    // "Filesystem Safety": never dereference/replace external entries).
    const kind = try fsutil.classify(c.io, cwd, link_path);

    switch (mode) {
        .enable => switch (kind) {
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
            .symlink => {
                // Already the correct managed symlink => skip_unchanged; any other
                // symlink target (external or WRONG managed target) is unsafe and
                // is left untouched (spec "enable").
                if (try symlinkPointsAt(c, link_path, canonical_target)) {
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
            // A real directory or regular file is unsafe (spec "enable").
            .directory, .file => return unsafe(c, link_path, agent),
        },
        .disable => switch (kind) {
            // Missing entry => nothing to remove (spec "disable": skip_unchanged).
            .missing => return .{ .ok = .{
                .agent = agent,
                .kind = .skip,
                .link_path = link_path,
                .target = "",
                .needs_root = false,
            } },
            .symlink => {
                // A managed symlink for THIS skill (pointing at the canonical copy
                // or the draft import dir for a legacy-enabled unpromoted import)
                // is removed; anything else is unsafe (spec "disable").
                if (try symlinkPointsAt(c, link_path, canonical_target) or
                    try symlinkPointsAt(c, link_path, imports_target))
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
            .directory, .file => return unsafe(c, link_path, agent),
        },
    }
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

/// True iff the symlink at `link_path` resolves (lexically, through any existing
/// symlinked ancestors) to the same canonicalized path as `expected_target`.
/// Both sides are canonicalized so a managed symlink reached through a symlinked
/// ancestor (e.g. macOS /tmp -> /private/tmp) is not misclassified (mirrors the
/// discovery classifier).
fn symlinkPointsAt(c: *Context, link_path: []const u8, expected_target: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = cwd.readLink(c.io, link_path, &buf) catch return false;
    const link_dir = std.fs.path.dirname(link_path) orelse ".";
    const canon_link_dir = try canonOrLexical(c, link_dir);
    const lexical_target = try fsutil.resolveLinkTarget(c.arena, canon_link_dir, buf[0..n]);
    const actual = try canonOrLexical(c, lexical_target);
    const expected = try canonOrLexical(c, expected_target);
    return std.mem.eql(u8, actual, expected);
}

fn canonOrLexical(c: *Context, path: []const u8) ![]const u8 {
    return fsutil.canonicalizeExistingAncestor(c.arena, c.io, path) catch
        std.fs.path.resolve(c.arena, &.{path});
}

fn dup(c: *Context, s: []const u8) []const u8 {
    return c.arena.dupe(u8, s) catch s;
}
