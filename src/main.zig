//! CLI entry point (cli-clean-room-spec.md "Root Resolution", "Output Contract",
//! "Commands", exit codes). Wires argv -> cli.parse -> roots.resolve -> command
//! dispatch -> JSON/text render -> flush -> exit code (zig-clean-room-cli.md
//! Phase 6).
//!
//! - An arena allocator scopes one operation; all result strings are arena-owned.
//! - `--format json` renders the spec JSON (UTF-8, single trailing newline);
//!   `--format text` renders a short human summary. Both share exit status and
//!   filesystem behavior (spec "Output Contract").
//! - Failures write `skill-importer: <message>` to stderr and exit 1 (spec exit
//!   codes: 0 success, 1 everything else).
//! - `tui` rejects `--format json`, prints "TUI not implemented", exits 1
//!   (zig-clean-room-cli.md "Decisions locked in": TUI deferred).
//! - Real `net`/`git` providers are injected for url/repository imports.

const std = @import("std");

const cli = @import("cli.zig");
const roots = @import("roots.zig");
const types = @import("types.zig");
const result = @import("result.zig");
const discovery = @import("discovery.zig");
const import_mod = @import("import.zig");
const repository = @import("repository.zig");
const ops = @import("ops.zig");
const json_out = @import("json_out.zig");
const net = @import("net.zig");
const git = @import("git.zig");

pub fn main(init: std.process.Init) !void {
    const code = run(init) catch |err| {
        // Last-resort failure (e.g. OOM building the argv slice): report and exit 1.
        var ebuf: [256]u8 = undefined;
        var ew = std.Io.File.stderr().writer(init.io, &ebuf);
        ew.interface.print("skill-importer: internal error: {s}\n", .{@errorName(err)}) catch {};
        ew.interface.flush() catch {};
        std.process.exit(1);
    };
    std.process.exit(code);
}

/// Run one invocation; return the process exit code. Never calls
/// `std.process.exit` itself so flushing always happens via normal control flow.
fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    // Operation arena: every result string lives here, freed on return.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Collect argv (excluding program name) into an arena-owned slice.
    const args = try collectArgs(arena, init.minimal.args);

    // --- parse ---
    const parsed = switch (cli.parse(arena, args)) {
        .ok => |p| p,
        .err => |e| return fail(io, arena, e),
    };

    // --- tui is special: it owns the terminal and is deferred ---
    if (parsed.command == .tui) {
        if (parsed.format == .json) {
            return failMsg(io, "tui does not support --format json");
        }
        return failMsg(io, "TUI not implemented");
    }

    // --- resolve roots ---
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    var env = EnvAdapter{ .map = init.environ_map };
    const resolved = switch (roots.resolve(arena, io, parsed.overrides, env.lookup(), cwd_path)) {
        .ok => |r| r,
        .err => |e| return fail(io, arena, e),
    };

    // Real wall clock for `imported_at` (spec "Import Manifest").
    var clock_state = RealClock{ .io = io };
    const clock = clock_state.clock();

    // --- dispatch + render ---
    return dispatch(arena, io, gpa, parsed, resolved, clock);
}

fn dispatch(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    parsed: cli.Parsed,
    resolved: discovery.Roots,
    clock: types.Clock,
) !u8 {
    switch (parsed.command) {
        .list => {
            const r = discovery.discover(arena, io, resolved);
            return renderResult(io, arena, parsed.format, r, json_out.writeInventory, textInventory);
        },
        .import_markdown => |c| {
            var ctx = importCtx(arena, io, resolved, clock);
            const md = try readStdin(io, arena);
            const r = import_mod.markdown(&ctx, md, c.source_location);
            return renderResult(io, arena, parsed.format, r, json_out.writeImportResult, textImport);
        },
        .import_path => |c| {
            var ctx = importCtx(arena, io, resolved, clock);
            const r = import_mod.path(&ctx, c.path);
            return renderResult(io, arena, parsed.format, r, json_out.writeImportResult, textImport);
        },
        .import_url => |c| {
            var ctx = importCtx(arena, io, resolved, clock);
            var real = net.RealFetcher.init(gpa);
            defer real.deinit();
            const r = import_mod.url(&ctx, real.fetcher(), c.url);
            return renderResult(io, arena, parsed.format, r, json_out.writeImportResult, textImport);
        },
        .import_repository => |c| {
            var ctx = repoCtx(arena, io, resolved, clock);
            var real = git.RealProvider.init(gpa, io);
            const r = repository.import(&ctx, real.provider(), c.repository, c.select);
            return renderResult(io, arena, parsed.format, r, json_out.writeRepositoryImportResult, textRepository);
        },
        .enable => |c| {
            var ctx = opsCtx(arena, io, resolved);
            const r = ops.enable(&ctx, c.skill, c.agents);
            return renderResult(io, arena, parsed.format, r, json_out.writeSkillOperationResult, textOperation);
        },
        .disable => |c| {
            var ctx = opsCtx(arena, io, resolved);
            const r = ops.disable(&ctx, c.skill, c.agents);
            return renderResult(io, arena, parsed.format, r, json_out.writeSkillOperationResult, textOperation);
        },
        .promote => |c| {
            var ctx = opsCtx(arena, io, resolved);
            const r = ops.promote(&ctx, c.skill, c.overwrite);
            return renderResult(io, arena, parsed.format, r, json_out.writeSkillOperationResult, textOperation);
        },
        .unpromote => |c| {
            var ctx = opsCtx(arena, io, resolved);
            const r = ops.unpromote(&ctx, c.skill);
            return renderResult(io, arena, parsed.format, r, json_out.writeSkillOperationResult, textOperation);
        },
        .delete => |c| {
            var ctx = opsCtx(arena, io, resolved);
            const r = ops.delete(&ctx, c.skill);
            return renderResult(io, arena, parsed.format, r, json_out.writeSkillOperationResult, textOperation);
        },
        .tui => unreachable, // handled in `run`
    }
}

// --- context builders -------------------------------------------------------

fn importCtx(arena: std.mem.Allocator, io: std.Io, r: discovery.Roots, clock: types.Clock) import_mod.Context {
    return .{
        .arena = arena,
        .io = io,
        .imports_root = r.imports,
        .canonical_root = r.canonical,
        .clock = clock,
    };
}

fn repoCtx(arena: std.mem.Allocator, io: std.Io, r: discovery.Roots, clock: types.Clock) repository.Context {
    return .{
        .arena = arena,
        .io = io,
        .imports_root = r.imports,
        .canonical_root = r.canonical,
        .clock = clock,
    };
}

fn opsCtx(arena: std.mem.Allocator, io: std.Io, r: discovery.Roots) ops.Context {
    return .{
        .arena = arena,
        .io = io,
        .canonical_root = r.canonical,
        .imports_root = r.imports,
        .claude_code_root = r.claude_code,
        .codex_root = r.codex,
    };
}

// --- rendering --------------------------------------------------------------

/// Render a `result.Result(T)`: on ok, emit JSON (via `jsonFn`) or text (via
/// `textFn`) to stdout, flush, return 0. On err, write stderr + return 1.
fn renderResult(
    io: std.Io,
    arena: std.mem.Allocator,
    format: cli.Format,
    r: anytype,
    comptime jsonFn: anytype,
    comptime textFn: anytype,
) !u8 {
    switch (r) {
        .ok => |value| {
            var buf: [4096]u8 = undefined;
            var fw = std.Io.File.stdout().writer(io, &buf);
            const w = &fw.interface;
            switch (format) {
                .json => try jsonFn(w, value),
                .text => try textFn(w, value),
            }
            try w.flush();
            return 0;
        },
        .err => |e| return fail(io, arena, e),
    }
}

// Text renderers: human-only summaries (spec "Output Contract": text output may
// vary; only exit status + filesystem behavior are normative). Each ends in a
// newline for tidy terminal output.

fn textInventory(w: *std.Io.Writer, inv: types.Inventory) std.Io.Writer.Error!void {
    if (inv.skills.len == 0) {
        try w.writeAll("no skills found\n");
        return;
    }
    for (inv.skills) |s| {
        try w.print("{s}\t{s}\n", .{ s.name, @tagName(s.source) });
    }
}

fn textImport(w: *std.Io.Writer, r: types.ImportResult) std.Io.Writer.Error!void {
    try w.print("imported {s} -> {s}\n", .{ r.skill_name, r.skill_path });
}

fn textRepository(w: *std.Io.Writer, r: types.RepositoryImportResult) std.Io.Writer.Error!void {
    switch (r) {
        .imported => |x| try w.print("imported {s} -> {s}\n", .{ x.skill_name, x.skill_path }),
        .imported_batch => |x| try w.print("imported {d} skills\n", .{x.imports.len}),
        .selection => |x| {
            try w.print("select a skill from {s}:\n", .{x.repository});
            for (x.skills) |c| try w.print("  {s}\t{s}\n", .{ c.relative_path, c.name });
        },
    }
}

fn textOperation(w: *std.Io.Writer, r: types.SkillOperationResult) std.Io.Writer.Error!void {
    try w.print("{s}: {d} action(s)\n", .{ r.skill_name, r.actions.len });
}

// --- failure reporting ------------------------------------------------------

/// Write `skill-importer: <message>` to stderr and return exit code 1.
fn fail(io: std.Io, arena: std.mem.Allocator, e: result.ErrorInfo) !u8 {
    return failMsg(io, errorMessage(arena, e) catch "operation failed");
}

fn failMsg(io: std.Io, message: []const u8) !u8 {
    var ebuf: [512]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &ebuf);
    try ew.interface.print("skill-importer: {s}\n", .{message});
    try ew.interface.flush();
    return 1;
}

/// Build an actionable stderr message naming the failing operation and the
/// specific path/URL/repository/skill where available (spec "Output Contract":
/// "Error text should include the failing operation and the specific path, URL,
/// repository, or skill name where applicable").
pub fn errorMessage(arena: std.mem.Allocator, e: result.ErrorInfo) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.writeAll(kindMessage(e.kind));
    if (e.name) |n| try w.print(" (skill: {s})", .{n});
    if (e.path) |p| try w.print(" (path: {s})", .{p});
    if (e.url) |u| try w.print(" (url: {s})", .{u});
    if (e.repository) |rp| try w.print(" (repository: {s})", .{rp});
    if (e.field) |f| try w.print(" (field: {s})", .{f});
    if (e.reason) |rs| try w.print(": {s}", .{rs});
    return aw.written();
}

fn kindMessage(kind: result.ErrorKind) []const u8 {
    return switch (kind) {
        .parse_error => "invalid command line",
        .missing_open_delimiter => "SKILL.md is missing the opening '---' frontmatter delimiter",
        .missing_close_delimiter => "SKILL.md is missing the closing '---' frontmatter delimiter",
        .missing_name => "SKILL.md frontmatter is missing a name",
        .invalid_name => "SKILL.md frontmatter name is not a single directory-safe path segment",
        .missing_description => "SKILL.md frontmatter is missing a description",
        .discovery_error => "failed to discover skills",
        .malformed_manifest => "an imported skill has a malformed import.json",
        .unknown_skill => "unknown skill",
        .agent_only_skill => "skill exists only as an agent entry and cannot be managed",
        .not_promoted => "skill is not promoted",
        .already_promoted => "skill is already promoted",
        .canonical_only_skill => "skill exists only in the canonical root",
        .import_collision => "an import with this name already exists",
        .canonical_collision => "a canonical skill already exists at the destination",
        .frontmatter_name_collision => "a canonical skill with this frontmatter name already exists",
        .unsafe_agent_entry => "an existing agent entry is unsafe and was left untouched",
        .unsupported_entry => "the source contains an unsupported filesystem entry",
        .imports_root_inside_source => "the imports root is inside the source directory",
        .reserved_manifest_in_source => "the source contains a reserved import.json",
        .fetch_failed => "failed to fetch the URL",
        .size_exceeded => "the response exceeded the maximum allowed size",
        .invalid_utf8 => "the content is not valid UTF-8",
        .timeout => "the network request timed out",
        .duplicate_selection => "a skill was selected more than once",
        .missing_selection => "the selected skill was not found in the repository",
        .duplicate_skill_name => "two selected skills resolve to the same name",
        .depth_exceeded => "a skill is beyond the repository scan depth limit",
        .empty_repository => "the repository contains no valid skills",
        .git_unavailable => "git is not available",
        .repository_error => "failed to process the repository",
        .enabled_import => "the import is enabled; disable it first",
        .io_error => "a filesystem operation failed",
        .out_of_memory => "out of memory",
    };
}

// --- helpers ----------------------------------------------------------------

/// Read all of stdin into arena-owned bytes (for `import markdown`).
fn readStdin(io: std.Io, arena: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().readerStreaming(io, &buf);
    return fr.interface.allocRemaining(arena, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

/// Collect argv (excluding the program name) into an arena-owned slice.
fn collectArgs(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    var it = args.iterate();
    _ = it.skip(); // program name
    var list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |a| {
        try list.append(arena, try arena.dupe(u8, a));
    }
    return list.toOwnedSlice(arena);
}

/// Adapter exposing the process environment as a `roots.EnvLookup`.
const EnvAdapter = struct {
    map: *std.process.Environ.Map,

    fn lookup(self: *EnvAdapter) roots.EnvLookup {
        return .{ .getFn = getImpl, .ctx = self };
    }

    fn getImpl(ctx: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *EnvAdapter = @ptrCast(@alignCast(ctx));
        return self.map.get(key);
    }
};

/// Real wall clock (`Io.Clock.real`) producing Unix seconds for `imported_at`.
const RealClock = struct {
    io: std.Io,

    fn clock(self: *RealClock) types.Clock {
        return .{ .nowFn = nowImpl, .ctx = self };
    }

    fn nowImpl(ctx: *anyopaque) i64 {
        const self: *RealClock = @ptrCast(@alignCast(ctx));
        const ts = std.Io.Clock.now(.real, self.io);
        return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
    }
};
