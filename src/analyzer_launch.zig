//! Skill-analysis launcher (Phase C; ported from v1 `analyzer.rs`
//! `TerminalSkillAnalyzerLauncher`). Non-spec extension.
//!
//! `analyze` resolves a managed skill's live directory, then — on macOS, with the
//! `codex` CLI available and no file-backed Codex auth — assembles an isolated
//! analysis workspace and launches `codex exec` against it in a new Terminal
//! window. The deterministic filesystem work (allocate workspace, snapshot-copy
//! the skill with a symlink-escape guard, write the prompt/schema/profile/script,
//! link the macOS keychain into the isolated HOME) lives here and is tested
//! against disposable temp roots. The only non-hermetic steps — checking for
//! `codex` and spawning Terminal — are behind the injected `Spawner`, so tests
//! never spawn a real process.
//!
//! The pure prompt/schema/config/script builders come from `analyzer.zig`
//! (Phase B); this module only adds I/O and process orchestration.

const std = @import("std");
const result = @import("result.zig");
const types = @import("types.zig");
const discovery = @import("discovery.zig");
const fsutil = @import("fsutil.zig");
const analyzer = @import("analyzer.zig");

/// The outcome of a successful launch: where the report will be written once the
/// spawned Codex run completes (the run itself is asynchronous, in Terminal).
pub const AnalyzeResult = struct {
    skill_name: []const u8,
    report_dir: []const u8,
    report_path: []const u8,
};

pub const Result = result.Result(AnalyzeResult);

/// The only non-hermetic operations, injected so `analyze` stays testable: probe
/// for the `codex` CLI and launch the generated script in a terminal. Both return
/// `true` on success; the real implementation maps spawn/exit failures to `false`.
pub const Spawner = struct {
    ctx: *anyopaque,
    ensureCodexFn: *const fn (ctx: *anyopaque) bool,
    launchFn: *const fn (ctx: *anyopaque, script_path: []const u8) bool,

    pub fn ensureCodex(self: Spawner) bool {
        return self.ensureCodexFn(self.ctx);
    }
    pub fn launch(self: Spawner, script_path: []const u8) bool {
        return self.launchFn(self.ctx, script_path);
    }
};

/// Injected dependencies for one `analyze`. `home`/`codex_home`/`inherited_env`
/// and `current_exe` are resolved by the CLI edge (`main.zig`) so this module
/// needs no direct environment or self-exe access. All output strings are
/// `arena`-owned.
pub const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    canonical_root: []const u8,
    imports_root: []const u8,
    claude_code_root: []const u8,
    codex_root: []const u8,
    /// Absolute `$HOME`; the analysis cache parent and the keychain link source.
    home: []const u8,
    /// `$CODEX_HOME` (or `<home>/.codex`); where the temp profile is written and
    /// where file-backed auth is rejected.
    codex_home: []const u8,
    /// Locale/terminal/PATH variables to pass through the isolated `env -i` shell.
    inherited_env: []const analyzer.EnvEntry,
    /// Absolute path to this binary, invoked by the script for `render-analysis-report`.
    current_exe: []const u8,
    clock: types.Clock,
    /// Gate for the macOS-only launch (v1 `cfg!(target_os = "macos")`). Injected so
    /// the deterministic filesystem path is testable on any host.
    is_macos: bool,

    fn roots(self: Context) discovery.Roots {
        return .{
            .canonical = self.canonical_root,
            .imports = self.imports_root,
            .claude_code = self.claude_code_root,
            .codex = self.codex_root,
        };
    }
};

/// Launch an analysis for `skill_name` (v1 `TerminalSkillAnalyzerLauncher::launch`).
pub fn analyze(c: *Context, spawner: Spawner, skill_name: []const u8) Result {
    return analyzeImpl(c, spawner, skill_name) catch |err| switch (err) {
        error.OutOfMemory => .{ .err = .{ .kind = .out_of_memory } },
        else => .{ .err = .{ .kind = .io_error, .name = dup(c, skill_name), .reason = @errorName(err) } },
    };
}

fn analyzeImpl(c: *Context, spawner: Spawner, skill_name: []const u8) anyerror!Result {
    // 1. macOS-only (v1 launch guard).
    if (!c.is_macos) {
        return .{ .err = .{ .kind = .unsupported_platform, .name = dup(c, skill_name) } };
    }

    // 2. Resolve the skill's live directory across roots.
    const live = switch (resolveLiveDir(c, skill_name)) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };

    const cwd = std.Io.Dir.cwd();

    // 3. The live skill must have a readable SKILL.md (v1 precondition).
    {
        const skill_md = try std.fs.path.join(c.arena, &.{ live, "SKILL.md" });
        const kind = fsutil.classify(c.io, cwd, skill_md) catch fsutil.EntryKind.missing;
        if (kind != .file) {
            return .{ .err = .{ .kind = .unknown_skill, .name = dup(c, skill_name), .reason = "selected skill has no readable SKILL.md" } };
        }
    }

    // 4. HOME must be absolute to anchor the cache + keychain (v1 resolve_source_home).
    if (c.home.len == 0 or !std.fs.path.isAbsolute(c.home)) {
        return .{ .err = .{ .kind = .io_error, .name = dup(c, skill_name), .reason = "HOME must be set to an absolute path to launch skill analysis" } };
    }

    // 5. The `codex` CLI must be available (v1 ensure_codex_available).
    if (!spawner.ensureCodex()) {
        return .{ .err = .{ .kind = .codex_unavailable, .name = dup(c, skill_name) } };
    }

    // 6. Refuse file-backed Codex auth: it would expose reusable credentials to
    //    the analyzed (untrusted) skill (v1 reject_file_backed_codex_auth).
    {
        const auth = try std.fs.path.join(c.arena, &.{ c.codex_home, "auth.json" });
        const kind = fsutil.classify(c.io, cwd, auth) catch fsutil.EntryKind.missing;
        if (kind != .missing) {
            return .{ .err = .{ .kind = .file_backed_codex_auth, .name = dup(c, skill_name), .path = auth } };
        }
    }

    // 7. Allocate a unique workspace under ~/Library/Caches (v1 analysis_parent_dir).
    const parent = try std.fs.path.join(c.arena, &.{ c.home, "Library", "Caches", "skill-importer-analysis" });
    try cwd.createDirPath(c.io, parent);
    const analysis_dir = try allocateWorkspace(c, parent, skill_name);

    // 8. Assemble the plan (Phase B, pure).
    const plan = try analyzer.buildLaunchPlan(c.arena, .{
        .skill_name = skill_name,
        .skill_dir = live,
        .current_exe = c.current_exe,
        .source_codex_home = c.codex_home,
        .source_home = c.home,
        .analysis_dir = analysis_dir,
        .inherited_env = c.inherited_env,
    });

    // 9. Materialize the workspace.
    try cwd.createDirPath(c.io, plan.workspace_dir);
    try cwd.createDirPath(c.io, plan.report_dir);
    try cwd.createDirPath(c.io, plan.isolated_home);
    try cwd.createDirPath(c.io, c.codex_home);
    try copySnapshot(c, live, plan.snapshot_dir);
    try writeNew(c, plan.prompt_path, plan.prompt_content);
    try writeNew(c, plan.output_schema_path, plan.output_schema_content);
    try prepareKeychainLink(c, plan);
    try writeNew(c, plan.codex_profile_path, analyzer.renderCodexConfig());
    try writeNew(c, plan.script_path, try analyzer.renderLaunchScript(c.arena, plan));

    // 10. Launch (v1 launch_terminal_script).
    if (!spawner.launch(plan.script_path)) {
        return .{ .err = .{ .kind = .io_error, .name = dup(c, skill_name), .reason = "failed to launch Terminal for skill analysis" } };
    }

    return .{ .ok = .{
        .skill_name = dup(c, skill_name),
        .report_dir = plan.report_dir,
        .report_path = plan.report_html_path,
    } };
}

/// Resolve `skill_name` to the on-disk directory holding its `SKILL.md`. Prefers
/// a canonical (promoted) copy, falling back to the draft import directory.
fn resolveLiveDir(c: *Context, skill_name: []const u8) result.Result([]const u8) {
    const inv = switch (discovery.discover(c.arena, c.io, c.roots())) {
        .ok => |i| i,
        .err => |e| return .{ .err = e },
    };
    for (inv.skills) |s| {
        if (!std.mem.eql(u8, s.name, skill_name)) continue;
        switch (s.source) {
            .agent_only => return .{ .err = .{ .kind = .agent_only_skill, .name = dup(c, skill_name) } },
            .canonical => return joinResult(c, c.canonical_root, s.canonical_dir orelse skill_name),
            .imported => {
                if (s.canonical_dir) |cd| return joinResult(c, c.canonical_root, cd);
                return joinResult(c, c.imports_root, s.imports_dir orelse skill_name);
            },
        }
    }
    return .{ .err = .{ .kind = .unknown_skill, .name = dup(c, skill_name) } };
}

fn joinResult(c: *Context, root: []const u8, name: []const u8) result.Result([]const u8) {
    const p = std.fs.path.join(c.arena, &.{ root, name }) catch return .{ .err = .{ .kind = .out_of_memory } };
    return .{ .ok = p };
}

/// Create a unique `<slug>-<seconds>-<attempt>` workspace directory, retrying on
/// collision (v1 allocate_workspace_dir).
fn allocateWorkspace(c: *Context, parent: []const u8, skill_name: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const slug = try analyzer.sanitizeName(c.arena, skill_name);
    const now = c.clock.now();
    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        const candidate = try std.fmt.allocPrint(c.arena, "{s}/{s}-{d}-{d}", .{ parent, slug, now, attempt });
        cwd.createDir(c.io, candidate, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return candidate;
    }
    return error.WorkspaceAllocFailed;
}

/// Recursively copy the live skill into the snapshot, REFUSING any symlink whose
/// target escapes the skill directory and any symlinked directory (v1
/// copy_skill_snapshot / copy_dir_checked). Symlinks to in-tree files are copied
/// by content. This is the security boundary: the analyzed skill is untrusted.
fn copySnapshot(c: *Context, source: []const u8, dest: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const root_z = try cwd.realPathFileAlloc(c.io, source, c.arena);
    try copyDirChecked(c, root_z, dest, root_z);
}

fn copyDirChecked(c: *Context, source: []const u8, dest: []const u8, root: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(c.io, dest);

    var dir = try cwd.openDir(c.io, source, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        const src_path = try std.fs.path.join(c.arena, &.{ source, entry.name });
        const dst_path = try std.fs.path.join(c.arena, &.{ dest, entry.name });
        switch (try fsutil.classify(c.io, cwd, src_path)) {
            .file => try copyFileBytes(c, src_path, dst_path),
            .directory => try copyDirChecked(c, src_path, dst_path, root),
            .symlink => {
                // Canonicalize the target; a broken link or one escaping the
                // skill directory is refused.
                const target = cwd.realPathFileAlloc(c.io, src_path, c.arena) catch return error.UnsupportedEntry;
                if (!std.mem.startsWith(u8, target, root)) return error.UnsupportedEntry;
                const st = cwd.statFile(c.io, target, .{ .follow_symlinks = true }) catch return error.UnsupportedEntry;
                switch (st.kind) {
                    .directory => return error.UnsupportedEntry,
                    .file => try copyFileBytes(c, target, dst_path),
                    else => {},
                }
            },
            .missing => {},
        }
    }
}

fn copyFileBytes(c: *Context, src_path: []const u8, dst_path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(c.io, src_path, c.arena, .unlimited);
    try writeNew(c, dst_path, bytes);
}

/// Link the macOS keychain directory into the isolated HOME so `codex` can reach
/// auth state without exposing the real HOME (v1 prepare_keychain_link). Skips if
/// the link already exists.
fn prepareKeychainLink(c: *Context, plan: analyzer.LaunchPlan) !void {
    const cwd = std.Io.Dir.cwd();
    const link_parent = std.fs.path.dirname(plan.keychains_link_path) orelse return error.BadKeychainPath;
    try cwd.createDirPath(c.io, link_parent);
    const kind = fsutil.classify(c.io, cwd, plan.keychains_link_path) catch fsutil.EntryKind.missing;
    if (kind != .missing) return;
    try cwd.symLink(c.io, plan.keychains_target_path, plan.keychains_link_path, .{});
}

/// Create `path` exclusively and write `bytes` (never clobbers; v1 write_new_file).
fn writeNew(c: *Context, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(c.io, path, .{ .exclusive = true });
    defer file.close(c.io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(c.io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

fn dup(c: *Context, s: []const u8) []const u8 {
    return c.arena.dupe(u8, s) catch s;
}

// ===========================================================================
// RealSpawner: probes `codex` and launches Terminal via `osascript`.
// ===========================================================================

/// Production `Spawner`. `codex_path`/`osascript_path` are injectable so the
/// real-process error mapping can be tested with stubs without mutating the
/// environment (mirrors `git.RealProvider`).
pub const RealSpawner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    codex_path: []const u8 = "codex",
    osascript_path: []const u8 = "osascript",

    pub fn spawner(self: *RealSpawner) Spawner {
        return .{ .ctx = self, .ensureCodexFn = ensureCodexImpl, .launchFn = launchImpl };
    }

    fn ensureCodexImpl(ctx: *anyopaque) bool {
        const self: *RealSpawner = @ptrCast(@alignCast(ctx));
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ self.codex_path, "--version" },
        }) catch return false;
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        return switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    fn launchImpl(ctx: *anyopaque, script_path: []const u8) bool {
        const self: *RealSpawner = @ptrCast(@alignCast(ctx));
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const command = std.fmt.allocPrint(arena, "sh {s}", .{
            analyzer.shellQuote(arena, script_path) catch return false,
        }) catch return false;
        const do_script = std.fmt.allocPrint(arena, "tell application \"Terminal\" to do script {s}", .{
            analyzer.applescriptQuote(arena, command) catch return false,
        }) catch return false;

        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{
                self.osascript_path,
                "-e",
                do_script,
                "-e",
                "tell application \"Terminal\" to activate",
            },
        }) catch return false;
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        return switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};
