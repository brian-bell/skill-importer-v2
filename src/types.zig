//! Domain model: enums + structs mirroring the spec JSON schemas field-for-field,
//! in declaration order == emit order (cli-clean-room-spec.md "JSON Schemas").
//!
//! The snake_case spelling of every enum value IS the spec's wire vocabulary and
//! is locked by the enum->string test in json_out.zig.

const std = @import("std");

/// Injectable clock so `imported_at` (spec "Import Manifest") is deterministic in
/// tests (zig-clean-room-cli.md: clock injection `now: fn () i64`). Lives in the
/// domain model (not the test-only module) so production code can depend on it
/// without pulling test infrastructure.
pub const Clock = struct {
    nowFn: *const fn (ctx: *anyopaque) i64,
    ctx: *anyopaque,

    pub fn now(self: Clock) i64 {
        return self.nowFn(self.ctx);
    }
};

/// `source` values (spec "Inventory": `source`).
pub const SkillSource = enum {
    canonical,
    imported,
    agent_only,
};

/// `agent_entries` values (spec "Inventory": `agent_entries`).
/// Enabled == {skill_directory, canonical_symlink, imported_symlink,
/// external_symlink}; disabled == {missing, broken_symlink}.
pub const AgentEntryStatus = enum {
    missing,
    skill_directory,
    canonical_symlink,
    imported_symlink,
    external_symlink,
    broken_symlink,

    /// Enablement boolean mapping (spec "Inventory": "Enablement booleans are
    /// true for skill_directory, canonical_symlink, imported_symlink, and
    /// external_symlink; false for missing and broken_symlink").
    pub fn enabled(self: AgentEntryStatus) bool {
        return switch (self) {
            .skill_directory, .canonical_symlink, .imported_symlink, .external_symlink => true,
            .missing, .broken_symlink => false,
        };
    }
};

/// `source_type` values (spec "Import Manifest").
pub const ImportSourceType = enum {
    markdown,
    local_path,
    url,
    repository,
};

/// Import action values (spec "Import Result": "Import action values").
pub const ImportActionKind = enum {
    create_directory,
    write_skill,
    copy_file,
    write_manifest,
};

/// Skill operation action values (spec "Skill Operation Result").
pub const SkillActionKind = enum {
    create_directory,
    create_symlink,
    remove_symlink,
    copy_file,
    write_manifest,
    remove_directory,
    skip_unchanged,
};

/// Agent identity. CLI input spelling is "claude-code"; JSON wire spelling is
/// "claude_code" (spec "Inventory": `enablement`/`agent_entries` keys).
pub const Agent = enum {
    claude_code,
    codex,

    /// CLI surface spelling (hyphenated), used for `--agent` parsing/rendering.
    pub fn cliName(self: Agent) []const u8 {
        return switch (self) {
            .claude_code => "claude-code",
            .codex => "codex",
        };
    }

    /// JSON/wire spelling (snake_case), used as object keys and `agent` values.
    pub fn jsonName(self: Agent) []const u8 {
        return @tagName(self);
    }
};

/// Repository import result discriminator (spec "Repository Import Result":
/// `kind`).
pub const RepoImportKind = enum {
    imported,
    imported_batch,
    selection,
};

/// Repository provenance for an imported skill (spec "Import Manifest":
/// `source_repository`, and "Inventory": `source_repository`).
pub const SourceRepository = struct {
    repository: []const u8,
    skill_path: []const u8,
};

/// `import.json` contents (spec "Import Manifest").
pub const ImportManifest = struct {
    source_type: ImportSourceType,
    source_location: ?[]const u8 = null,
    source_repository: ?SourceRepository = null,
    imported_at: i64,
    content_hash: []const u8,
    promoted: bool,
};

/// One action in an import result's `actions` array (spec "Import Result").
pub const ImportAction = struct {
    action: ImportActionKind,
    path: []const u8,
};

/// Markdown / path / url import result (spec "Import Result").
pub const ImportResult = struct {
    skill_name: []const u8,
    skill_path: []const u8,
    manifest_path: []const u8,
    manifest: ImportManifest,
    actions: []const ImportAction,
};

/// One action in a skill operation's `actions` array (spec "Skill Operation
/// Result"). `agent` present for agent-root actions, omitted for collection
/// actions; `target` present for symlink/skip actions involving an agent entry;
/// `source` present for copy/promotion actions when useful.
pub const SkillAction = struct {
    action: SkillActionKind,
    agent: ?Agent = null,
    path: []const u8,
    target: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

/// enable / disable / promote / unpromote / delete result (spec "Skill
/// Operation Result").
pub const SkillOperationResult = struct {
    skill_name: []const u8,
    actions: []const SkillAction,
};

/// Per-agent enablement booleans (spec "Inventory": `enablement`).
pub const Enablement = struct {
    claude_code: bool,
    codex: bool,
};

/// Per-agent entry classification (spec "Inventory": `agent_entries`).
pub const AgentEntries = struct {
    claude_code: AgentEntryStatus,
    codex: AgentEntryStatus,
};

/// One skill in the inventory (spec "Inventory": `skills[]`).
pub const SkillEntry = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    source: SkillSource,
    source_repository: ?SourceRepository = null,
    promoted: bool,
    enablement: Enablement,
    agent_entries: AgentEntries,
};

/// One entry inside a grouped `source_repositories[].skills[]` (spec
/// "Inventory": `source_repositories`).
pub const RepositorySkillRef = struct {
    skill_name: []const u8,
    skill_path: []const u8,
};

/// A repository group in the inventory (spec "Inventory":
/// `source_repositories[]`).
pub const SourceRepositoryGroup = struct {
    repository: []const u8,
    skills: []const RepositorySkillRef,
};

/// Full `list --format json` payload (spec "Inventory").
pub const Inventory = struct {
    skills: []const SkillEntry,
    source_repositories: []const SourceRepositoryGroup,
};

/// One discovered skill in a repository selection result (spec "Repository
/// Import Result": selection `skills[]`).
pub const RepositorySkillChoice = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    relative_path: []const u8,
};

/// A single repository import result (spec "Repository Import Result":
/// `kind: "imported"`). Same fields as an `ImportResult`, with the `kind`
/// discriminator FIRST so the JSON emits `kind` before the import fields. The
/// manifest always carries `source_repository` for repository imports.
pub const RepositorySingleImport = struct {
    kind: RepoImportKind = .imported,
    skill_name: []const u8,
    skill_path: []const u8,
    manifest_path: []const u8,
    manifest: ImportManifest,
    actions: []const ImportAction,
};

/// A repository selection result emitted when more than one valid skill exists
/// and no `--select` was provided, WITHOUT writing storage (spec "Repository
/// Import Result": `kind: "selection"`).
pub const RepositorySelection = struct {
    kind: RepoImportKind = .selection,
    repository: []const u8,
    skills: []const RepositorySkillChoice,
};

/// One imported skill inside a batch (spec "Repository Import Result":
/// `imported_batch.imports[]`). Same fields as `ImportResult` (no per-import
/// `kind`).
pub const RepositoryBatchImport = struct {
    skill_name: []const u8,
    skill_path: []const u8,
    manifest_path: []const u8,
    manifest: ImportManifest,
    actions: []const ImportAction,
};

/// A multi-skill batch import result (spec "Repository Import Result":
/// `kind: "imported_batch"`).
pub const RepositoryBatch = struct {
    kind: RepoImportKind = .imported_batch,
    imports: []const RepositoryBatchImport,
};

/// The repository import result (spec "Repository Import Result"): a tagged
/// union over `RepoImportKind`. The JSON `kind` discriminator is carried by each
/// variant struct so the wire shape matches the spec exactly.
pub const RepositoryImportResult = union(RepoImportKind) {
    imported: RepositorySingleImport,
    imported_batch: RepositoryBatch,
    selection: RepositorySelection,
};
