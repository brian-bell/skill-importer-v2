//! Tests for the hand-written CLI parser (cli-clean-room-spec.md "Root
//! Resolution" global options + "Commands"). Covers each command's happy parse
//! and a representative parse error, global `--format`, the four root overrides,
//! repeatable `--agent`/`--select`, and the singleton flags.

const std = @import("std");
const testing = std.testing;

const cli = @import("cli.zig");
const types = @import("types.zig");

fn parse(arena: std.mem.Allocator, args: []const []const u8) cli.Result {
    return cli.parse(arena, args);
}

// spec "Commands > list": `skill-importer [global-options] list`.
test "parse list with no global options" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{"list"}).ok;
    try testing.expect(p.command == .list);
    try testing.expectEqual(cli.Format.text, p.format);
}

// spec "Output Contract": global `--format json`.
test "parse global --format json before command" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "--format", "json", "list" }).ok;
    try testing.expectEqual(cli.Format.json, p.format);
    try testing.expect(p.command == .list);
}

// spec "Root Resolution": the four global root overrides.
test "parse all four root overrides" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{
        "--canonical-root",   "/a",
        "--imports-root",     "/b",
        "--claude-code-root", "/c",
        "--codex-root",       "/d",
        "list",
    }).ok;
    try testing.expectEqualStrings("/a", p.overrides.canonical_root.?);
    try testing.expectEqualStrings("/b", p.overrides.imports_root.?);
    try testing.expectEqualStrings("/c", p.overrides.claude_code_root.?);
    try testing.expectEqualStrings("/d", p.overrides.codex_root.?);
}

// spec "import markdown": optional `--source-location`.
test "parse import markdown with source-location" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "import", "markdown", "--source-location", "clipboard" }).ok;
    try testing.expect(p.command == .import_markdown);
    try testing.expectEqualStrings("clipboard", p.command.import_markdown.source_location.?);
}

// spec "import markdown": `--source-location` is optional.
test "parse import markdown without source-location" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "import", "markdown" }).ok;
    try testing.expect(p.command == .import_markdown);
    try testing.expect(p.command.import_markdown.source_location == null);
}

// spec "import path": `--path PATH` required.
test "parse import path" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "import", "path", "--path", "/src/skill" }).ok;
    try testing.expectEqualStrings("/src/skill", p.command.import_path.path);
}

// spec "import path": missing required `--path` is a parse error.
test "import path without --path is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{ "import", "path" });
    try testing.expect(!r.isOk());
}

// spec "import url": `--url URL` required.
test "parse import url" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "import", "url", "--url", "https://x.test/s.md" }).ok;
    try testing.expectEqualStrings("https://x.test/s.md", p.command.import_url.url);
}

// spec "import repository": `--repository REPOSITORY [--select PATH ...]`.
test "parse import repository with repeated --select" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{
        "import",   "repository", "--repository", "https://x.test/r.git",
        "--select", "a",          "--select",     "b/c",
    }).ok;
    try testing.expectEqualStrings("https://x.test/r.git", p.command.import_repository.repository);
    try testing.expectEqual(@as(usize, 2), p.command.import_repository.select.len);
    try testing.expectEqualStrings("a", p.command.import_repository.select[0]);
    try testing.expectEqualStrings("b/c", p.command.import_repository.select[1]);
}

// spec "import repository": missing `--repository` is a parse error.
test "import repository without --repository is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{ "import", "repository" });
    try testing.expect(!r.isOk());
}

// spec "enable": `--skill NAME --agent claude-code|codex [--agent ...]`.
test "parse enable with repeated --agent" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{
        "enable", "--skill", "demo", "--agent", "claude-code", "--agent", "codex",
    }).ok;
    try testing.expectEqualStrings("demo", p.command.enable.skill);
    try testing.expectEqual(@as(usize, 2), p.command.enable.agents.len);
    try testing.expectEqual(types.Agent.claude_code, p.command.enable.agents[0]);
    try testing.expectEqual(types.Agent.codex, p.command.enable.agents[1]);
}

// spec "enable": an unknown `--agent` value is a parse error.
test "enable with unknown agent is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{ "enable", "--skill", "demo", "--agent", "bogus" });
    try testing.expect(!r.isOk());
}

// spec "enable": missing `--skill` is a parse error.
test "enable without --skill is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{ "enable", "--agent", "codex" });
    try testing.expect(!r.isOk());
}

// spec "disable": same shape as enable.
test "parse disable" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "disable", "--skill", "demo", "--agent", "codex" }).ok;
    try testing.expectEqualStrings("demo", p.command.disable.skill);
    try testing.expectEqual(@as(usize, 1), p.command.disable.agents.len);
}

// spec "promote": `--skill NAME [--overwrite]`.
test "parse promote with --overwrite" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "promote", "--skill", "demo", "--overwrite" }).ok;
    try testing.expectEqualStrings("demo", p.command.promote.skill);
    try testing.expect(p.command.promote.overwrite);
}

// spec "promote": `--overwrite` defaults off.
test "parse promote without --overwrite" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "promote", "--skill", "demo" }).ok;
    try testing.expect(!p.command.promote.overwrite);
}

// spec "unpromote": `--skill NAME`.
test "parse unpromote" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "unpromote", "--skill", "demo" }).ok;
    try testing.expectEqualStrings("demo", p.command.unpromote.skill);
}

// spec "delete": `--skill NAME`.
test "parse delete" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "delete", "--skill", "demo" }).ok;
    try testing.expectEqualStrings("demo", p.command.delete.skill);
}

// spec "tui": `skill-importer [global-options] tui`.
test "parse tui" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{"tui"}).ok;
    try testing.expect(p.command == .tui);
}

// spec "Output Contract" exit codes: an unknown command is a parse error.
test "unknown command is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{"frobnicate"});
    try testing.expect(!r.isOk());
}

// spec "Commands": a missing command is a parse error.
test "no command is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{});
    try testing.expect(!r.isOk());
}

// spec "import": an unknown import subcommand is a parse error.
test "unknown import subcommand is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{ "import", "bogus" });
    try testing.expect(!r.isOk());
}

// spec "Output Contract": an unknown global flag is a parse error.
test "unknown flag is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{ "--nonsense", "list" });
    try testing.expect(!r.isOk());
}

// spec "Output Contract": an invalid `--format` value is a parse error.
test "invalid --format value is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{ "--format", "xml", "list" });
    try testing.expect(!r.isOk());
}

// A flag that needs a value but is at end-of-args is a parse error.
test "flag missing its value is parse error" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{"--format"});
    try testing.expect(!r.isOk());
}

// Non-spec extension: `render-analysis-report --input PATH --output PATH`.
test "parse render-analysis-report with input and output" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "render-analysis-report", "--input", "r.json", "--output", "r.html" }).ok;
    try testing.expect(p.command == .render_analysis_report);
    try testing.expectEqualStrings("r.json", p.command.render_analysis_report.input);
    try testing.expectEqualStrings("r.html", p.command.render_analysis_report.output);
}

test "render-analysis-report requires --input" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{ "render-analysis-report", "--output", "r.html" });
    try testing.expect(!r.isOk());
}

test "render-analysis-report requires --output" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{ "render-analysis-report", "--input", "r.json" });
    try testing.expect(!r.isOk());
}

// Non-spec extension: `analyze --skill NAME`.
test "parse analyze with skill" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const p = parse(arena_s.allocator(), &.{ "analyze", "--skill", "demo" }).ok;
    try testing.expect(p.command == .analyze);
    try testing.expectEqualStrings("demo", p.command.analyze.skill);
}

test "analyze requires --skill" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const r = parse(arena_s.allocator(), &.{"analyze"});
    try testing.expect(!r.isOk());
}
