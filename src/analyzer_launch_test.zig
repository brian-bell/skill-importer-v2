//! Tests for the Phase C skill-analysis launcher (analyzer_launch.zig). The
//! non-hermetic spawn (codex probe + Terminal launch) is replaced by a fake
//! `Spawner`; everything else — resolution, the macOS gate, the auth refusal,
//! workspace assembly, and the snapshot symlink-escape guard — runs for real
//! against a disposable temp tree (CLAUDE.md hard rule: never touch real roots,
//! and `home`/`codex_home` are temp subdirectories so the cache + profile writes
//! stay inside the sandbox).

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const al = @import("analyzer_launch.zig");
const fsutil = @import("fsutil.zig");
const testutil = @import("testutil.zig");

// --- fake spawner -----------------------------------------------------------

const FakeSpawner = struct {
    codex_ok: bool = true,
    launch_ok: bool = true,
    launched: ?[]const u8 = null,

    fn spawner(self: *FakeSpawner) al.Spawner {
        return .{ .ctx = self, .ensureCodexFn = ensureImpl, .launchFn = launchImpl };
    }
    fn ensureImpl(ctx: *anyopaque) bool {
        const self: *FakeSpawner = @ptrCast(@alignCast(ctx));
        return self.codex_ok;
    }
    fn launchImpl(ctx: *anyopaque, script_path: []const u8) bool {
        const self: *FakeSpawner = @ptrCast(@alignCast(ctx));
        self.launched = script_path;
        return self.launch_ok;
    }
};

// --- harness ----------------------------------------------------------------

const Harness = struct {
    roots: testutil.TmpRoots,
    arena_state: std.heap.ArenaAllocator,
    clock: testutil.FixedClock = .{ .value = 1000 },
    home: []const u8 = undefined,
    codex_home: []const u8 = undefined,

    fn init() !Harness {
        var roots = try testutil.TmpRoots.init(testing.allocator);
        errdefer roots.deinit();
        var h = Harness{
            .roots = roots,
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
        };
        h.home = try std.fs.path.join(h.arena(), &.{ h.roots.base, "home" });
        h.codex_home = try std.fs.path.join(h.arena(), &.{ h.roots.base, "codex_home" });
        return h;
    }
    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
        self.roots.deinit();
    }
    fn arena(self: *Harness) std.mem.Allocator {
        return self.arena_state.allocator();
    }
    fn context(self: *Harness, is_macos: bool) al.Context {
        return .{
            .arena = self.arena(),
            .io = io,
            .canonical_root = self.roots.canonical,
            .imports_root = self.roots.imports,
            .claude_code_root = self.roots.claude,
            .codex_root = self.roots.codex,
            .home = self.home,
            .codex_home = self.codex_home,
            .inherited_env = &.{},
            .current_exe = "/bin/skill-importer",
            .clock = self.clock.clock(),
            .is_macos = is_macos,
        };
    }
};

fn isKind(io_: std.Io, path: []const u8, want: fsutil.EntryKind) bool {
    return (fsutil.classify(io_, std.Io.Dir.cwd(), path) catch fsutil.EntryKind.missing) == want;
}

// --- tests ------------------------------------------------------------------

test "analyze: happy path assembles the workspace and launches" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");
    // A referenced support file must be snapshot-copied by content.
    try h.roots.dir().writeFile(io, .{ .sub_path = "imports/demo/helper.md", .data = "SUPPORT BODY" });

    var fake = FakeSpawner{};
    var c = h.context(true);
    const r = al.analyze(&c, fake.spawner(), "demo");

    const res = switch (r) {
        .ok => |v| v,
        .err => return error.UnexpectedError,
    };
    try testing.expect(std.mem.endsWith(u8, res.report_path, "/report/index.html"));

    // The launcher was invoked with the generated script.
    try testing.expect(fake.launched != null);
    try testing.expect(std.mem.endsWith(u8, fake.launched.?, "run-analysis.sh"));

    // Workspace artifacts exist on disk (derive analysis_dir from report_dir).
    const analysis_dir = std.fs.path.dirname(res.report_dir).?;
    const arena = h.arena();
    try testing.expect(isKind(io, try std.fs.path.join(arena, &.{ analysis_dir, "workspace", "snapshot", "SKILL.md" }), .file));
    // The support file is copied with its content intact.
    const helper = try std.fs.path.join(arena, &.{ analysis_dir, "workspace", "snapshot", "helper.md" });
    try testing.expect(isKind(io, helper, .file));
    const helper_bytes = try std.Io.Dir.cwd().readFileAlloc(io, helper, arena, .unlimited);
    try testing.expectEqualStrings("SUPPORT BODY", helper_bytes);
    try testing.expect(isKind(io, try std.fs.path.join(arena, &.{ analysis_dir, "run-analysis.sh" }), .file));
    try testing.expect(isKind(io, try std.fs.path.join(arena, &.{ analysis_dir, "workspace", "prompt.txt" }), .file));
    try testing.expect(isKind(io, try std.fs.path.join(arena, &.{ analysis_dir, "home", "Library", "Keychains" }), .symlink));
    // The temp Codex profile was written into codex_home.
    try testing.expect(isKind(io, try std.fs.path.join(arena, &.{ h.codex_home, "skill-importer-analysis-demo-1000-0.config.toml" }), .file));
}

test "analyze: non-macOS is rejected before any work" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");

    var fake = FakeSpawner{};
    var c = h.context(false);
    switch (al.analyze(&c, fake.spawner(), "demo")) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .unsupported_platform), e.kind),
    }
    try testing.expect(fake.launched == null);
}

test "analyze: missing codex CLI fails with codex_unavailable" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");

    var fake = FakeSpawner{ .codex_ok = false };
    var c = h.context(true);
    switch (al.analyze(&c, fake.spawner(), "demo")) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .codex_unavailable), e.kind),
    }
}

test "analyze: file-backed Codex auth is refused" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");
    // Plant codex_home/auth.json.
    try h.roots.dir().createDirPath(io, "codex_home");
    try h.roots.dir().writeFile(io, .{ .sub_path = "codex_home/auth.json", .data = "{}" });

    var fake = FakeSpawner{};
    var c = h.context(true);
    switch (al.analyze(&c, fake.spawner(), "demo")) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .file_backed_codex_auth), e.kind),
    }
}

test "analyze: unknown skill is reported" {
    var h = try Harness.init();
    defer h.deinit();
    var fake = FakeSpawner{};
    var c = h.context(true);
    switch (al.analyze(&c, fake.spawner(), "ghost")) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .unknown_skill), e.kind),
    }
}

test "analyze: an agent-only skill cannot be analyzed" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    // A bare real directory in an agent root is discovered as agent_only.
    try fx.realDir(.claude, "ghost");

    var fake = FakeSpawner{};
    var c = h.context(true);
    switch (al.analyze(&c, fake.spawner(), "ghost")) {
        .ok => return error.ExpectedError,
        .err => |e| try testing.expectEqual(@as(@TypeOf(e.kind), .agent_only_skill), e.kind),
    }
}

test "analyze: a snapshot symlink escaping the skill dir is refused" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");
    // A secret outside the skill directory, and an in-skill symlink pointing at it.
    try h.roots.dir().writeFile(io, .{ .sub_path = "secret", .data = "TOP SECRET" });
    const secret_abs = try std.fs.path.join(h.arena(), &.{ h.roots.base, "secret" });
    try fx.symlink(secret_abs, "imports/demo/escape");

    var fake = FakeSpawner{};
    var c = h.context(true);
    // The escape guard aborts the copy; the launch must NOT happen.
    try testing.expect(!al.analyze(&c, fake.spawner(), "demo").isOk());
    try testing.expect(fake.launched == null);
}

// The prefix-boundary escape: a SIBLING directory (`demo-evil`) whose name
// extends the skill dir name must NOT be treated as inside it. A byte-prefix
// guard would let this through; the component-wise guard refuses it.
test "analyze: a symlink to a sibling-prefix directory is refused" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");
    try h.roots.dir().createDirPath(io, "imports/demo-evil");
    try h.roots.dir().writeFile(io, .{ .sub_path = "imports/demo-evil/secret", .data = "SIBLING SECRET" });
    const sibling = try std.fs.path.join(h.arena(), &.{ h.roots.base, "imports", "demo-evil", "secret" });
    try fx.symlink(sibling, "imports/demo/escape");

    var fake = FakeSpawner{};
    var c = h.context(true);
    try testing.expect(!al.analyze(&c, fake.spawner(), "demo").isOk());
    try testing.expect(fake.launched == null);
}

// An IN-TREE symlink to a file inside the skill dir is allowed and copied by
// content (v1 parity). This locks against a regression that refuses all symlinks.
test "analyze: an in-tree symlinked file is copied by content" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");
    try h.roots.dir().writeFile(io, .{ .sub_path = "imports/demo/real.txt", .data = "REAL BODY" });
    try fx.symlink("real.txt", "imports/demo/link.txt");

    var fake = FakeSpawner{};
    var c = h.context(true);
    const res = switch (al.analyze(&c, fake.spawner(), "demo")) {
        .ok => |v| v,
        .err => return error.UnexpectedError,
    };
    const analysis_dir = std.fs.path.dirname(res.report_dir).?;
    const copied = try std.fs.path.join(h.arena(), &.{ analysis_dir, "workspace", "snapshot", "link.txt" });
    // The destination is a real file (content copy), not a recreated symlink.
    try testing.expect(isKind(io, copied, .file));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, copied, h.arena(), .unlimited);
    try testing.expectEqualStrings("REAL BODY", bytes);
}

// A symlinked DIRECTORY (even in-tree) is refused (v1 copy_dir_checked refuses
// symlinked directories regardless of target).
test "analyze: an in-tree symlinked directory is refused" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");
    try h.roots.dir().createDirPath(io, "imports/demo/sub");
    try h.roots.dir().writeFile(io, .{ .sub_path = "imports/demo/sub/f.txt", .data = "x" });
    try fx.symlink("sub", "imports/demo/dlink");

    var fake = FakeSpawner{};
    var c = h.context(true);
    try testing.expect(!al.analyze(&c, fake.spawner(), "demo").isOk());
    try testing.expect(fake.launched == null);
}

// A CHAINED in-tree symlink (top -> mid -> file) resolves via realpath to the
// in-tree regular file and is copied by content. This locks the resolved-target
// path that otherwise rests only on reasoning.
test "analyze: a chained in-tree symlink is copied by content" {
    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");
    try h.roots.dir().writeFile(io, .{ .sub_path = "imports/demo/real.txt", .data = "CHAIN BODY" });
    try fx.symlink("real.txt", "imports/demo/mid");
    try fx.symlink("mid", "imports/demo/top");

    var fake = FakeSpawner{};
    var c = h.context(true);
    const res = switch (al.analyze(&c, fake.spawner(), "demo")) {
        .ok => |v| v,
        .err => return error.UnexpectedError,
    };
    const analysis_dir = std.fs.path.dirname(res.report_dir).?;
    const copied = try std.fs.path.join(h.arena(), &.{ analysis_dir, "workspace", "snapshot", "top" });
    try testing.expect(isKind(io, copied, .file));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, copied, h.arena(), .unlimited);
    try testing.expectEqualStrings("CHAIN BODY", bytes);
}

// A non-regular entry (named pipe) must be SKIPPED, never read — reading a fifo
// would block forever. The analysis still succeeds; the fifo is absent from the
// snapshot. POSIX-only (mkfifo is libc); skip elsewhere. Safety: the fifo lives
// inside the temp tree.
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "analyze: a fifo in the skill dir is skipped, not read" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");
    const fifo_abs = try std.fs.path.joinZ(h.arena(), &.{ h.roots.base, "imports", "demo", "pipe" });
    if (mkfifo(fifo_abs.ptr, 0o600) != 0) return error.SkipZigTest;

    var fake = FakeSpawner{};
    var c = h.context(true);
    const res = switch (al.analyze(&c, fake.spawner(), "demo")) {
        .ok => |v| v,
        .err => return error.UnexpectedError,
    };
    const analysis_dir = std.fs.path.dirname(res.report_dir).?;
    // SKILL.md copied; the fifo skipped entirely.
    try testing.expect(isKind(io, try std.fs.path.join(h.arena(), &.{ analysis_dir, "workspace", "snapshot", "SKILL.md" }), .file));
    try testing.expect(isKind(io, try std.fs.path.join(h.arena(), &.{ analysis_dir, "workspace", "snapshot", "pipe" }), .missing));
}

// A symlink whose (in-tree) target is a fifo must also be skipped, never read:
// the resolved-target stat lands in the `else => {}` arm.
test "analyze: an in-tree symlink to a fifo is skipped" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var h = try Harness.init();
    defer h.deinit();
    var fx = testutil.Fixtures.init(&h.roots);
    try fx.writeSkill("imports/demo", "demo", "A demo skill.");
    const fifo_abs = try std.fs.path.joinZ(h.arena(), &.{ h.roots.base, "imports", "demo", "pipe" });
    if (mkfifo(fifo_abs.ptr, 0o600) != 0) return error.SkipZigTest;
    try fx.symlink("pipe", "imports/demo/plink");

    var fake = FakeSpawner{};
    var c = h.context(true);
    const res = switch (al.analyze(&c, fake.spawner(), "demo")) {
        .ok => |v| v,
        .err => return error.UnexpectedError,
    };
    const analysis_dir = std.fs.path.dirname(res.report_dir).?;
    try testing.expect(isKind(io, try std.fs.path.join(h.arena(), &.{ analysis_dir, "workspace", "snapshot", "plink" }), .missing));
}

// --- RealSpawner error mapping (stub executables; never spawns real codex or
// Terminal). Mirrors git.zig's RealProvider tests: inject the executable paths
// so exit-code -> bool mapping is exercised without touching the environment.
// Safety: stubs live in a temp tree. ---

fn writeStub(dir: std.Io.Dir, name: []const u8, body: []const u8) !void {
    var f = try dir.createFile(io, name, .{ .permissions = .executable_file });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

test "RealSpawner.ensureCodex: missing binary and non-zero exit map to false; exit 0 to true" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    try writeStub(tmp.dir, "ok", "#!/bin/sh\nexit 0\n");
    try writeStub(tmp.dir, "bad", "#!/bin/sh\nexit 3\n");
    const ok = try std.fs.path.join(testing.allocator, &.{ base, "ok" });
    defer testing.allocator.free(ok);
    const bad = try std.fs.path.join(testing.allocator, &.{ base, "bad" });
    defer testing.allocator.free(bad);
    const missing = try std.fs.path.join(testing.allocator, &.{ base, "nope" });
    defer testing.allocator.free(missing);

    var s_ok = al.RealSpawner{ .gpa = testing.allocator, .io = io, .codex_path = ok };
    try testing.expect(s_ok.spawner().ensureCodex());
    var s_bad = al.RealSpawner{ .gpa = testing.allocator, .io = io, .codex_path = bad };
    try testing.expect(!s_bad.spawner().ensureCodex());
    var s_missing = al.RealSpawner{ .gpa = testing.allocator, .io = io, .codex_path = missing };
    try testing.expect(!s_missing.spawner().ensureCodex());
}

test "RealSpawner.launch: osascript exit code maps to the launch boolean" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    try writeStub(tmp.dir, "osa-ok", "#!/bin/sh\nexit 0\n");
    try writeStub(tmp.dir, "osa-bad", "#!/bin/sh\nexit 1\n");
    const osa_ok = try std.fs.path.join(testing.allocator, &.{ base, "osa-ok" });
    defer testing.allocator.free(osa_ok);
    const osa_bad = try std.fs.path.join(testing.allocator, &.{ base, "osa-bad" });
    defer testing.allocator.free(osa_bad);

    var s_ok = al.RealSpawner{ .gpa = testing.allocator, .io = io, .osascript_path = osa_ok };
    try testing.expect(s_ok.spawner().launch("/tmp/some script's path/run.sh"));
    var s_bad = al.RealSpawner{ .gpa = testing.allocator, .io = io, .osascript_path = osa_bad };
    try testing.expect(!s_bad.spawner().launch("/tmp/run.sh"));
}
