//! Test-only helpers (zig-clean-room-cli.md "Test infrastructure built first").
//!
//! SAFETY (CLAUDE.md hard rule + spec "Filesystem Safety"): every test operates
//! inside a unique temp tree created via `std.testing.tmpDir`. No helper here ever
//! touches a real user root (~/.claude/skills, ~/.agents/skills, ~/dev/agent-skills,
//! $HOME defaults). `TmpRoots.deinit` deletes the whole tree.

const std = @import("std");
const types = @import("types.zig");
const result = @import("result.zig");
const net = @import("net.zig");

const io = std.testing.io;

/// A unique temp tree with the four spec roots
/// (cli-clean-room-spec.md "Root Resolution") as subdirectories:
/// `canonical/`, `imports/`, `claude/`, `codex/`. Roots are NOT pre-created on
/// disk (spec: "Missing roots are valid and are treated as empty"); call
/// `makeRoot` to materialize one. Absolute paths are exposed for CLI-level tests.
pub const TmpRoots = struct {
    tmp: std.testing.TmpDir,
    gpa: std.mem.Allocator,
    /// Absolute path of the temp tree base.
    base: []u8,
    canonical: []u8,
    imports: []u8,
    claude: []u8,
    codex: []u8,

    pub fn init(gpa: std.mem.Allocator) !TmpRoots {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();

        // realPathFileAlloc returns a sentinel-terminated [:0]u8; keep a plain
        // []u8 copy so deinit's free size matches the allocation.
        const base_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        const base = try gpa.dupe(u8, base_z);
        gpa.free(base_z);
        errdefer gpa.free(base);

        const canonical = try std.fs.path.join(gpa, &.{ base, "canonical" });
        errdefer gpa.free(canonical);
        const imports = try std.fs.path.join(gpa, &.{ base, "imports" });
        errdefer gpa.free(imports);
        const claude = try std.fs.path.join(gpa, &.{ base, "claude" });
        errdefer gpa.free(claude);
        const codex = try std.fs.path.join(gpa, &.{ base, "codex" });
        errdefer gpa.free(codex);

        return .{
            .tmp = tmp,
            .gpa = gpa,
            .base = base,
            .canonical = canonical,
            .imports = imports,
            .claude = claude,
            .codex = codex,
        };
    }

    pub fn deinit(self: *TmpRoots) void {
        self.gpa.free(self.base);
        self.gpa.free(self.canonical);
        self.gpa.free(self.imports);
        self.gpa.free(self.claude);
        self.gpa.free(self.codex);
        self.tmp.cleanup();
        self.* = undefined;
    }

    /// The iterable base `Dir` handle, valid until `deinit`.
    pub fn dir(self: *TmpRoots) std.Io.Dir {
        return self.tmp.dir;
    }

    /// Materialize one of the roots (and any parents) on disk.
    pub fn makeRoot(self: *TmpRoots, which: Root) !void {
        try self.tmp.dir.createDirPath(io, @tagName(which));
    }

    pub const Root = enum { canonical, imports, claude, codex };

    /// Absolute path of a named root.
    pub fn rootPath(self: *TmpRoots, which: Root) []const u8 {
        return switch (which) {
            .canonical => self.canonical,
            .imports => self.imports,
            .claude => self.claude,
            .codex => self.codex,
        };
    }
};

/// Fixture builder: constructs skill directories, manifests, symlinks, and stray
/// entries so every `AgentEntryStatus` case (spec "Inventory") is reproducible.
/// All paths are relative to the `TmpRoots` base; nested parents are created.
pub const Fixtures = struct {
    roots: *TmpRoots,

    pub fn init(roots: *TmpRoots) Fixtures {
        return .{ .roots = roots };
    }

    fn dir(self: Fixtures) std.Io.Dir {
        return self.roots.tmp.dir;
    }

    /// Write `<rel_dir>/SKILL.md` with the given frontmatter `name`/`description`.
    pub fn writeSkill(self: Fixtures, rel_dir: []const u8, name: []const u8, description: []const u8) !void {
        try self.dir().createDirPath(io, rel_dir);
        var buf: [4096]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &buf,
            "---\nname: {s}\ndescription: {s}\n---\n",
            .{ name, description },
        );
        const path = try std.fs.path.join(self.roots.gpa, &.{ rel_dir, "SKILL.md" });
        defer self.roots.gpa.free(path);
        try self.dir().writeFile(io, .{ .sub_path = path, .data = body });
    }

    /// Write an arbitrary supporting file at `<rel_dir>/<rel_file>`.
    pub fn writeSupportFile(self: Fixtures, rel_dir: []const u8, rel_file: []const u8, data: []const u8) !void {
        try self.dir().createDirPath(io, rel_dir);
        const path = try std.fs.path.join(self.roots.gpa, &.{ rel_dir, rel_file });
        defer self.roots.gpa.free(path);
        try self.dir().writeFile(io, .{ .sub_path = path, .data = data });
    }

    /// Write `<rel_dir>/import.json` from a manifest struct (no trailing newline,
    /// spec: on-disk `import.json` has no trailing newline).
    pub fn writeManifest(self: Fixtures, rel_dir: []const u8, manifest: types.ImportManifest) !void {
        try self.dir().createDirPath(io, rel_dir);
        var aw: std.Io.Writer.Allocating = .init(self.roots.gpa);
        defer aw.deinit();
        try std.json.Stringify.value(manifest, .{ .whitespace = .indent_2 }, &aw.writer);
        const path = try std.fs.path.join(self.roots.gpa, &.{ rel_dir, "import.json" });
        defer self.roots.gpa.free(path);
        try self.dir().writeFile(io, .{ .sub_path = path, .data = aw.writer.buffered() });
    }

    /// Write raw bytes to `<rel_dir>/import.json` (e.g. malformed manifest).
    pub fn writeRawManifest(self: Fixtures, rel_dir: []const u8, data: []const u8) !void {
        try self.dir().createDirPath(io, rel_dir);
        const path = try std.fs.path.join(self.roots.gpa, &.{ rel_dir, "import.json" });
        defer self.roots.gpa.free(path);
        try self.dir().writeFile(io, .{ .sub_path = path, .data = data });
    }

    /// Create a symlink at `link_rel` pointing to `target` (target may be
    /// relative or absolute, existing or not — used to build broken/external
    /// links). Parent of `link_rel` is created.
    pub fn symlink(self: Fixtures, target: []const u8, link_rel: []const u8) !void {
        if (std.fs.path.dirname(link_rel)) |parent| {
            try self.dir().createDirPath(io, parent);
        }
        try self.dir().symLink(io, target, link_rel, .{});
    }

    /// Create a managed symlink in an agent root pointing at a canonical/imports
    /// skill. Produces an `AgentEntryStatus.canonical_symlink` /
    /// `imported_symlink` depending on the target root.
    pub fn managedSymlink(self: Fixtures, agent: TmpRoots.Root, skill_name: []const u8, target_root: TmpRoots.Root, target_skill: []const u8) !void {
        try self.roots.makeRoot(agent);
        const target = try std.fs.path.join(self.roots.gpa, &.{ self.roots.rootPath(target_root), target_skill });
        defer self.roots.gpa.free(target);
        const link_rel = try std.fs.path.join(self.roots.gpa, &.{ @tagName(agent), skill_name });
        defer self.roots.gpa.free(link_rel);
        try self.dir().symLink(io, target, link_rel, .{});
    }

    /// Create a real (non-symlink) directory entry in an agent root — an
    /// `AgentEntryStatus.skill_directory`.
    pub fn realDir(self: Fixtures, agent: TmpRoots.Root, name: []const u8) !void {
        const rel = try std.fs.path.join(self.roots.gpa, &.{ @tagName(agent), name });
        defer self.roots.gpa.free(rel);
        try self.dir().createDirPath(io, rel);
    }

    /// Create a stray regular file in an agent root — an external/unsafe entry.
    pub fn strayFile(self: Fixtures, agent: TmpRoots.Root, name: []const u8, data: []const u8) !void {
        try self.roots.makeRoot(agent);
        const rel = try std.fs.path.join(self.roots.gpa, &.{ @tagName(agent), name });
        defer self.roots.gpa.free(rel);
        try self.dir().writeFile(io, .{ .sub_path = rel, .data = data });
    }
};

// ---------------------------------------------------------------------------
// Injectable side-effect providers (zig-clean-room-cli.md "Test infrastructure").
// ---------------------------------------------------------------------------

/// Injectable clock interface; the canonical type lives in the domain model
/// (types.Clock) so production code can use it without importing this test-only
/// module. Re-exported here for test convenience.
pub const Clock = types.Clock;

/// A clock that always returns a fixed timestamp.
pub const FixedClock = struct {
    value: i64,

    pub fn clock(self: *FixedClock) Clock {
        return .{ .nowFn = nowImpl, .ctx = self };
    }

    fn nowImpl(ctx: *anyopaque) i64 {
        const self: *FixedClock = @ptrCast(@alignCast(ctx));
        return self.value;
    }
};

/// Network fetcher abstraction. The canonical interface lives in net.zig so the
/// real (std.http-backed) and fake fetchers share one type; re-exported here for
/// test convenience (zig-clean-room-cli.md: fake net provider).
pub const Fetcher = net.Fetcher;

/// A fake fetcher returning canned bytes or a canned error.
pub const FakeFetcher = struct {
    body: ?[]const u8 = null,
    fail_with: ?Fetcher.FetchError = null,

    pub fn fetcher(self: *FakeFetcher) Fetcher {
        return .{ .fetchFn = fetchImpl, .ctx = self };
    }

    fn fetchImpl(ctx: *anyopaque, gpa: std.mem.Allocator, url: []const u8) Fetcher.FetchError![]u8 {
        _ = url;
        const self: *FakeFetcher = @ptrCast(@alignCast(ctx));
        if (self.fail_with) |e| return e;
        const body = self.body orelse return error.FetchFailed;
        return gpa.dupe(u8, body);
    }
};

/// Git/repository provider abstraction (struct of fn pointers) so repository
/// import tests need no network or `git` binary (zig-clean-room-cli.md: fake git
/// provider). `checkout` "checks out" a repo to a destination directory; the fake
/// copies a prebuilt local tree.
pub const Provider = struct {
    /// Materialize `repository` into the empty directory at absolute `dest_path`,
    /// or return a `result.ErrorKind` (git_unavailable/repository_error).
    checkoutFn: *const fn (ctx: *anyopaque, repository: []const u8, dest_path: []const u8) CheckoutError!void,
    ctx: *anyopaque,

    pub const CheckoutError = error{ GitUnavailable, RepositoryError };

    pub fn checkout(self: Provider, repository: []const u8, dest_path: []const u8) CheckoutError!void {
        return self.checkoutFn(self.ctx, repository, dest_path);
    }
};

/// A fake provider that copies a prebuilt source tree (given as an absolute path)
/// into the checkout destination, or returns a canned error.
pub const FakeProvider = struct {
    source_tree: ?[]const u8 = null,
    fail_with: ?Provider.CheckoutError = null,

    pub fn provider(self: *FakeProvider) Provider {
        return .{ .checkoutFn = checkoutImpl, .ctx = self };
    }

    fn checkoutImpl(ctx: *anyopaque, repository: []const u8, dest_path: []const u8) Provider.CheckoutError!void {
        _ = repository;
        const self: *FakeProvider = @ptrCast(@alignCast(ctx));
        if (self.fail_with) |e| return e;
        const src = self.source_tree orelse return error.RepositoryError;
        copyTree(src, dest_path) catch return error.RepositoryError;
    }

    fn copyTree(src_abs: []const u8, dest_abs: []const u8) !void {
        var src_dir = try std.Io.Dir.cwd().openDir(io, src_abs, .{ .iterate = true });
        defer src_dir.close(io);
        try std.Io.Dir.cwd().createDirPath(io, dest_abs);
        var dest_dir = try std.Io.Dir.cwd().openDir(io, dest_abs, .{});
        defer dest_dir.close(io);

        var it = src_dir.iterate();
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (try it.next(io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    const sub_src = try std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ src_abs, entry.name });
                    var dest_join: [std.fs.max_path_bytes]u8 = undefined;
                    const sub_dest = try std.fmt.bufPrint(&dest_join, "{s}/{s}", .{ dest_abs, entry.name });
                    try copyTree(sub_src, sub_dest);
                },
                .file => {
                    try src_dir.copyFile(entry.name, dest_dir, entry.name, io, .{});
                },
                else => {},
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Smoke tests: one per helper.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "TmpRoots: unique tree, roots not pre-created, deinit deletes" {
    var roots = try TmpRoots.init(testing.allocator);
    // Roots are NOT pre-created (spec: missing roots are valid/empty).
    try testing.expectError(error.FileNotFound, roots.dir().statFile(io, "canonical", .{ .follow_symlinks = false }));

    try roots.makeRoot(.canonical);
    const st = try roots.dir().statFile(io, "canonical", .{ .follow_symlinks = false });
    try testing.expect(st.kind == .directory);

    // Absolute paths point inside the temp base.
    try testing.expect(std.mem.startsWith(u8, roots.canonical, roots.base));
    try testing.expect(std.mem.endsWith(u8, roots.rootPath(.codex), "codex"));

    roots.deinit();
}

test "Fixtures: writeSkill + writeManifest produce readable files" {
    var roots = try TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = Fixtures.init(&roots);

    try fx.writeSkill("imports/alpha", "alpha", "Alpha skill.");
    const skill = try roots.dir().readFileAlloc(io, "imports/alpha/SKILL.md", testing.allocator, .unlimited);
    defer testing.allocator.free(skill);
    try testing.expect(std.mem.indexOf(u8, skill, "name: alpha") != null);
    try testing.expect(std.mem.indexOf(u8, skill, "description: Alpha skill.") != null);

    try fx.writeManifest("imports/alpha", .{
        .source_type = .markdown,
        .imported_at = 1710000000,
        .content_hash = "sha256:deadbeef",
        .promoted = false,
    });
    const manifest = try roots.dir().readFileAlloc(io, "imports/alpha/import.json", testing.allocator, .unlimited);
    defer testing.allocator.free(manifest);
    try testing.expect(std.mem.indexOf(u8, manifest, "\"source_type\"") != null);
    // No trailing newline on disk (spec: import.json has no trailing newline).
    try testing.expect(manifest[manifest.len - 1] != '\n');
}

test "Fixtures: each AgentEntryStatus shape is constructible" {
    var roots = try TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = Fixtures.init(&roots);

    try fx.writeSkill("canonical/beta", "beta", "Beta.");

    // canonical_symlink
    try fx.managedSymlink(.claude, "beta", .canonical, "beta");
    const link_st = try roots.dir().statFile(io, "claude/beta", .{ .follow_symlinks = false });
    try testing.expect(link_st.kind == .sym_link);

    // skill_directory (real dir in agent root)
    try fx.realDir(.codex, "gamma");
    const dir_st = try roots.dir().statFile(io, "codex/gamma", .{ .follow_symlinks = false });
    try testing.expect(dir_st.kind == .directory);

    // broken_symlink (target does not exist)
    try fx.symlink("does/not/exist", "claude/broken");
    const broken_st = try roots.dir().statFile(io, "claude/broken", .{ .follow_symlinks = false });
    try testing.expect(broken_st.kind == .sym_link);
    try testing.expectError(error.FileNotFound, roots.dir().statFile(io, "claude/broken", .{ .follow_symlinks = true }));

    // external_symlink (real but stray file target)
    try fx.strayFile(.codex, "stray-target", "x");
    try fx.symlink("stray-target", "codex/external");
    const ext_st = try roots.dir().statFile(io, "codex/external", .{ .follow_symlinks = false });
    try testing.expect(ext_st.kind == .sym_link);
}

test "FixedClock returns a stable timestamp through the Clock interface" {
    var fc: FixedClock = .{ .value = 1710000000 };
    const clk = fc.clock();
    try testing.expectEqual(@as(i64, 1710000000), clk.now());
    try testing.expectEqual(@as(i64, 1710000000), clk.now());
}

test "FakeFetcher returns canned body and canned error" {
    var ok_fetch: FakeFetcher = .{ .body = "hello body" };
    const f = ok_fetch.fetcher();
    const body = try f.fetch(testing.allocator, "https://example.test/x.md");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello body", body);

    var bad_fetch: FakeFetcher = .{ .fail_with = error.SizeExceeded };
    const fb = bad_fetch.fetcher();
    try testing.expectError(error.SizeExceeded, fb.fetch(testing.allocator, "https://example.test/big"));
}

test "FakeProvider checks out a prebuilt tree into a destination" {
    var roots = try TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = Fixtures.init(&roots);

    // Build a source repo tree under the temp base.
    try fx.writeSkill("repo-src/skill-one", "skill-one", "One.");
    try fx.writeSupportFile("repo-src/skill-one", "helper.txt", "support");

    const src_abs = try std.fs.path.join(testing.allocator, &.{ roots.base, "repo-src" });
    defer testing.allocator.free(src_abs);
    const dest_abs = try std.fs.path.join(testing.allocator, &.{ roots.base, "checkout" });
    defer testing.allocator.free(dest_abs);

    var fp: FakeProvider = .{ .source_tree = src_abs };
    const p = fp.provider();
    try p.checkout("https://example.test/repo.git", dest_abs);

    const copied = try roots.dir().readFileAlloc(io, "checkout/skill-one/SKILL.md", testing.allocator, .unlimited);
    defer testing.allocator.free(copied);
    try testing.expect(std.mem.indexOf(u8, copied, "name: skill-one") != null);

    const support = try roots.dir().readFileAlloc(io, "checkout/skill-one/helper.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(support);
    try testing.expectEqualStrings("support", support);

    // Provider failure surfaces as the canned error.
    var fp_fail: FakeProvider = .{ .fail_with = error.GitUnavailable };
    const pf = fp_fail.provider();
    try testing.expectError(error.GitUnavailable, pf.checkout("x", dest_abs));
}
