//! Hand-written argument parser (cli-clean-room-spec.md "Root Resolution" global
//! options + "Commands").
//!
//!   skill-importer [global-options] <command> [command-options]
//!
//! Global options (before the command word):
//!   --format text|json
//!   --canonical-root PATH  --imports-root PATH
//!   --claude-code-root PATH  --codex-root PATH
//!
//! Commands: list | import (markdown|path|url|repository) | enable | disable |
//! promote | unpromote | delete | tui, with the per-command options in the spec.
//! `--agent` and `--select` are repeatable; `--skill`/`--path`/`--url`/
//! `--repository`/`--source-location` are singletons; `--overwrite` is a flag.
//!
//! Any parse failure returns a `result.err` of kind `.parse_error` with an
//! actionable `reason`; `main.zig` writes it to stderr and exits 1 (spec
//! "Output Contract": exit codes — parse errors are exit 1).

const std = @import("std");
const result = @import("result.zig");
const types = @import("types.zig");
const roots = @import("roots.zig");

/// Output format (spec "Output Contract"). Defaults to `text`.
pub const Format = enum { text, json };

/// The fully-parsed command (spec "Commands"). One variant per subcommand.
pub const Command = union(enum) {
    list,
    import_markdown: struct { source_location: ?[]const u8 = null },
    import_path: struct { path: []const u8 },
    import_url: struct { url: []const u8 },
    import_repository: struct { repository: []const u8, select: []const []const u8 },
    enable: struct { skill: []const u8, agents: []const types.Agent },
    disable: struct { skill: []const u8, agents: []const types.Agent },
    promote: struct { skill: []const u8, overwrite: bool },
    unpromote: struct { skill: []const u8 },
    delete: struct { skill: []const u8 },
    /// Non-spec extension (analyzer.zig): render a Codex report JSON to HTML.
    render_analysis_report: struct { input: []const u8, output: []const u8 },
    /// Non-spec extension (analyzer_launch.zig): launch a Codex analysis of a skill.
    analyze: struct { skill: []const u8 },
    tui,
};

/// The complete parsed invocation: global format + root overrides + command.
pub const Parsed = struct {
    format: Format = .text,
    overrides: roots.Overrides = .{},
    command: Command,
};

pub const Result = result.Result(Parsed);

fn parseError(reason: []const u8) Result {
    return .{ .err = .{ .kind = .parse_error, .reason = reason } };
}

/// Parse `args` (argv WITHOUT the program name). All slices are borrowed from
/// `args`; any allocated lists (`--agent`, `--select`) are owned by `arena`.
pub fn parse(arena: std.mem.Allocator, args: []const []const u8) Result {
    var format: Format = .text;
    var overrides: roots.Overrides = .{};

    var i: usize = 0;
    // --- global options, until the first non-flag token (the command word) ---
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (tok.len == 0 or tok[0] != '-') break;
        if (std.mem.eql(u8, tok, "--format")) {
            const v = nextValue(args, &i) orelse return parseError("--format requires a value (text|json)");
            if (std.mem.eql(u8, v, "text")) {
                format = .text;
            } else if (std.mem.eql(u8, v, "json")) {
                format = .json;
            } else return parseError("invalid --format value (expected text|json)");
        } else if (std.mem.eql(u8, tok, "--canonical-root")) {
            overrides.canonical_root = nextValue(args, &i) orelse return parseError("--canonical-root requires a PATH");
        } else if (std.mem.eql(u8, tok, "--imports-root")) {
            overrides.imports_root = nextValue(args, &i) orelse return parseError("--imports-root requires a PATH");
        } else if (std.mem.eql(u8, tok, "--claude-code-root")) {
            overrides.claude_code_root = nextValue(args, &i) orelse return parseError("--claude-code-root requires a PATH");
        } else if (std.mem.eql(u8, tok, "--codex-root")) {
            overrides.codex_root = nextValue(args, &i) orelse return parseError("--codex-root requires a PATH");
        } else {
            return parseError("unknown global option");
        }
    }

    if (i >= args.len) return parseError("missing command");

    const cmd_word = args[i];
    i += 1;
    const rest = args[i..];

    const command: Command = blk: {
        if (std.mem.eql(u8, cmd_word, "list")) {
            break :blk switch (parseListLike(rest)) {
                .ok => .list,
                .err => |e| return .{ .err = e },
            };
        } else if (std.mem.eql(u8, cmd_word, "tui")) {
            break :blk switch (parseListLike(rest)) {
                .ok => .tui,
                .err => |e| return .{ .err = e },
            };
        } else if (std.mem.eql(u8, cmd_word, "import")) {
            break :blk switch (parseImport(arena, rest)) {
                .ok => |c| c,
                .err => |e| return .{ .err = e },
            };
        } else if (std.mem.eql(u8, cmd_word, "enable")) {
            break :blk switch (parseAgentOp(arena, rest, .enable)) {
                .ok => |c| c,
                .err => |e| return .{ .err = e },
            };
        } else if (std.mem.eql(u8, cmd_word, "disable")) {
            break :blk switch (parseAgentOp(arena, rest, .disable)) {
                .ok => |c| c,
                .err => |e| return .{ .err = e },
            };
        } else if (std.mem.eql(u8, cmd_word, "promote")) {
            break :blk switch (parsePromote(rest)) {
                .ok => |c| c,
                .err => |e| return .{ .err = e },
            };
        } else if (std.mem.eql(u8, cmd_word, "unpromote")) {
            break :blk switch (parseSkillOnly(rest, .unpromote)) {
                .ok => |c| c,
                .err => |e| return .{ .err = e },
            };
        } else if (std.mem.eql(u8, cmd_word, "delete")) {
            break :blk switch (parseSkillOnly(rest, .delete)) {
                .ok => |c| c,
                .err => |e| return .{ .err = e },
            };
        } else if (std.mem.eql(u8, cmd_word, "render-analysis-report")) {
            break :blk switch (parseRenderAnalysisReport(rest)) {
                .ok => |c| c,
                .err => |e| return .{ .err = e },
            };
        } else if (std.mem.eql(u8, cmd_word, "analyze")) {
            break :blk switch (parseSkillOnly(rest, .analyze)) {
                .ok => |c| c,
                .err => |e| return .{ .err = e },
            };
        } else {
            return parseError("unknown command");
        }
    };

    return .{ .ok = .{ .format = format, .overrides = overrides, .command = command } };
}

/// Advance `i` to the option's value and return it, or null at end-of-args.
fn nextValue(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

const VoidResult = result.Result(void);

/// `list`/`tui` accept no command options; any extra token is an error.
fn parseListLike(rest: []const []const u8) VoidResult {
    if (rest.len != 0) return .{ .err = .{ .kind = .parse_error, .reason = "command takes no options" } };
    return .{ .ok = {} };
}

const CmdResult = result.Result(Command);

fn parseImport(arena: std.mem.Allocator, rest: []const []const u8) CmdResult {
    if (rest.len == 0) return .{ .err = .{ .kind = .parse_error, .reason = "import requires a subcommand (markdown|path|url|repository)" } };
    const sub = rest[0];
    const opts = rest[1..];
    if (std.mem.eql(u8, sub, "markdown")) return parseImportMarkdown(opts);
    if (std.mem.eql(u8, sub, "path")) return parseImportPath(opts);
    if (std.mem.eql(u8, sub, "url")) return parseImportUrl(opts);
    if (std.mem.eql(u8, sub, "repository")) return parseImportRepository(arena, opts);
    return .{ .err = .{ .kind = .parse_error, .reason = "unknown import subcommand (expected markdown|path|url|repository)" } };
}

fn parseImportMarkdown(opts: []const []const u8) CmdResult {
    var source_location: ?[]const u8 = null;
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        const tok = opts[i];
        if (std.mem.eql(u8, tok, "--source-location")) {
            source_location = nextValue(opts, &i) orelse return optNeedsValue("--source-location");
        } else return unknownOpt();
    }
    return .{ .ok = .{ .import_markdown = .{ .source_location = source_location } } };
}

fn parseImportPath(opts: []const []const u8) CmdResult {
    var p: ?[]const u8 = null;
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        const tok = opts[i];
        if (std.mem.eql(u8, tok, "--path")) {
            p = nextValue(opts, &i) orelse return optNeedsValue("--path");
        } else return unknownOpt();
    }
    const path = p orelse return .{ .err = .{ .kind = .parse_error, .reason = "import path requires --path PATH" } };
    return .{ .ok = .{ .import_path = .{ .path = path } } };
}

fn parseImportUrl(opts: []const []const u8) CmdResult {
    var u: ?[]const u8 = null;
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        const tok = opts[i];
        if (std.mem.eql(u8, tok, "--url")) {
            u = nextValue(opts, &i) orelse return optNeedsValue("--url");
        } else return unknownOpt();
    }
    const url = u orelse return .{ .err = .{ .kind = .parse_error, .reason = "import url requires --url URL" } };
    return .{ .ok = .{ .import_url = .{ .url = url } } };
}

fn parseImportRepository(arena: std.mem.Allocator, opts: []const []const u8) CmdResult {
    var repo: ?[]const u8 = null;
    var select: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        const tok = opts[i];
        if (std.mem.eql(u8, tok, "--repository")) {
            repo = nextValue(opts, &i) orelse return optNeedsValue("--repository");
        } else if (std.mem.eql(u8, tok, "--select")) {
            const v = nextValue(opts, &i) orelse return optNeedsValue("--select");
            select.append(arena, v) catch return oom();
        } else return unknownOpt();
    }
    const repository = repo orelse return .{ .err = .{ .kind = .parse_error, .reason = "import repository requires --repository REPOSITORY" } };
    return .{ .ok = .{ .import_repository = .{
        .repository = repository,
        .select = select.toOwnedSlice(arena) catch return oom(),
    } } };
}

const AgentOpKind = enum { enable, disable };

fn parseAgentOp(arena: std.mem.Allocator, opts: []const []const u8, kind: AgentOpKind) CmdResult {
    var skill: ?[]const u8 = null;
    var agents: std.ArrayList(types.Agent) = .empty;
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        const tok = opts[i];
        if (std.mem.eql(u8, tok, "--skill")) {
            skill = nextValue(opts, &i) orelse return optNeedsValue("--skill");
        } else if (std.mem.eql(u8, tok, "--agent")) {
            const v = nextValue(opts, &i) orelse return optNeedsValue("--agent");
            const ag = parseAgent(v) orelse return .{ .err = .{ .kind = .parse_error, .reason = "invalid --agent value (expected claude-code|codex)" } };
            agents.append(arena, ag) catch return oom();
        } else return unknownOpt();
    }
    const s = skill orelse return .{ .err = .{ .kind = .parse_error, .reason = "requires --skill NAME" } };
    if (agents.items.len == 0) return .{ .err = .{ .kind = .parse_error, .reason = "requires at least one --agent claude-code|codex" } };
    const agent_slice = agents.toOwnedSlice(arena) catch return oom();
    return switch (kind) {
        .enable => .{ .ok = .{ .enable = .{ .skill = s, .agents = agent_slice } } },
        .disable => .{ .ok = .{ .disable = .{ .skill = s, .agents = agent_slice } } },
    };
}

fn parseAgent(v: []const u8) ?types.Agent {
    if (std.mem.eql(u8, v, "claude-code")) return .claude_code;
    if (std.mem.eql(u8, v, "codex")) return .codex;
    return null;
}

fn parsePromote(opts: []const []const u8) CmdResult {
    var skill: ?[]const u8 = null;
    var overwrite = false;
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        const tok = opts[i];
        if (std.mem.eql(u8, tok, "--skill")) {
            skill = nextValue(opts, &i) orelse return optNeedsValue("--skill");
        } else if (std.mem.eql(u8, tok, "--overwrite")) {
            overwrite = true;
        } else return unknownOpt();
    }
    const s = skill orelse return .{ .err = .{ .kind = .parse_error, .reason = "promote requires --skill NAME" } };
    return .{ .ok = .{ .promote = .{ .skill = s, .overwrite = overwrite } } };
}

const SkillOnlyKind = enum { unpromote, delete, analyze };

fn parseSkillOnly(opts: []const []const u8, kind: SkillOnlyKind) CmdResult {
    var skill: ?[]const u8 = null;
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        const tok = opts[i];
        if (std.mem.eql(u8, tok, "--skill")) {
            skill = nextValue(opts, &i) orelse return optNeedsValue("--skill");
        } else return unknownOpt();
    }
    const s = skill orelse return .{ .err = .{ .kind = .parse_error, .reason = "requires --skill NAME" } };
    return switch (kind) {
        .unpromote => .{ .ok = .{ .unpromote = .{ .skill = s } } },
        .delete => .{ .ok = .{ .delete = .{ .skill = s } } },
        .analyze => .{ .ok = .{ .analyze = .{ .skill = s } } },
    };
}

/// `render-analysis-report --input PATH --output PATH` (both required, singletons;
/// last value wins like the other singleton parsers). Non-spec extension.
fn parseRenderAnalysisReport(opts: []const []const u8) CmdResult {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        const tok = opts[i];
        if (std.mem.eql(u8, tok, "--input")) {
            input = nextValue(opts, &i) orelse return optNeedsValue("--input");
        } else if (std.mem.eql(u8, tok, "--output")) {
            output = nextValue(opts, &i) orelse return optNeedsValue("--output");
        } else return unknownOpt();
    }
    const in = input orelse return .{ .err = .{ .kind = .parse_error, .reason = "render-analysis-report requires --input PATH" } };
    const out = output orelse return .{ .err = .{ .kind = .parse_error, .reason = "render-analysis-report requires --output PATH" } };
    return .{ .ok = .{ .render_analysis_report = .{ .input = in, .output = out } } };
}

fn unknownOpt() CmdResult {
    return .{ .err = .{ .kind = .parse_error, .reason = "unknown command option" } };
}

fn optNeedsValue(name: []const u8) CmdResult {
    _ = name;
    return .{ .err = .{ .kind = .parse_error, .reason = "command option requires a value" } };
}

fn oom() CmdResult {
    return .{ .err = .{ .kind = .io_error, .reason = "out of memory parsing arguments" } };
}
