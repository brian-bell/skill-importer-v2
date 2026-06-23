# Skill Importer CLI Clean-Room Specification

This document specifies the `skill-importer` command line interface in a
language- and framework-independent way. It is intended for a clean-room rewrite:
implementations should preserve the product contract and data model described
here, but do not need to preserve parser quirks, Rust module boundaries, or
backward-incompatible command details from the current implementation.

## Goals

- Inspect local AI skills across promoted third-party storage, imported draft
  storage, Claude Code skills, and Codex skills.
- Import skills from pasted Markdown, local files or directories, URLs, and
  repositories.
- Enable and disable managed skills for Claude Code and Codex by creating or
  removing managed symlinks.
- Promote imported draft skills into the promoted third-party collection.
- Delete unpromoted imported draft skills.
- Expose stable JSON for automation and a human-friendly CLI contract for
  operators.
- Keep filesystem mutations safe, predictable, and auditable through action
  reports.

## Non-Goals

- The specification does not prescribe an implementation language, CLI parsing
  library, HTTP client, terminal UI framework, or JSON serializer.
- The specification does not require compatibility with current parser edge
  cases such as accepting duplicate singleton flags or requiring `--json` on
  every automation command.
- The specification does not define the internal TUI reducer or rendering
  architecture, except where the CLI launches the TUI.

## Terms

- **Skill**: A directory containing `SKILL.md`, or a standalone Markdown source
  that can be materialized as a directory containing `SKILL.md`.
- **Skill name**: The `name` field in `SKILL.md` frontmatter. It must be one
  directory-safe path segment, not empty, not `.` or `..`, and not contain path
  separators.
- **Description**: The `description` field in `SKILL.md` frontmatter. It must
  be present and non-empty for importable skills.
- **Canonical root**: The promoted third-party skill collection. Promoted
  imports are copied here.
- **Imports root**: Managed draft import storage. Each imported skill lives in
  `<imports-root>/<skill-name>`.
- **Agent root**: The per-agent skill directory. Claude Code and Codex each have
  a root.
- **Managed symlink**: A symlink in an agent root whose target is a skill in the
  canonical root or imports root.
- **External entry**: A real directory, regular file, broken symlink, or symlink
  to a target outside managed roots.
- **Agent-only skill**: A skill found only through an agent root entry, not in
  canonical or imported storage.

## Root Resolution

Every command that reads or mutates skills operates over these roots:

- `canonical_root`
- `imports_root`
- `claude_code_root`
- `codex_root`

The CLI must allow each root to be overridden explicitly. A clean-room CLI should
use global options so commands have consistent syntax:

```text
skill-importer [global-options] <command> [command-options]

Global options:
  --canonical-root PATH
  --imports-root PATH
  --claude-code-root PATH
  --codex-root PATH
  --format text|json
```

Default root resolution:

- `canonical_root` defaults to `<agent-skills-repo>/third-party`.
- `agent-skills-repo` is `AGENT_SKILLS_REPO` when set, otherwise
  `~/dev/agent-skills`.
- `imports_root` defaults to `<runtime-root>/.skill-importer/imports`.
- `claude_code_root` defaults to `~/.claude/skills`.
- `codex_root` defaults to `~/.agents/skills`.

`runtime-root` is the nearest ancestor of the current working directory that
contains both `AGENTS.md` and `catalog/portable/`. If no such ancestor exists,
`runtime-root` is the current working directory.

If a default requires `HOME`, `HOME` must be set to an absolute path. Explicitly
providing all roots must not require `HOME`.

Missing roots are valid and are treated as empty during discovery. Mutating
commands create only the roots they need for the specific operation.

## Skill Metadata

`SKILL.md` metadata is parsed from leading YAML-like frontmatter:

```markdown
---
name: example-skill
description: Example description.
---
```

The importer only needs to recognize `name:` and `description:` lines before the
closing delimiter. Values are trimmed. Unknown frontmatter fields may be ignored.

Import validation fails before storage is created when:

- The opening `---` delimiter is missing.
- The closing `---` delimiter is missing.
- `name` is missing or empty.
- `name` is not a single directory-safe path segment.
- `description` is missing or empty.

## Import Manifest

Each imported skill directory must contain `import.json`:

```json
{
  "source_type": "markdown",
  "source_location": "clipboard",
  "source_repository": {
    "repository": "https://example.test/skills.git",
    "skill_path": "helpers/example-skill"
  },
  "imported_at": 1710000000,
  "content_hash": "sha256:...",
  "promoted": false
}
```

Fields:

- `source_type`: One of `markdown`, `local_path`, `url`, `repository`.
- `source_location`: Optional source identifier. For repository imports, use
  `<repository>#<relative-skill-path>`.
- `source_repository`: Optional. Present for repository imports and omitted for
  other source types.
- `imported_at`: Unix timestamp in seconds.
- `content_hash`: SHA-256 content hash string prefixed with `sha256:`.
- `promoted`: Boolean indicating whether this imported skill has a promoted copy
  in the canonical root.

Promoting a skill must not copy `import.json` into the canonical root.

## Output Contract

Commands should support `--format json` for stable automation output and
`--format text` for human output. JSON output is normative in this spec. Text
output may vary by implementation as long as exit status and filesystem behavior
match this document.

Successful JSON output must be UTF-8, pretty-printed or otherwise deterministic,
and terminated by a newline.

Errors must be written to stderr and return a non-zero exit code. Error text
should include the failing operation and the specific path, URL, repository, or
skill name where applicable. Implementations may provide additional structured
error JSON in the future, but stderr plus non-zero exit is the required minimum.

Exit codes:

- `0`: Success.
- `1`: Command parse error, validation error, discovery error, import error, or
  failed filesystem operation.

## JSON Schemas

### Inventory

`list --format json` returns:

```json
{
  "skills": [
    {
      "name": "example-skill",
      "description": "Example description.",
      "source": "canonical",
      "source_repository": {
        "repository": "https://example.test/skills.git",
        "skill_path": "helpers/example-skill"
      },
      "promoted": false,
      "enablement": {
        "claude_code": true,
        "codex": false
      },
      "agent_entries": {
        "claude_code": "canonical_symlink",
        "codex": "missing"
      }
    }
  ],
  "source_repositories": [
    {
      "repository": "https://example.test/skills.git",
      "skills": [
        {
          "skill_name": "example-skill",
          "skill_path": "helpers/example-skill"
        }
      ]
    }
  ]
}
```

`source` values:

- `canonical`
- `imported`
- `agent_only`

`agent_entries` values:

- `missing`
- `skill_directory`
- `canonical_symlink`
- `imported_symlink`
- `external_symlink`
- `broken_symlink`

Enablement booleans are true for `skill_directory`, `canonical_symlink`,
`imported_symlink`, and `external_symlink`; false for `missing` and
`broken_symlink`.

`source_repository` appears only on imported skill entries that have repository
metadata. `source_repositories` groups imported repository skills by repository.

### Import Result

Markdown, path, and URL imports return:

```json
{
  "skill_name": "example-skill",
  "skill_path": "/abs/path/imports/example-skill",
  "manifest_path": "/abs/path/imports/example-skill/import.json",
  "manifest": {
    "source_type": "url",
    "source_location": "https://example.test/example-skill.md",
    "imported_at": 1710000000,
    "content_hash": "sha256:...",
    "promoted": false
  },
  "actions": [
    {
      "action": "create_directory",
      "path": "/abs/path/imports/example-skill"
    },
    {
      "action": "write_skill",
      "path": "/abs/path/imports/example-skill/SKILL.md"
    },
    {
      "action": "write_manifest",
      "path": "/abs/path/imports/example-skill/import.json"
    }
  ]
}
```

Import action values:

- `create_directory`
- `write_skill`
- `copy_file`
- `write_manifest`

### Repository Import Result

Repository imports always include a `kind` discriminator. A single repository
skill import returns `kind: "imported"` plus the import result fields:

```json
{
  "kind": "imported",
  "skill_name": "repo-alpha",
  "skill_path": "/abs/path/imports/repo-alpha",
  "manifest_path": "/abs/path/imports/repo-alpha/import.json",
  "manifest": {
    "source_type": "repository",
    "source_location": "https://example.test/skills.git#repo-alpha",
    "source_repository": {
      "repository": "https://example.test/skills.git",
      "skill_path": "repo-alpha"
    },
    "imported_at": 1710000000,
    "content_hash": "sha256:...",
    "promoted": false
  },
  "actions": []
}
```

When a repository has multiple valid skills and no selection was provided, the
CLI returns a selection result without writing storage:

```json
{
  "kind": "selection",
  "repository": "https://example.test/skills.git",
  "skills": [
    {
      "name": "repo-alpha",
      "description": "First repository skill.",
      "relative_path": "repo-alpha"
    }
  ]
}
```

When multiple selected repository skills are imported:

```json
{
  "kind": "imported_batch",
  "imports": [
    {
      "skill_name": "repo-alpha",
      "skill_path": "/abs/path/imports/repo-alpha",
      "manifest_path": "/abs/path/imports/repo-alpha/import.json",
      "manifest": {
        "source_type": "repository",
        "source_location": "https://example.test/skills.git#repo-alpha",
        "source_repository": {
          "repository": "https://example.test/skills.git",
          "skill_path": "repo-alpha"
        },
        "imported_at": 1710000000,
        "content_hash": "sha256:...",
        "promoted": false
      },
      "actions": []
    }
  ]
}
```

### Skill Operation Result

Enable, disable, promote, unpromote, and delete return:

```json
{
  "skill_name": "example-skill",
  "actions": [
    {
      "action": "create_symlink",
      "agent": "codex",
      "path": "/abs/path/.agents/skills/example-skill",
      "target": "/abs/path/agent-skills/third-party/example-skill"
    }
  ]
}
```

Skill operation action values:

- `create_directory`
- `create_symlink`
- `remove_symlink`
- `copy_file`
- `write_manifest`
- `remove_directory`
- `skip_unchanged`

`agent` is present for agent-root actions and omitted for collection actions.
`target` is present for symlink actions and skip actions involving an agent
entry. `source` is present for copy and promotion actions when useful.

## Commands

### `list`

```text
skill-importer [global-options] list
```

Discovers skills from canonical root, imports root, Claude Code root, and Codex
root. Missing roots are treated as empty.

Discovery behavior:

- Canonical and imported skills are identified by valid `SKILL.md` metadata.
- Imported skills may include `import.json`; malformed `import.json` for an
  otherwise valid imported skill is an error.
- Agent-root entries are classified by entry type and symlink target.
- Skill entries are returned in deterministic order by skill name.
- Repository-imported skills are grouped in `source_repositories`.

### `import markdown`

```text
skill-importer [global-options] import markdown [--source-location VALUE]
```

Reads all Markdown from stdin, validates `SKILL.md` frontmatter, and writes:

- `<imports-root>/<skill-name>/SKILL.md`
- `<imports-root>/<skill-name>/import.json`

`source_type` is `markdown`. `source_location` is the optional
`--source-location` value.

### `import path`

```text
skill-importer [global-options] import path --path PATH
```

Imports a local Markdown file or a local skill directory.

Markdown file behavior:

- The file is read as UTF-8 text.
- The destination is `<imports-root>/<skill-name>/SKILL.md`.
- `source_type` is `local_path`.
- `source_location` is the source path string.

Directory behavior:

- The directory must contain `SKILL.md`.
- Regular files and directories are recursively copied.
- Symlinks and unsupported filesystem entries are rejected.
- `import.json` in the source directory is reserved and must be rejected.
- The imports root must not be inside the source directory.
- The directory content hash includes supporting files and relative paths.

### `import url`

```text
skill-importer [global-options] import url --url URL
```

Fetches Markdown from `URL`, validates it, and stores it as an imported skill.

Requirements:

- Use a bounded response size. The current product limit is 1 MiB; clean-room
  implementations should keep that limit unless a new limit is explicitly
  chosen.
- Reject invalid UTF-8.
- Use a finite network timeout.
- On fetch, size, UTF-8, or validation failure, do not create import storage.
- `source_type` is `url`.
- `source_location` is the URL.

### `import repository`

```text
skill-importer [global-options] import repository --repository REPOSITORY [--select PATH ...]
```

Fetches or opens a repository, scans for valid skills, and imports one or more
selected skill directories. `REPOSITORY` may be a Git URL, local path, or any
source supported by the implementation.

Repository scan behavior:

- Valid skills are directories containing valid `SKILL.md` metadata.
- The repository root may itself be a skill.
- If the repository root has invalid `SKILL.md`, fail; do not skip it and import
  nested skills.
- Skip skills beyond the repository scan depth limit. The current product uses
  depth `8`; clean-room implementations may choose another explicit limit but
  must document and test it.
- Return a selection result when more than one valid skill exists and no
  `--select` was provided.
- Import immediately when exactly one valid skill exists and no `--select` was
  provided.
- `--select` values identify repository-relative skill directories. Normalize
  `.` and `./name` consistently.
- Duplicate normalized selections are errors.
- A selected path that does not match a discovered valid skill is an error.
- Batch imports must preflight all selected skills before writing any storage.
- If a later batch write fails, previously written imports from that batch must
  be rolled back.

Repository import manifests use:

- `source_type`: `repository`
- `source_location`: `<repository>#<relative-skill-path>`
- `source_repository.repository`: the repository argument
- `source_repository.skill_path`: the repository-relative skill path, or `.`
  for a root skill

### `enable`

```text
skill-importer [global-options] enable --skill NAME --agent claude-code|codex [--agent ...]
```

Enables a canonical skill or promoted import for one or more agents.

Behavior:

- Unknown skills fail.
- Agent-only skills fail.
- Unpromoted imports fail.
- Promoted imports are enabled by symlinking to the canonical promoted copy, not
  to the draft import directory.
- Agent requests are deduplicated in first-seen order.
- The operation must preflight all requested agents before mutating any of them.
- If an agent entry is missing, create the agent root if needed and create a
  symlink.
- If an agent entry is already the correct managed symlink, return
  `skip_unchanged`.
- If an agent entry is a real directory, regular file, broken symlink, external
  symlink, or symlink to the wrong managed target, fail and leave it untouched.

### `disable`

```text
skill-importer [global-options] disable --skill NAME --agent claude-code|codex [--agent ...]
```

Disables a managed skill for one or more agents.

Behavior:

- Unknown skills fail.
- Agent-only skills fail.
- Canonical skills, promoted imports, and legacy enabled unpromoted imports may
  be disabled.
- Agent requests are deduplicated in first-seen order.
- The operation must preflight all requested agents before mutating any of them.
- If the agent entry is the correct managed symlink, remove it.
- If the agent entry is missing, return `skip_unchanged`.
- Unsafe entries are rejected and left untouched.

### `promote`

```text
skill-importer [global-options] promote --skill NAME [--overwrite]
```

Copies an imported draft skill from imports root to canonical root and marks its
manifest as promoted.

Behavior:

- Unknown skills fail.
- Canonical skills and agent-only skills fail.
- Already promoted imports fail.
- Existing canonical destination fails unless `--overwrite` is provided.
- Even with `--overwrite`, an existing destination whose `SKILL.md` frontmatter
  has a different `name` must fail.
- Frontmatter name collisions elsewhere in canonical root must fail.
- Unsupported entries inside the import directory, such as symlinks, must fail.
- Existing unsafe agent entries for the skill must fail before mutation.
- Promotion copies skill content and supporting files but excludes top-level
  `import.json`.
- Promotion sets the draft import manifest `promoted` field to true.
- Existing managed symlinks that point to the import directory must be relinked
  to the canonical promoted copy.
- With `--overwrite`, the existing canonical copy must not be removed until the
  replacement copy is known to be valid and ready.

### `unpromote`

```text
skill-importer [global-options] unpromote --skill NAME
```

Removes the canonical promoted copy of an imported skill and marks the import as
an unpromoted draft.

Behavior:

- Unknown skills fail.
- Canonical-only and agent-only skills fail.
- Unpromoted imports fail.
- Managed agent symlinks to the canonical promoted copy are removed.
- The canonical copy is removed.
- The draft import manifest `promoted` field is set to false.

This command is part of the clean-room CLI even though it may have been
available only through lower-level workflow or TUI paths in older
implementations.

### `delete`

```text
skill-importer [global-options] delete --skill NAME
```

Deletes an unpromoted imported draft skill.

Behavior:

- Unknown skills fail.
- Canonical and agent-only skills fail.
- Promoted imports fail; unpromote first.
- Imports enabled through legacy managed import symlinks fail; disable first.
- Unrelated same-name unsafe agent entries do not block deletion and must be
  left untouched.
- Successful deletion removes `<imports-root>/<skill-name>`.

### `tui`

```text
skill-importer [global-options] tui
```

Launches the interactive TUI using the same root resolution rules. The TUI owns
terminal output. It should expose the same operations as the CLI where practical
and must use the same core filesystem safety rules.

## Collision Rules

Import commands:

- Refuse collisions within imports root by directory name or by `SKILL.md`
  frontmatter name.
- Allow collisions with canonical root. This supports replacement drafts that
  may later be promoted with explicit overwrite.

Promote:

- Refuse canonical root collisions unless overwrite is explicit.
- Refuse frontmatter name collisions anywhere in canonical root, including when
  the colliding directory has a different directory name.

Repository batch import:

- Refuse duplicate selected skill names before writing.
- Refuse existing imports-root collisions before writing.
- Allow canonical collisions as replacement drafts.

## Filesystem Safety

Implementations must treat filesystem operations as plan-then-execute workflows:

1. Discover current state.
2. Validate source metadata and destination safety.
3. Preflight all requested paths for an operation.
4. Execute only after preflight succeeds.
5. Return an action list describing what happened.

For multi-agent operations, no earlier agent may be mutated if a later requested
agent has an unsafe entry.

Operations must not remove, overwrite, or replace external entries in agent
roots. Unsafe entries must be reported with their path and left intact.

Partially completed operations caused by unexpected I/O errors should report the
actions that completed before the failure when the implementation can do so.

## Recommended TDD Acceptance Suite

A clean-room implementation should be built with tests first around these public
behaviors:

- `list` returns deterministic JSON for canonical, imported, promoted, enabled,
  external, broken, and agent-only skills.
- Missing roots produce an empty inventory rather than an error.
- Malformed import manifests for valid imported skills fail discovery.
- Markdown imports validate frontmatter and leave no partial storage on failure.
- Local directory imports preserve supporting files and reject symlinks,
  reserved `import.json`, and imports roots inside the source directory.
- URL imports enforce timeout, UTF-8, and size limits with no partial storage on
  failure.
- Repository imports cover single import, selection, selected import, batch
  import, duplicate selections, missing selections, duplicate skill names,
  rollback on batch failure, root skill imports, invalid root `SKILL.md`, empty
  repositories, and depth-limit behavior.
- Enable and disable cover idempotence, agent order, duplicate agents, unsafe
  entries, unknown skills, agent-only skills, unpromoted imports, and atomic
  multi-agent preflight.
- Promote covers support-file copying, manifest updates, excluding `import.json`,
  relinking managed import symlinks, canonical collisions, overwrite, unsafe
  agent entries, unsupported import entries, and already-promoted imports.
- Unpromote covers removing canonical copies, removing managed agent symlinks,
  manifest updates, and invalid source states.
- Delete covers successful unpromoted import deletion, blocking promoted or
  enabled imports, canonical and agent-only errors, and preserving unrelated
  same-name agent entries.
- Every JSON-producing command emits valid UTF-8 JSON with a trailing newline.
- Every failing command returns a non-zero exit status and writes actionable
  stderr.
