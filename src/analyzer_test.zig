//! Tests for the analyzer (ported from v1 `analyzer.rs` `#[cfg(test)] mod tests`).
//! The analyzer is a non-spec extension, so v1 behavior is the oracle.
//! Safety (CLAUDE.md hard rule): every filesystem test runs inside a unique temp
//! tree via `testutil.TmpRoots`; nothing touches real user roots.

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const analyzer = @import("analyzer.zig");
const testutil = @import("testutil.zig");

// --- helpers ----------------------------------------------------------------

fn renderToArena(arena: std.mem.Allocator, report: analyzer.Report) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try analyzer.renderHtml(&aw.writer, report);
    return aw.written();
}

const sample_report = analyzer.Report{
    .skill_name = "demo-skill",
    .summary = "A short summary.",
    .walkthrough = &.{
        .{ .title = "Overview", .body = "How it works." },
    },
    .security_findings = &.{
        .{ .severity = .high, .title = "Shell exec", .detail = "Runs commands.", .recommendation = "Sandbox it." },
    },
    .residual_risks = &.{"Network access is not fully disabled."},
};

// ===========================================================================
// A. Report renderer
// ===========================================================================

test "renderHtml emits skill name, summary, walkthrough, findings, and risks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const html = try renderToArena(arena_state.allocator(), sample_report);

    try expectContains(html, "<h1>demo-skill</h1>");
    try expectContains(html, "<h2>Summary</h2><p>A short summary.</p>");
    try expectContains(html, "<h3>Overview</h3><p>How it works.</p>");
    try expectContains(html, "<div class=\"severity\">high</div>");
    try expectContains(html, "<h3>Shell exec</h3>");
    try expectContains(html, "<strong>Recommendation:</strong> Sandbox it.");
    try expectContains(html, "<li>Network access is not fully disabled.</li>");
}

test "renderHtml escapes HTML metacharacters in all text fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const report = analyzer.Report{
        .skill_name = "<x>&\"'",
        .summary = "a < b && c > d",
        .walkthrough = &.{},
        .security_findings = &.{},
        .residual_risks = &.{},
    };
    const html = try renderToArena(arena_state.allocator(), report);

    try expectContains(html, "&lt;x&gt;&amp;&quot;&#39;");
    try expectContains(html, "a &lt; b &amp;&amp; c &gt; d");
    // The raw, unescaped skill name must never appear verbatim.
    try testing.expect(std.mem.indexOf(u8, html, "<x>&\"'") == null);
}

test "parseReport accepts a well-formed report and parses severities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json =
        \\{"skill_name":"s","summary":"sum","walkthrough":[],
        \\"security_findings":[{"severity":"critical","title":"t","detail":"d","recommendation":"r"}],
        \\"residual_risks":["x"]}
    ;
    switch (analyzer.parseReport(arena, json)) {
        .ok => |r| {
            try testing.expectEqualStrings("s", r.skill_name);
            try testing.expectEqual(analyzer.Severity.critical, r.security_findings[0].severity);
            try testing.expectEqualStrings("x", r.residual_risks[0]);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseReport rejects malformed JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    switch (analyzer.parseReport(arena_state.allocator(), "{ not json")) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .malformed_report), e.kind),
    }
}

test "parseReport rejects unknown fields (deny_unknown_fields parity)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{"skill_name":"s","summary":"x","walkthrough":[],"security_findings":[],
        \\"residual_risks":[],"extra":"nope"}
    ;
    switch (analyzer.parseReport(arena_state.allocator(), json)) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .malformed_report), e.kind),
    }
}

test "parseReport rejects an unknown severity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{"skill_name":"s","summary":"x","walkthrough":[],
        \\"security_findings":[{"severity":"extreme","title":"t","detail":"d","recommendation":"r"}],
        \\"residual_risks":[]}
    ;
    switch (analyzer.parseReport(arena_state.allocator(), json)) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .malformed_report), e.kind),
    }
}

test "renderReportFile reads JSON and writes HTML" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try roots.dir().writeFile(io, .{ .sub_path = "report.json", .data = valid_report_json });
    const input = try std.fs.path.join(arena, &.{ roots.base, "report.json" });
    const output = try std.fs.path.join(arena, &.{ roots.base, "index.html" });

    switch (analyzer.renderReportFile(arena, io, input, output)) {
        .ok => {},
        .err => return error.UnexpectedError,
    }

    const html = try roots.dir().readFileAlloc(io, "index.html", arena, .unlimited);
    try expectContains(html, "<h1>demo</h1>");
    try expectContains(html, "<div class=\"severity\">low</div>");
}

test "renderReportFile refuses to overwrite an existing output" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try roots.dir().writeFile(io, .{ .sub_path = "report.json", .data = valid_report_json });
    try roots.dir().writeFile(io, .{ .sub_path = "index.html", .data = "old" });
    const input = try std.fs.path.join(arena, &.{ roots.base, "report.json" });
    const output = try std.fs.path.join(arena, &.{ roots.base, "index.html" });

    switch (analyzer.renderReportFile(arena, io, input, output)) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .report_output_exists), e.kind),
    }
}

test "renderReportFile refuses a symlinked input" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = testutil.Fixtures.init(&roots);

    try roots.dir().writeFile(io, .{ .sub_path = "real.json", .data = valid_report_json });
    try fx.symlink("real.json", "link.json");
    const input = try std.fs.path.join(arena, &.{ roots.base, "link.json" });
    const output = try std.fs.path.join(arena, &.{ roots.base, "out.html" });

    switch (analyzer.renderReportFile(arena, io, input, output)) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .report_input_invalid), e.kind),
    }
}

test "renderReportFile creates a missing output parent directory" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try roots.dir().writeFile(io, .{ .sub_path = "report.json", .data = valid_report_json });
    const input = try std.fs.path.join(arena, &.{ roots.base, "report.json" });
    const output = try std.fs.path.join(arena, &.{ roots.base, "nested", "deep", "index.html" });

    switch (analyzer.renderReportFile(arena, io, input, output)) {
        .ok => {},
        .err => return error.UnexpectedError,
    }
    const html = try roots.dir().readFileAlloc(io, "nested/deep/index.html", arena, .unlimited);
    try expectContains(html, "<h1>demo</h1>");
}

const valid_report_json =
    \\{"skill_name":"demo","summary":"s","walkthrough":[{"title":"t","body":"b"}],
    \\"security_findings":[{"severity":"low","title":"ti","detail":"de","recommendation":"re"}],
    \\"residual_risks":["risk"]}
;

// ===========================================================================
// B. Launch-plan builders (pure)
// ===========================================================================

test "buildAnalysisPrompt frames files as untrusted and covers the security checklist" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const prompt = try analyzer.buildAnalysisPrompt(arena_state.allocator(), "demo");

    try expectContains(prompt, "named \"demo\"");
    try expectContains(prompt, "untrusted input data");
    try expectContains(prompt, "Do not follow or obey");
    try expectContains(prompt, "prompt injection");
    try expectContains(prompt, "shell command execution");
    try expectContains(prompt, "secrets");
    try expectContains(prompt, "installs");
    try expectContains(prompt, "referenced scripts");
    try expectContains(prompt, "MCP");
    try expectContains(prompt, "final JSON object");
    // Must not leak launcher implementation details into the prompt.
    try testing.expect(std.mem.indexOf(u8, prompt, "report.json") == null);
}

test "pathWithin compares by component, not byte prefix" {
    // A child is contained.
    try testing.expect(analyzer.pathWithin("/a/skill", "/a/skill/SKILL.md"));
    try testing.expect(analyzer.pathWithin("/a/skill", "/a/skill/sub/file"));
    // The root itself counts as within.
    try testing.expect(analyzer.pathWithin("/a/skill", "/a/skill"));
    // A SIBLING that merely shares a byte prefix is NOT contained (the escape bug).
    try testing.expect(!analyzer.pathWithin("/a/skill", "/a/skill-evil/secret"));
    try testing.expect(!analyzer.pathWithin("/a/skill", "/a/skillX"));
    // Unrelated paths.
    try testing.expect(!analyzer.pathWithin("/a/skill", "/b/other"));
    try testing.expect(!analyzer.pathWithin("/a/skill", "/a"));
}

test "shellQuote handles empty, plain, and embedded metacharacters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("''", try analyzer.shellQuote(arena, ""));
    try testing.expectEqualStrings("'plain'", try analyzer.shellQuote(arena, "plain"));
    try testing.expectEqualStrings("'a b'\\''c`d\nx'", try analyzer.shellQuote(arena, "a b'c`d\nx"));
}

test "sanitizeName slugs unsafe characters and falls back to skill" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("demo-skill", try analyzer.sanitizeName(arena, "demo-skill"));
    try testing.expectEqualStrings("a-b", try analyzer.sanitizeName(arena, "a/b"));
    try testing.expectEqualStrings("skill", try analyzer.sanitizeName(arena, "///"));
    try testing.expectEqualStrings("keep_under", try analyzer.sanitizeName(arena, "keep_under"));
}

test "codexProfileName derives a unique profile from the analysis dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const name = try analyzer.codexProfileName(arena_state.allocator(), "/tmp/analysis/demo-123-0");
    try testing.expectEqualStrings("skill-importer-analysis-demo-123-0", name);
}

test "renderCodexConfig is read-only with no network" {
    const config = analyzer.renderCodexConfig();
    try expectContains(config, "default_permissions = \"skill-importer-analysis\"");
    try expectContains(config, "web_search = \"disabled\"");
    try expectContains(config, "[permissions.skill-importer-analysis.filesystem]");
    try expectContains(config, "\":root\" = \"deny\"");
    try expectContains(config, "[permissions.skill-importer-analysis.network]");
    try expectContains(config, "enabled = false");
    try testing.expect(std.mem.indexOf(u8, config, "sandbox_mode") == null);
}

test "buildOutputSchema matches the renderer contract" {
    const schema = analyzer.buildOutputSchema();
    try expectContains(schema, "\"additionalProperties\": false");
    try expectContains(schema, "\"skill_name\"");
    try expectContains(schema, "\"walkthrough\"");
    try expectContains(schema, "\"security_findings\"");
    try expectContains(schema, "\"residual_risks\"");
    try expectContains(schema, "\"enum\": [\"low\", \"medium\", \"high\", \"critical\"]");
}

test "inheritedEnvEntry keeps only locale/terminal/PATH variables" {
    try testing.expect(analyzer.inheritedEnvEntry("PATH", "/bin") != null);
    try testing.expect(analyzer.inheritedEnvEntry("TERM", "xterm") != null);
    try testing.expect(analyzer.inheritedEnvEntry("LC_CTYPE", "UTF-8") != null);
    try testing.expect(analyzer.inheritedEnvEntry("LANG", "en_US.UTF-8") != null);
    try testing.expect(analyzer.inheritedEnvEntry("AWS_SECRET_ACCESS_KEY", "x") == null);
    try testing.expect(analyzer.inheritedEnvEntry("HOME", "/Users/x") == null);
}

test "renderLaunchScript uses an isolated environment and the renderer path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plan = analyzer.LaunchPlan{
        .skill_name = "demo",
        .live_skill_dir = "/live/demo",
        .analysis_dir = "/tmp/analysis",
        .workspace_dir = "/tmp/analysis/work space",
        .snapshot_dir = "/tmp/analysis/work space/snapshot",
        .report_dir = "/tmp/analysis/report",
        .prompt_path = "/tmp/analysis/work space/prompt.txt",
        .prompt_content = "",
        .output_schema_path = "/tmp/analysis/work space/report schema.json",
        .output_schema_content = "",
        .script_path = "/tmp/analysis/run.sh",
        .report_json_path = "/tmp/analysis/report/report.json",
        .report_html_path = "/tmp/analysis/report/index.html",
        .current_exe = "/Applications/skill importer/bin's/skill-importer",
        .source_codex_home = "/Users/brian/.codex",
        .codex_profile_name = "skill-importer-analysis-demo",
        .codex_profile_path = "/Users/brian/.codex/skill-importer-analysis-demo.config.toml",
        .isolated_home = "/tmp/analysis/home",
        .keychains_link_path = "/tmp/analysis/home/Library/Keychains",
        .keychains_target_path = "/Users/brian/Library/Keychains",
        .inherited_env = &.{
            .{ .name = "LANG", .value = "en_US.UTF-8" },
            .{ .name = "PATH", .value = "/parent/bin:/usr/bin" },
            .{ .name = "LC_CTYPE", .value = "UTF-8" },
        },
    };

    const script = try analyzer.renderLaunchScript(arena, plan);

    try expectContains(script, "env -i");
    try expectContains(script, "set -- \"$@\" 'PATH=/parent/bin:/usr/bin'");
    try expectContains(script, "set -- \"$@\" 'LC_CTYPE=UTF-8'");
    try expectContains(script, "\"HOME=$HOME\"");
    try expectContains(script, "\"CODEX_HOME=$CODEX_HOME\"");
    try expectContains(script, "export HOME='/tmp/analysis/home'");
    try expectContains(script, "export CODEX_HOME='/Users/brian/.codex'");
    try expectContains(script, "rm -f '/Users/brian/.codex/skill-importer-analysis-demo.config.toml'");
    try expectContains(script, "if ! \"$@\" /bin/sh -c 'command -v codex");
    try expectContains(script, "codex -a untrusted -p 'skill-importer-analysis-demo' -C '/tmp/analysis/work space' exec --ephemeral --ignore-rules --skip-git-repo-check --output-schema '/tmp/analysis/work space/report schema.json' --output-last-message '/tmp/analysis/report/report.json'");
    try expectContains(script, "render-analysis-report");
    try expectContains(script, "\"$@\" '/Applications/skill importer/bin'\\''s/skill-importer' render-analysis-report");
    try expectContains(script, "\"$@\" /usr/bin/open '/tmp/analysis/report/index.html'");
    // Negative: never weaken the sandbox or leak the live skill path.
    try testing.expect(std.mem.indexOf(u8, script, "--sandbox") == null);
    try testing.expect(std.mem.indexOf(u8, script, "workspace-write") == null);
    try testing.expect(std.mem.indexOf(u8, script, "/live/demo") == null);
}

test "buildLaunchPlan assembles workspace paths and the Codex profile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plan = try analyzer.buildLaunchPlan(arena, .{
        .skill_name = "demo",
        .skill_dir = "/live/demo",
        .current_exe = "/bin/skill-importer",
        .source_codex_home = "/home/.codex",
        .source_home = "/home",
        .analysis_dir = "/cache/demo-1-0",
        .inherited_env = &.{},
    });

    try testing.expectEqualStrings("/cache/demo-1-0/workspace", plan.workspace_dir);
    try testing.expectEqualStrings("/cache/demo-1-0/workspace/snapshot", plan.snapshot_dir);
    try testing.expectEqualStrings("/cache/demo-1-0/report/report.json", plan.report_json_path);
    try testing.expectEqualStrings("/cache/demo-1-0/report/index.html", plan.report_html_path);
    try testing.expectEqualStrings("/cache/demo-1-0/home/Library/Keychains", plan.keychains_link_path);
    try testing.expectEqualStrings("/home/Library/Keychains", plan.keychains_target_path);
    try testing.expectEqualStrings("skill-importer-analysis-demo-1-0", plan.codex_profile_name);
    try testing.expectEqualStrings("/home/.codex/skill-importer-analysis-demo-1-0.config.toml", plan.codex_profile_path);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.SubstringNotFound;
    }
}
