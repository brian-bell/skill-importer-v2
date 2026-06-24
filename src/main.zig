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
const analyzer = @import("analyzer.zig");
const analyzer_launch = @import("analyzer_launch.zig");
const builtin = @import("builtin");

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

    // --- render-analysis-report operates on explicit paths only (no roots,
    // no HOME), so handle it before root resolution. Non-spec extension. ---
    if (parsed.command == .render_analysis_report) {
        const c = parsed.command.render_analysis_report;
        switch (analyzer.renderReportFile(arena, io, c.input, c.output)) {
            .ok => return renderReportOk(io, parsed.format, c.output),
            .err => |e| return fail(io, arena, e),
        }
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

    // Resolve this binary's path for the analyzer launch script (it `cd`s into a
    // workspace, so a relative argv[0] is absolutized; a bare name resolves via
    // the inherited PATH). Only used by `analyze`.
    const self_exe = try resolveSelfExe(arena, io, init.minimal.args);

    // --- dispatch + render ---
    return dispatch(arena, io, gpa, parsed, resolved, clock, init.environ_map, self_exe);
}

fn dispatch(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    parsed: cli.Parsed,
    resolved: discovery.Roots,
    clock: types.Clock,
    environ_map: *std.process.Environ.Map,
    self_exe: []const u8,
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
        .analyze => |c| {
            const home = environ_map.get("HOME") orelse "";
            const codex_home = environ_map.get("CODEX_HOME") orelse
                (if (home.len != 0) try std.fs.path.join(arena, &.{ home, ".codex" }) else "");
            const inherited = try collectInheritedEnv(arena, environ_map);
            var spawner_state = analyzer_launch.RealSpawner{ .gpa = gpa, .io = io };
            var actx = analyzer_launch.Context{
                .arena = arena,
                .io = io,
                .canonical_root = resolved.canonical,
                .imports_root = resolved.imports,
                .claude_code_root = resolved.claude_code,
                .codex_root = resolved.codex,
                .home = home,
                .codex_home = codex_home,
                .inherited_env = inherited,
                .current_exe = self_exe,
                .clock = clock,
                .is_macos = builtin.target.os.tag == .macos,
            };
            const r = analyzer_launch.analyze(&actx, spawner_state.spawner(), c.skill);
            return renderResult(io, arena, parsed.format, r, jsonAnalyze, textAnalyze);
        },
        .render_analysis_report => unreachable, // handled in `run`
        .tui => unreachable, // handled in `run`
    }
}

/// Collect the locale/terminal/PATH passthrough environment for an analyzer
/// launch (analyzer.inheritedEnvEntry filter), sorted by name for determinism.
fn collectInheritedEnv(arena: std.mem.Allocator, map: *std.process.Environ.Map) ![]const analyzer.EnvEntry {
    var list: std.ArrayList(analyzer.EnvEntry) = .empty;
    var it = map.iterator();
    while (it.next()) |e| {
        if (analyzer.inheritedEnvEntry(e.key_ptr.*, e.value_ptr.*)) |entry| {
            try list.append(arena, .{
                .name = try arena.dupe(u8, entry.name),
                .value = try arena.dupe(u8, entry.value),
            });
        }
    }
    std.mem.sort(analyzer.EnvEntry, list.items, {}, envLess);
    return list.toOwnedSlice(arena);
}

fn envLess(_: void, a: analyzer.EnvEntry, b: analyzer.EnvEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Best-effort current-executable path from argv[0]: absolute as-is, relative
/// absolutized against cwd (the launch script `cd`s), bare name left for PATH.
fn resolveSelfExe(arena: std.mem.Allocator, io: std.Io, args: std.process.Args) ![]const u8 {
    var it = args.iterate();
    const argv0 = it.next() orelse return "";
    if (argv0.len == 0 or std.fs.path.isAbsolute(argv0)) return arena.dupe(u8, argv0);
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        return std.Io.Dir.cwd().realPathFileAlloc(io, argv0, arena) catch arena.dupe(u8, argv0);
    }
    return arena.dupe(u8, argv0);
}

fn jsonAnalyze(w: *std.Io.Writer, r: analyzer_launch.AnalyzeResult) std.Io.Writer.Error!void {
    try std.json.Stringify.value(r, json_out.json_options, w);
    try w.writeByte('\n');
}

fn textAnalyze(w: *std.Io.Writer, r: analyzer_launch.AnalyzeResult) std.Io.Writer.Error!void {
    try w.print("analysis launched for {s}; report: {s}\n", .{ r.skill_name, r.report_path });
}

/// Emit the `render-analysis-report` success line. Text: a short confirmation;
/// JSON: a stable `{"output": "<path>"}` object with one trailing newline. (The
/// launch script invokes this command without `--format`, so JSON is cosmetic.)
fn renderReportOk(io: std.Io, format: cli.Format, output: []const u8) !u8 {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    switch (format) {
        .json => try std.json.Stringify.value(.{ .output = output }, json_out.json_options, w),
        .text => try w.print("wrote {s}", .{output}),
    }
    try w.writeByte('\n');
    try w.flush();
    return 0;
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
        .malformed_report => "the analysis report JSON is malformed",
        .report_input_invalid => "the analysis report input is not a readable regular file",
        .report_output_exists => "the analysis report output already exists",
        .unsupported_platform => "skill analysis launch is supported only on macOS",
        .codex_unavailable => "the codex CLI was not found or could not be executed",
        .file_backed_codex_auth => "skill analysis cannot run with file-backed Codex auth; use a credential mode that is not exposed to shell tools",
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
