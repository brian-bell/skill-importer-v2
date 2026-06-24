//! End-to-end CLI integration tests (cli-clean-room-spec.md "Output Contract"
//! + acceptance bullets 12-13): exec the BUILT binary and assert exit codes,
//! UTF-8 + trailing-newline JSON, json/text parity, and actionable stderr.
//!
//! SAFETY (CLAUDE.md hard rule + task note): every invocation passes explicit
//! DISPOSABLE roots from `TmpRoots`; no test ever touches a real user root. The
//! child also runs with an environment that has NO `HOME` (and no
//! `AGENT_SKILLS_REPO`), proving "all roots explicit must not require HOME"
//! (spec "Root Resolution") AND guaranteeing that even a resolution bug could
//! not fall back to a real `$HOME` default.

const std = @import("std");
const testing = std.testing;

const tu = @import("testutil.zig");
const build_options = @import("build_options");

const io = std.testing.io;

/// Result of one CLI invocation.
const Run = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *Run, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Exec the built binary with `argv` (NOT including program name). The child
/// gets an EMPTY environment (no HOME), so any default-root resolution would
/// fail loudly rather than silently reaching a real user root.
fn runCli(gpa: std.mem.Allocator, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, build_options.exe_path);
    try full.appendSlice(gpa, argv);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    // Intentionally empty: no HOME, no AGENT_SKILLS_REPO.

    const res = try std.process.run(gpa, io, .{
        .argv = full.items,
        .environ_map = &env,
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

/// Build the four explicit `--*-root` global options pointing at the temp tree.
fn rootArgs(arena: std.mem.Allocator, tr: *tu.TmpRoots) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, &.{
        "--canonical-root",   tr.canonical,
        "--imports-root",     tr.imports,
        "--claude-code-root", tr.claude,
        "--codex-root",       tr.codex,
    });
    return list.toOwnedSlice(arena);
}

fn concat(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, a);
    try list.appendSlice(arena, b);
    return list.toOwnedSlice(arena);
}

// spec "Output Contract": successful JSON output must be UTF-8 and terminated by
// a newline. spec "list": missing roots produce an empty inventory (exit 0).
test "list json: empty inventory is valid UTF-8 with trailing newline, exit 0" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{"list"}));
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.unicode.utf8ValidateSlice(run.stdout));
    try testing.expect(run.stdout.len > 0 and run.stdout[run.stdout.len - 1] == '\n');
    // Exactly one trailing newline.
    try testing.expect(run.stdout[run.stdout.len - 2] != '\n');
    // Valid JSON object.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

// spec "Output Contract": text output is human-only but shares exit status.
test "list text: empty inventory exits 0" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const argv = try concat(arena, try rootArgs(arena, &tr), &.{"list"});
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);
}

// spec "Root Resolution": "Explicitly providing all roots must not require
// HOME." The child has NO HOME yet `list` with all roots explicit must succeed.
test "all roots explicit succeeds with no HOME in environment" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const argv = try concat(arena, try rootArgs(arena, &tr), &.{"list"});
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);
}

// spec "Root Resolution": "If a default requires HOME, HOME must be set." With
// no HOME and NOT all roots overridden, a default needs HOME and the command
// fails non-zero with actionable stderr.
test "missing HOME with a needed default fails non-zero with stderr" {
    const gpa = testing.allocator;
    var run = try runCli(gpa, &.{ "--canonical-root", "/x", "--imports-root", "/y", "--codex-root", "/z", "list" });
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "HOME") != null);
}

// spec "import path" + "Import Result": a local markdown file import yields the
// import-result JSON (valid UTF-8, trailing newline), exit 0.
test "import path json: valid UTF-8 + trailing newline, exit 0" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    // Write a source SKILL.md into the temp tree (disposable).
    try tr.dir().createDirPath(io, "src");
    {
        const f = try tr.dir().createFile(io, "src/SKILL.md", .{});
        defer f.close(io);
        var wbuf: [256]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        try fw.interface.writeAll("---\nname: pathskill\ndescription: from a file\n---\nbody\n");
        try fw.interface.flush();
    }
    const src_md = try std.fs.path.join(arena, &.{ tr.base, "src/SKILL.md" });

    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "import", "path", "--path", src_md }));
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.unicode.utf8ValidateSlice(run.stdout));
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("pathskill", parsed.value.object.get("skill_name").?.string);
}

// spec "enable": unknown skills fail. Every failing command returns non-zero
// and writes actionable stderr naming the skill (spec "Output Contract").
test "enable unknown skill: exit 1 with skill-named stderr" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "enable", "--skill", "ghost", "--agent", "codex" });
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "ghost") != null);
}

// spec "Output Contract": json vs text behavior parity — the same failure exits
// non-zero in BOTH formats. (A failing enable on an unknown skill.)
test "json and text failures both exit non-zero" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const base = try concat(arena, try rootArgs(arena, &tr), &.{ "enable", "--skill", "ghost", "--agent", "codex" });
    var text_run = try runCli(gpa, base);
    defer text_run.deinit(gpa);
    const json_argv = try concat(arena, &.{ "--format", "json" }, base);
    var json_run = try runCli(gpa, json_argv);
    defer json_run.deinit(gpa);

    try testing.expectEqual(@as(u8, 1), text_run.code);
    try testing.expectEqual(@as(u8, 1), json_run.code);
}

// spec "tui" + zig-clean-room-cli "Decisions locked in": tui rejects
// `--format json` (exit 1).
test "tui rejects --format json with non-zero exit" {
    const gpa = testing.allocator;
    var run = try runCli(gpa, &.{ "--format", "json", "tui" });
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "json") != null);
}

// spec "tui": deferred — prints "TUI not implemented" and exits 1.
test "tui text prints not implemented and exits 1" {
    const gpa = testing.allocator;
    var run = try runCli(gpa, &.{"tui"});
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "TUI not implemented") != null);
}

// spec "Output Contract" exit codes: a command parse error exits 1 with stderr.
test "parse error: unknown command exits 1 with stderr" {
    const gpa = testing.allocator;
    var run = try runCli(gpa, &.{"frobnicate"});
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
}

// spec "import path": missing required --path is a parse error (exit 1).
test "parse error: import path without --path exits 1" {
    const gpa = testing.allocator;
    var run = try runCli(gpa, &.{ "import", "path" });
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
}

// End-to-end: import (stdin markdown) -> promote -> enable -> list, all JSON,
// exercising the full wiring including stdin reading and the real clock. stdin
// is fed via `/bin/sh -c` since std.process.run ignores stdin. The whole chain
// runs against disposable roots with no HOME.
test "end-to-end markdown import, promote, enable, list (json)" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const roots_str = try std.fmt.allocPrint(arena, "--canonical-root {s} --imports-root {s} --claude-code-root {s} --codex-root {s}", .{ tr.canonical, tr.imports, tr.claude, tr.codex });
    const bin = build_options.exe_path;

    // import markdown from stdin
    {
        const script = try std.fmt.allocPrint(arena, "printf '%s\\n' '---' 'name: e2e' 'description: end to end' '---' 'body' | '{s}' --format json {s} import markdown", .{ bin, roots_str });
        var run = try runShell(gpa, script);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
        try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
    }
    // promote
    {
        const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "promote", "--skill", "e2e" }));
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
    }
    // enable for both agents
    {
        const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "enable", "--skill", "e2e", "--agent", "claude-code", "--agent", "codex" }));
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
    }
    // list shows the promoted + enabled skill
    {
        const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{"list"}));
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
        defer parsed.deinit();
        const skills = parsed.value.object.get("skills").?.array;
        try testing.expectEqual(@as(usize, 1), skills.items.len);
        const s0 = skills.items[0].object;
        try testing.expectEqualStrings("e2e", s0.get("name").?.string);
        try testing.expect(s0.get("promoted").?.bool);
        try testing.expect(s0.get("enablement").?.object.get("claude_code").?.bool);
        try testing.expect(s0.get("enablement").?.object.get("codex").?.bool);
    }
}

/// Run a shell script string via `/bin/sh -c` with an empty environment (no
/// HOME). Used to feed stdin, which `std.process.run` otherwise ignores.
fn runShell(gpa: std.mem.Allocator, script: []const u8) !Run {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .environ_map = &env,
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

/// Exec the built binary with a `PATH` in the environment so the child can spawn
/// `git` (needed only by `import repository` -> `git.RealProvider`). Still NO
/// HOME, so root-default resolution would fail loudly rather than touch a real
/// user root (spec "Root Resolution"; CLAUDE.md safety rule).
fn runCliWithPath(gpa: std.mem.Allocator, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, build_options.exe_path);
    try full.appendSlice(gpa, argv);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    // `git` lives on PATH; provide it (and nothing else — still no HOME).
    try env.put("PATH", "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin");

    const res = try std.process.run(gpa, io, .{
        .argv = full.items,
        .environ_map = &env,
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

/// Create a local git repository under the disposable temp tree at `rel_dir`,
/// seeded with each `(rel, name, desc)` skill as `<rel>/SKILL.md`, and return its
/// absolute path. The repo is real (so `git.RealProvider`'s `git clone` drives
/// production wiring) but lives entirely inside `tr`'s tree, deleted on deinit.
fn makeGitRepo(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    tr: *tu.TmpRoots,
    rel_dir: []const u8,
    skills: []const [3][]const u8,
) ![]const u8 {
    try tr.dir().createDirPath(io, rel_dir);
    const repo_abs = try std.fs.path.join(arena, &.{ tr.base, rel_dir });

    for (skills) |sk| {
        const sub = try std.fs.path.join(arena, &.{ rel_dir, sk[0] });
        try tr.dir().createDirPath(io, sub);
        const md_path = try std.fs.path.join(arena, &.{ sub, "SKILL.md" });
        const body = try std.fmt.allocPrint(arena, "---\nname: {s}\ndescription: {s}\n---\nbody\n", .{ sk[1], sk[2] });
        try tr.dir().writeFile(io, .{ .sub_path = md_path, .data = body });
    }

    // Initialize the repo and commit. Run with a real PATH so `git` resolves;
    // pin identity so commit succeeds without global config.
    const script = try std.fmt.allocPrint(
        arena,
        "cd '{s}' && git init -q && git config user.email t@t.t && git config user.name t && git add -A && git commit -qm init",
        .{repo_abs},
    );
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin");
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .environ_map = &env,
    });
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    switch (res.term) {
        .exited => |c| if (c != 0) return error.GitInitFailed,
        else => return error.GitInitFailed,
    }
    return repo_abs;
}

// === Phase 6 dispatch-arm coverage (adversarial review) =====================
// The dispatch arms for `disable`, `unpromote`, `delete`, `import url`, and
// `import repository` were wired only in main.zig and exercised by NO test; a
// copy-paste error (wrong renderer/context/provider) would compile green and
// ship broken. These integration tests exec the built binary for each arm so a
// wiring regression fails. (spec "Output Contract"; "Commands: disable,
// unpromote, delete, import url, import repository".)

// spec "disable": removing an enabled agent entry succeeds (exit 0) and emits a
// skill-operation result. Drives the `disable` dispatch arm + opsCtx + the
// writeSkillOperationResult renderer end-to-end.
test "disable json: removes a managed symlink, exit 0 with operation JSON" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    // Build a promoted, enabled skill via the real CLI (promote then enable),
    // so disable has a managed symlink to remove.
    {
        const script = try std.fmt.allocPrint(
            arena,
            "printf '%s\\n' '---' 'name: dis' 'description: d' '---' 'body' | '{s}' --format json --canonical-root {s} --imports-root {s} --claude-code-root {s} --codex-root {s} import markdown",
            .{ build_options.exe_path, tr.canonical, tr.imports, tr.claude, tr.codex },
        );
        var run = try runShell(gpa, script);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
    }
    {
        const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "promote", "--skill", "dis" });
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
    }
    {
        const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "enable", "--skill", "dis", "--agent", "codex" });
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
    }

    // Now disable for codex (json): exit 0, valid UTF-8, one trailing newline.
    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "disable", "--skill", "dis", "--agent", "codex" }));
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.unicode.utf8ValidateSlice(run.stdout));
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
    try testing.expect(run.stdout[run.stdout.len - 2] != '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("dis", parsed.value.object.get("skill_name").?.string);
    try testing.expect(parsed.value.object.get("actions").? == .array);
}

// spec "disable": unknown skill fails (exit 1) with skill-named stderr — proves
// the disable arm routes failures through `fail`, not a crash.
test "disable unknown skill: exit 1 with skill-named stderr" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "disable", "--skill", "ghost", "--agent", "codex" });
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "ghost") != null);
}

// spec "unpromote": unpromoting a promoted import succeeds (exit 0) and emits a
// skill-operation result. Drives the `unpromote` dispatch arm + renderer.
test "unpromote json: exit 0 with operation JSON" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    {
        const script = try std.fmt.allocPrint(
            arena,
            "printf '%s\\n' '---' 'name: unp' 'description: u' '---' 'body' | '{s}' --format json --canonical-root {s} --imports-root {s} --claude-code-root {s} --codex-root {s} import markdown",
            .{ build_options.exe_path, tr.canonical, tr.imports, tr.claude, tr.codex },
        );
        var run = try runShell(gpa, script);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
    }
    {
        const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "promote", "--skill", "unp" });
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
    }

    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "unpromote", "--skill", "unp" }));
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.unicode.utf8ValidateSlice(run.stdout));
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
    try testing.expect(run.stdout[run.stdout.len - 2] != '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("unp", parsed.value.object.get("skill_name").?.string);
}

// spec "delete": deleting an unpromoted import succeeds (exit 0) and emits a
// skill-operation result. Drives the `delete` dispatch arm + renderer.
test "delete json: removes an unpromoted import, exit 0 with operation JSON" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    {
        const script = try std.fmt.allocPrint(
            arena,
            "printf '%s\\n' '---' 'name: del' 'description: d' '---' 'body' | '{s}' --format json --canonical-root {s} --imports-root {s} --claude-code-root {s} --codex-root {s} import markdown",
            .{ build_options.exe_path, tr.canonical, tr.imports, tr.claude, tr.codex },
        );
        var run = try runShell(gpa, script);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
    }

    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "delete", "--skill", "del" }));
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.unicode.utf8ValidateSlice(run.stdout));
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
    try testing.expect(run.stdout[run.stdout.len - 2] != '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("del", parsed.value.object.get("skill_name").?.string);
}

// spec "delete": deleting an unknown skill fails (exit 1) with stderr — proves
// the delete arm routes failures through `fail`.
test "delete unknown skill: exit 1 with stderr" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "delete", "--skill", "ghost" });
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "ghost") != null);
}

// spec "import url" failure modes: a connection-refused URL drives the
// `net.RealFetcher` injection (the only place it is constructed in production)
// and the fetch-failure path -> exit 1 with actionable stderr naming the URL.
test "import url: unreachable URL drives RealFetcher, exit 1 with url-named stderr" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    // Port 1 on loopback refuses connections fast; no real network is touched.
    const bad_url = "http://127.0.0.1:1/SKILL.md";
    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "import", "url", "--url", bad_url });
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
    try testing.expect(std.mem.indexOf(u8, run.stderr, bad_url) != null);
}

// spec "import repository": "Return a selection result when more than one valid
// skill exists" — this is a SUCCESS (exit 0), not an error. Drives the
// `import repository` arm, `git.RealProvider` injection, and the selection JSON
// branch of writeRepositoryImportResult/textRepository.
test "import repository selection: multiple skills, no --select -> exit 0 kind=selection" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const repo = try makeGitRepo(gpa, arena, &tr, "repo", &.{
        .{ "skill-a", "alpha", "Alpha skill." },
        .{ "skill-b", "beta", "Beta skill." },
    });

    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "import", "repository", "--repository", repo }));
    var run = try runCliWithPath(gpa, argv);
    defer run.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.unicode.utf8ValidateSlice(run.stdout));
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
    try testing.expect(run.stdout[run.stdout.len - 2] != '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("selection", parsed.value.object.get("kind").?.string);
    const skills = parsed.value.object.get("skills").?.array;
    try testing.expectEqual(@as(usize, 2), skills.items.len);
}

// spec "import repository": text format of the selection branch must not crash
// (main.zig textRepository selection arm) and shares exit 0 with json.
test "import repository selection text: exit 0, lists skills" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const repo = try makeGitRepo(gpa, arena, &tr, "repo", &.{
        .{ "skill-a", "alpha", "Alpha skill." },
        .{ "skill-b", "beta", "Beta skill." },
    });

    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "import", "repository", "--repository", repo });
    var run = try runCliWithPath(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stdout, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, run.stdout, "beta") != null);
}

// spec "import repository": single valid skill, no --select -> import it
// (kind=imported), exit 0. Drives the single-import wiring + RealProvider.
test "import repository single: one skill -> exit 0 kind=imported" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const repo = try makeGitRepo(gpa, arena, &tr, "repo", &.{
        .{ "only", "solo", "The only skill." },
    });

    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "import", "repository", "--repository", repo }));
    var run = try runCliWithPath(gpa, argv);
    defer run.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("imported", parsed.value.object.get("kind").?.string);
    try testing.expectEqualStrings("solo", parsed.value.object.get("skill_name").?.string);
}

// spec "import repository" batch: two skills WITH `--select` for both ->
// imported_batch (exit 0). Drives the batch-import wiring + RealProvider + the
// imported_batch JSON branch.
test "import repository batch: --select two skills -> exit 0 kind=imported_batch" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const repo = try makeGitRepo(gpa, arena, &tr, "repo", &.{
        .{ "skill-a", "alpha", "Alpha skill." },
        .{ "skill-b", "beta", "Beta skill." },
    });

    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "import", "repository", "--repository", repo, "--select", "skill-a", "--select", "skill-b" }));
    var run = try runCliWithPath(gpa, argv);
    defer run.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("imported_batch", parsed.value.object.get("kind").?.string);
    const imports = parsed.value.object.get("imports").?.array;
    try testing.expectEqual(@as(usize, 2), imports.items.len);
}

// spec "import repository": a non-existent local repository fails (exit 1) with
// stderr naming the repository — proves the repository arm routes RealProvider
// failures through `fail` rather than crashing or exiting 0.
test "import repository: bad repository -> exit 1 with repository-named stderr" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const bogus = try std.fs.path.join(arena, &.{ tr.base, "does-not-exist-repo" });
    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "import", "repository", "--repository", bogus });
    var run = try runCliWithPath(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
    try testing.expect(std.mem.indexOf(u8, run.stderr, bogus) != null);
}

// === H8 hardening: gaps flagged by adversarial review ========================

/// Return true if `<imports-root>/<name>` exists as a directory entry. Used to
/// prove selection results write NO storage and that delete removes storage.
/// SAFETY: only ever called with the disposable `tr.imports` path.
fn importDirExists(arena: std.mem.Allocator, tr: *tu.TmpRoots, name: []const u8) !bool {
    const rel = try std.fs.path.join(arena, &.{ "imports", name });
    tr.dir().access(io, rel, .{}) catch return false;
    return true;
}

// spec "import repository": a selection result is returned "without writing
// storage". The existing selection test asserts kind=selection + exit 0 but NOT
// the no-storage guarantee — a regression that eagerly imported the first skill
// would still pass it. This locks the spec's "without writing storage" clause by
// asserting the imports root contains neither candidate skill after a selection.
test "import repository selection: writes NO storage to imports root" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const repo = try makeGitRepo(gpa, arena, &tr, "repo", &.{
        .{ "skill-a", "alpha", "Alpha skill." },
        .{ "skill-b", "beta", "Beta skill." },
    });

    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "import", "repository", "--repository", repo }));
    var run = try runCliWithPath(gpa, argv);
    defer run.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), run.code);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("selection", parsed.value.object.get("kind").?.string);

    // No storage was written for either candidate (spec: selection returns
    // "without writing storage").
    try testing.expect(!try importDirExists(arena, &tr, "alpha"));
    try testing.expect(!try importDirExists(arena, &tr, "beta"));
}

// spec "Output Contract" exit codes: "Command parse error ... return a non-zero
// exit code." Existing parse-error tests only assert `skill-importer:` is in
// stderr, which any error kind satisfies. This pins the failure to the
// PARSE-ERROR kind specifically: `kindMessage(.parse_error)` is the unique
// string "invalid command line" (main.zig), so its presence proves the error was
// routed as a parse error and not, e.g., misclassified as a discovery/io error.
test "parse error: unknown command stderr is specifically the parse-error kind" {
    const gpa = testing.allocator;
    var run = try runCli(gpa, &.{"frobnicate"});
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "invalid command line") != null);
}

// Same, for a missing required option: `import path` without `--path` must be a
// PARSE error (the unique "invalid command line" message), not a downstream
// import/io error.
test "parse error: missing --path is specifically the parse-error kind" {
    const gpa = testing.allocator;
    var run = try runCli(gpa, &.{ "import", "path" });
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "invalid command line") != null);
}

// spec "Output Contract": text output is human-only but must share exit status
// and not crash. The `textImport` renderer (import success TEXT) was never
// exercised end-to-end — only JSON import and text *selection* were. This drives
// `textImport` through the built binary: a successful `import path` in text
// format must exit 0 and print the skill name without crashing.
test "import path text: textImport renderer runs without crashing, exit 0" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    try tr.dir().createDirPath(io, "src");
    {
        const f = try tr.dir().createFile(io, "src/SKILL.md", .{});
        defer f.close(io);
        var wbuf: [256]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        try fw.interface.writeAll("---\nname: txtimp\ndescription: text import\n---\nbody\n");
        try fw.interface.flush();
    }
    const src_md = try std.fs.path.join(arena, &.{ tr.base, "src/SKILL.md" });

    // No --format: defaults to text (spec: Format defaults to text).
    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "import", "path", "--path", src_md });
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stdout, "txtimp") != null);
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
}

// spec "Output Contract": the `textOperation` renderer (enable/disable/promote/
// unpromote/delete success in TEXT) was never driven e2e. A successful `promote`
// in text format must run `textOperation` without crashing and exit 0.
test "promote text: textOperation renderer runs without crashing, exit 0" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    {
        const script = try std.fmt.allocPrint(
            arena,
            "printf '%s\\n' '---' 'name: txtop' 'description: o' '---' 'body' | '{s}' --canonical-root {s} --imports-root {s} --claude-code-root {s} --codex-root {s} import markdown",
            .{ build_options.exe_path, tr.canonical, tr.imports, tr.claude, tr.codex },
        );
        var run = try runShell(gpa, script);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
    }

    // promote in TEXT format (no --format).
    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "promote", "--skill", "txtop" });
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stdout, "txtop") != null);
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
}

// spec "import repository": the `textRepository` `.imported` branch (single
// repository import, TEXT) was never driven e2e — only the selection branch was.
// A single-skill repository imported in text format must run `textRepository`
// without crashing and exit 0.
test "import repository single text: textRepository imported branch, exit 0" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const repo = try makeGitRepo(gpa, arena, &tr, "repo", &.{
        .{ "only", "solotext", "The only skill." },
    });

    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "import", "repository", "--repository", repo });
    var run = try runCliWithPath(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stdout, "solotext") != null);
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
}

// spec "Output Contract": "Successful JSON output must be ... terminated by a
// newline." main.zig renders stdout through a fixed 4096-byte buffer and relies
// on a single `flush()` before exit (Writergate flush-before-exit). If the
// buffer ever drained mid-write without a final flush, an output LARGER than the
// buffer could be truncated or double-/un-terminated. This builds an inventory
// whose `list --format json` exceeds 4096 bytes (many imported skills with long
// descriptions) and asserts the output is valid JSON ending in EXACTLY one
// trailing newline — proving flush correctness across the buffer boundary.
test "list json larger than 4096-byte stdout buffer ends in exactly one newline" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    // Seed enough canonical skills (each with a long description) that the
    // pretty-printed JSON inventory is well over 4096 bytes.
    var fx = tu.Fixtures.init(&tr);
    const long_desc = "x" ** 200;
    var n: usize = 0;
    while (n < 40) : (n += 1) {
        const dir_name = try std.fmt.allocPrint(arena, "canonical/skill-{d:0>3}", .{n});
        const skill_name = try std.fmt.allocPrint(arena, "skill-{d:0>3}", .{n});
        try fx.writeSkill(dir_name, skill_name, long_desc);
    }

    const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{"list"}));
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), run.code);
    // The output must be larger than the 4096-byte stdout buffer for this test
    // to actually exercise a buffer-spanning flush.
    try testing.expect(run.stdout.len > 4096);
    try testing.expect(std.unicode.utf8ValidateSlice(run.stdout));
    // Exactly one trailing newline (flush correctness across the boundary).
    try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
    try testing.expect(run.stdout[run.stdout.len - 2] != '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, run.stdout, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 40), parsed.value.object.get("skills").?.array.items.len);
}

// spec "Commands": the full managed-skill lifecycle, end-to-end through the built
// binary, in ONE test: import (stdin markdown) -> promote -> enable -> disable ->
// unpromote -> delete. Each mutating step asserts exit 0, valid UTF-8 JSON with
// EXACTLY one trailing newline, and the correct renderer wiring (skill_name +
// actions array for operations). The final `delete` is asserted to actually
// remove `<imports-root>/<skill>` (spec "delete": "removes
// <imports-root>/<skill-name>"). No real user root is touched (disposable roots,
// no HOME).
test "end-to-end lifecycle: import->promote->enable->disable->unpromote->delete (json)" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    // Asserts one JSON operation result: exit 0, UTF-8, exactly one trailing
    // newline, skill_name matches, actions is an array.
    const Checker = struct {
        fn op(g: std.mem.Allocator, run: *Run, name: []const u8) !void {
            try testing.expectEqual(@as(u8, 0), run.code);
            try testing.expect(std.unicode.utf8ValidateSlice(run.stdout));
            try testing.expect(run.stdout.len > 0 and run.stdout[run.stdout.len - 1] == '\n');
            try testing.expect(run.stdout[run.stdout.len - 2] != '\n');
            const parsed = try std.json.parseFromSlice(std.json.Value, g, run.stdout, .{});
            defer parsed.deinit();
            try testing.expectEqualStrings(name, parsed.value.object.get("skill_name").?.string);
            try testing.expect(parsed.value.object.get("actions").? == .array);
        }
    };

    // 1. import markdown (stdin) — exit 0, trailing newline.
    {
        const script = try std.fmt.allocPrint(
            arena,
            "printf '%s\\n' '---' 'name: life' 'description: lifecycle' '---' 'body' | '{s}' --format json --canonical-root {s} --imports-root {s} --claude-code-root {s} --codex-root {s} import markdown",
            .{ build_options.exe_path, tr.canonical, tr.imports, tr.claude, tr.codex },
        );
        var run = try runShell(gpa, script);
        defer run.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), run.code);
        try testing.expect(run.stdout[run.stdout.len - 1] == '\n');
        try testing.expect(run.stdout[run.stdout.len - 2] != '\n');
        try testing.expect(try importDirExists(arena, &tr, "life"));
    }
    // 2. promote
    {
        const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "promote", "--skill", "life" }));
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try Checker.op(gpa, &run, "life");
    }
    // 3. enable (both agents)
    {
        const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "enable", "--skill", "life", "--agent", "claude-code", "--agent", "codex" }));
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try Checker.op(gpa, &run, "life");
    }
    // 4. disable (both agents)
    {
        const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "disable", "--skill", "life", "--agent", "claude-code", "--agent", "codex" }));
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try Checker.op(gpa, &run, "life");
    }
    // 5. unpromote (now no managed symlinks remain; removes canonical copy)
    {
        const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "unpromote", "--skill", "life" }));
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try Checker.op(gpa, &run, "life");
    }
    // 6. delete — succeeds (unpromoted, not enabled) and removes the import dir.
    {
        const argv = try concat(arena, &.{ "--format", "json" }, try concat(arena, try rootArgs(arena, &tr), &.{ "delete", "--skill", "life" }));
        var run = try runCli(gpa, argv);
        defer run.deinit(gpa);
        try Checker.op(gpa, &run, "life");
        // spec "delete": successful deletion removes <imports-root>/<skill-name>.
        try testing.expect(!try importDirExists(arena, &tr, "life"));
    }
}

// Non-spec analyzer: `render-analysis-report` reads a report JSON and writes HTML.
// Needs NO roots and NO HOME, so it runs under the empty-env harness unchanged.
test "render-analysis-report writes HTML from a valid report, exit 0" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const report =
        \\{"skill_name":"demo","summary":"s","walkthrough":[{"title":"t","body":"b"}],
        \\"security_findings":[{"severity":"high","title":"ti","detail":"de","recommendation":"re"}],
        \\"residual_risks":["risk"]}
    ;
    try tr.dir().writeFile(io, .{ .sub_path = "report.json", .data = report });
    const input = try std.fs.path.join(arena, &.{ tr.base, "report.json" });
    const output = try std.fs.path.join(arena, &.{ tr.base, "index.html" });

    var run = try runCli(gpa, &.{ "render-analysis-report", "--input", input, "--output", output });
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), run.code);

    const html = try tr.dir().readFileAlloc(io, "index.html", arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, html, "<h1>demo</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<div class=\"severity\">high</div>") != null);
}

// Non-spec analyzer: malformed report JSON exits 1 with actionable stderr.
test "render-analysis-report with malformed JSON exits 1 with stderr" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    try tr.dir().writeFile(io, .{ .sub_path = "bad.json", .data = "{ not json" });
    const input = try std.fs.path.join(arena, &.{ tr.base, "bad.json" });
    const output = try std.fs.path.join(arena, &.{ tr.base, "out.html" });

    var run = try runCli(gpa, &.{ "render-analysis-report", "--input", input, "--output", output });
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "malformed") != null);
}

// Non-spec analyzer launch: `analyze` for a missing skill (or off macOS) exits 1
// with actionable stderr. Robust across platforms: on non-macOS it is the
// platform gate; on macOS with explicit empty roots the skill is unknown. Either
// way the launch never proceeds and the exit is non-zero.
test "analyze for an unknown skill exits 1 with stderr" {
    const gpa = testing.allocator;
    var tr = try tu.TmpRoots.init(gpa);
    defer tr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const arena = arena_s.allocator();

    const argv = try concat(arena, try rootArgs(arena, &tr), &.{ "analyze", "--skill", "nope" });
    var run = try runCli(gpa, argv);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), run.code);
    try testing.expect(std.mem.indexOf(u8, run.stderr, "skill-importer:") != null);
}
