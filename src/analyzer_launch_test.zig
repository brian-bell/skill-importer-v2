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
