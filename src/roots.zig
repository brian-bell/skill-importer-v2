//! Root resolution (cli-clean-room-spec.md "Root Resolution").
//!
//! Each of the four roots (canonical, imports, claude_code, codex) is resolved
//! INDEPENDENTLY: an explicit `--*-root` override is used verbatim; otherwise a
//! per-root default is computed. `HOME` is consulted ONLY when a surviving
//! default needs it, so "all roots explicit" never requires `HOME`
//! (spec: "Explicitly providing all roots must not require HOME").
//!
//! Defaults (spec "Root Resolution"):
//!   canonical    = <agent-skills-repo>/third-party
//!                  agent-skills-repo = $AGENT_SKILLS_REPO, else $HOME/dev/agent-skills
//!   imports      = <runtime-root>/.skill-importer/imports
//!                  runtime-root = nearest ancestor of cwd containing BOTH
//!                  `AGENTS.md` and `catalog/portable/`, else cwd
//!   claude_code  = $HOME/.claude/skills
//!   codex        = $HOME/.agents/skills
//!
//! `HOME` must be an absolute path when a default needs it (spec). The env and
//! cwd are injected (see `EnvLookup`) so resolution is hermetic and testable
//! without ever touching real user roots (CLAUDE.md hard rule).

const std = @import("std");
const result = @import("result.zig");
const discovery = @import("discovery.zig");

/// Explicit per-root overrides from `--canonical-root` / `--imports-root` /
/// `--claude-code-root` / `--codex-root`. A null field means "use the default".
pub const Overrides = struct {
    canonical_root: ?[]const u8 = null,
    imports_root: ?[]const u8 = null,
    claude_code_root: ?[]const u8 = null,
    codex_root: ?[]const u8 = null,
};

/// Injectable environment lookup (struct of fn pointer) so root resolution is
/// hermetic in tests; production wires this to the process environment.
pub const EnvLookup = struct {
    getFn: *const fn (ctx: *anyopaque, key: []const u8) ?[]const u8,
    ctx: *anyopaque,

    pub fn get(self: EnvLookup, key: []const u8) ?[]const u8 {
        return self.getFn(self.ctx, key);
    }
};

const Result = result.Result(discovery.Roots);

/// Resolve all four roots. `cwd_path` is the absolute current working directory
/// used for runtime-root detection. All returned strings are owned by `arena`.
pub fn resolve(
    arena: std.mem.Allocator,
    io: std.Io,
    ov: Overrides,
    env: EnvLookup,
    cwd_path: []const u8,
) Result {
    return resolveImpl(arena, io, ov, env, cwd_path) catch
        return .{ .err = .{ .kind = .io_error, .reason = "out of memory resolving roots" } };
}

fn resolveImpl(
    arena: std.mem.Allocator,
    io: std.Io,
    ov: Overrides,
    env: EnvLookup,
    cwd_path: []const u8,
) error{OutOfMemory}!Result {
    // canonical = override, else <agent-skills-repo>/third-party.
    const canonical = if (ov.canonical_root) |c| c else blk: {
        const repo = if (env.get("AGENT_SKILLS_REPO")) |r|
            r
        else
            (homeJoin(arena, env, "dev/agent-skills") catch |e| return mapErr(e));
        break :blk try std.fs.path.join(arena, &.{ repo, "third-party" });
    };

    // imports = override, else <runtime-root>/.skill-importer/imports.
    const imports = if (ov.imports_root) |i| i else blk: {
        const runtime_root = runtimeRoot(arena, io, cwd_path) catch cwd_path;
        break :blk try std.fs.path.join(arena, &.{ runtime_root, ".skill-importer/imports" });
    };

    // claude_code = override, else $HOME/.claude/skills.
    const claude_code = if (ov.claude_code_root) |c|
        c
    else
        (homeJoin(arena, env, ".claude/skills") catch |e| return mapErr(e));

    // codex = override, else $HOME/.agents/skills.
    const codex = if (ov.codex_root) |c|
        c
    else
        (homeJoin(arena, env, ".agents/skills") catch |e| return mapErr(e));

    return .{ .ok = .{
        .canonical = canonical,
        .imports = imports,
        .claude_code = claude_code,
        .codex = codex,
    } };
}

const HomeError = error{ OutOfMemory, MissingHome, RelativeHome };

/// Join `rel` under `$HOME`, requiring an absolute `HOME` (spec: "If a default
/// requires HOME, HOME must be set to an absolute path").
fn homeJoin(arena: std.mem.Allocator, env: EnvLookup, rel: []const u8) HomeError![]const u8 {
    const home = env.get("HOME") orelse return error.MissingHome;
    if (!std.fs.path.isAbsolute(home)) return error.RelativeHome;
    return std.fs.path.join(arena, &.{ home, rel });
}

fn mapErr(e: HomeError) Result {
    return switch (e) {
        error.OutOfMemory => .{ .err = .{ .kind = .io_error, .reason = "out of memory resolving roots" } },
        error.MissingHome => .{ .err = .{
            .kind = .parse_error,
            .reason = "HOME is required to resolve a default root but is not set",
        } },
        error.RelativeHome => .{ .err = .{
            .kind = .parse_error,
            .reason = "HOME must be an absolute path to resolve a default root",
        } },
    };
}

/// Nearest ancestor of `cwd_path` (inclusive) that contains BOTH `AGENTS.md` and
/// `catalog/portable/` (spec "Root Resolution"). Returns the matching ancestor's
/// path (arena-owned), or `error.NotFound` if none qualifies (caller falls back
/// to cwd). Probes the filesystem with no-follow-agnostic existence checks.
fn runtimeRoot(arena: std.mem.Allocator, io: std.Io, cwd_path: []const u8) error{ OutOfMemory, NotFound }![]const u8 {
    var cur: []const u8 = cwd_path;
    while (true) {
        if (try hasRuntimeMarkers(arena, io, cur)) return cur;
        const parent = std.fs.path.dirname(cur) orelse return error.NotFound;
        if (std.mem.eql(u8, parent, cur)) return error.NotFound;
        cur = parent;
    }
}

/// True iff `dir` contains both `AGENTS.md` and `catalog/portable/`.
fn hasRuntimeMarkers(arena: std.mem.Allocator, io: std.Io, dir: []const u8) error{OutOfMemory}!bool {
    const agents = try std.fs.path.join(arena, &.{ dir, "AGENTS.md" });
    std.Io.Dir.accessAbsolute(io, agents, .{}) catch return false;
    const portable = try std.fs.path.join(arena, &.{ dir, "catalog/portable" });
    std.Io.Dir.accessAbsolute(io, portable, .{}) catch return false;
    return true;
}
