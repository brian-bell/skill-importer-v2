# skill-importer

A clean-room [Zig](https://ziglang.org/) implementation of the `skill-importer`
command line interface. It inspects, imports, and manages local AI skills across
promoted third-party storage, imported draft storage, Claude Code skills, and
Codex skills.

The product contract and data model are defined in
[`cli-clean-room-spec.md`](./cli-clean-room-spec.md); the implementation plan and
Zig-specific notes live in [`zig-clean-room-cli.md`](./zig-clean-room-cli.md).
This README is a usage and build reference — the spec is normative where they
disagree.

## What it does

- **Inspect** skills found in the canonical, imports, Claude Code, and Codex
  roots (`list`).
- **Import** skills from pasted Markdown, a local file or directory, a URL, or a
  repository (`import markdown|path|url|repository`).
- **Enable / disable** managed skills for Claude Code and Codex by creating or
  removing managed symlinks (`enable`, `disable`).
- **Promote / unpromote** imported draft skills into and out of the canonical
  third-party collection (`promote`, `unpromote`).
- **Delete** unpromoted imported draft skills (`delete`).

All filesystem mutations are plan-then-execute: state is discovered, sources and
destinations are validated, every requested path is preflighted, and only then is
the operation executed. Each command returns an auditable action list. Unsafe or
external agent entries are never overwritten — they are reported and left intact.

## Requirements

- **Zig 0.16.0** (pinned; see `build.zig.zon` `minimum_zig_version` and the CI
  workflow). Other versions are not supported.
- `git` is only needed at runtime for `import repository` against Git URLs.

## Build, test, format

The `Makefile` wraps the common `zig build` invocations:

| Command          | What it runs              | Purpose                                  |
| ---------------- | ------------------------- | ---------------------------------------- |
| `make build`     | `zig build`               | Compile the `skill-importer` binary.     |
| `make test`      | `zig build test`          | Run the full test suite.                 |
| `make fmt-check` | `zig fmt --check src`     | Verify formatting without rewriting.     |
| `make check`     | `fmt-check` then `test`   | The pre-commit / CI gate.                |
| `make run-list`  | `zig build run -- list`   | Build and run `list`.                    |
| `make run-tui`   | `zig build run -- tui`    | Build and run `tui` (see TUI note below).|

The built binary is written to `./zig-out/bin/skill-importer`. The test suite is
the primary oracle: the integration tests exec the real binary against
**disposable temp roots only** — never real user roots.

CI ([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) pins Zig to 0.16.0
and runs `zig fmt --check src` and `zig build test` on every push to `main` and
on every pull request.

## Usage

```text
skill-importer [global-options] <command> [command-options]
```

### Global options

Global options come before the command word. Each root may be overridden
independently; `--format` selects the output format.

| Option                  | Value          | Default                                       |
| ----------------------- | -------------- | --------------------------------------------- |
| `--format`              | `text \| json` | `text`                                        |
| `--canonical-root`      | `PATH`         | `<agent-skills-repo>/third-party`             |
| `--imports-root`        | `PATH`         | `<runtime-root>/.skill-importer/imports`      |
| `--claude-code-root`    | `PATH`         | `~/.claude/skills`                            |
| `--codex-root`          | `PATH`         | `~/.agents/skills`                            |

`--format json` emits the stable, normative JSON described in the spec (UTF-8,
deterministic, terminated by a single newline). `--format text` emits a short
human summary; its exact text may change, but exit status and filesystem behavior
always match the spec.

### Commands

```text
skill-importer [global-options] list
skill-importer [global-options] import markdown [--source-location VALUE]
skill-importer [global-options] import path --path PATH
skill-importer [global-options] import url --url URL
skill-importer [global-options] import repository --repository REPOSITORY [--select PATH ...]
skill-importer [global-options] enable    --skill NAME --agent claude-code|codex [--agent ...]
skill-importer [global-options] disable   --skill NAME --agent claude-code|codex [--agent ...]
skill-importer [global-options] promote   --skill NAME [--overwrite]
skill-importer [global-options] unpromote --skill NAME
skill-importer [global-options] delete    --skill NAME
skill-importer [global-options] render-analysis-report --input PATH --output PATH
skill-importer [global-options] tui
```

- `list` — discover skills across all four roots; missing roots are treated as
  empty. JSON output groups repository-imported skills under
  `source_repositories`.
- `import markdown` — read Markdown from **stdin**, validate `SKILL.md`
  frontmatter, and write `<imports-root>/<name>/SKILL.md` plus `import.json`.
- `import path` — import a local Markdown file or a local skill directory.
  Directories are copied recursively; symlinks, unsupported entries, and a
  reserved source `import.json` are rejected.
- `import url` — fetch Markdown from `URL` (bounded size, finite timeout, UTF-8
  required) and store it as an imported skill. No partial storage is left on
  failure.
- `import repository` — scan a Git URL or local path for valid skills. With one
  skill and no `--select`, it imports immediately; with several and no
  `--select`, it returns a selection result; `--select` is repeatable. Batch
  imports preflight all selections and roll back on a later write failure. The
  scan depth limit is **8**.
- `enable` / `disable` — manage agent symlinks for one or more agents. `--agent`
  is repeatable and deduplicated in first-seen order; all requested agents are
  preflighted before any mutation, so no agent is changed if a later one is
  unsafe.
- `promote` — copy an imported draft into the canonical root (excluding
  `import.json`), mark the manifest promoted, and relink managed symlinks.
  `--overwrite` is required to replace an existing canonical copy.
- `unpromote` — remove the canonical copy and managed symlinks, marking the
  import an unpromoted draft.
- `delete` — remove an unpromoted, non-enabled imported draft.
- `render-analysis-report` — **non-spec extension** (not part of
  `cli-clean-room-spec.md`). Read a skill-analysis report JSON from `--input`,
  render it to a self-contained HTML document, and write it to `--output`. The
  input must be a regular file (symlinks are refused) and the output is created
  fresh (an existing file is never overwritten). Operates on explicit paths only:
  it needs no roots and no `HOME`.

`--skill`, `--path`, `--url`, `--repository`, `--source-location`, `--input`, and
`--output` are single-value options; `--agent` and `--select` are repeatable;
`--overwrite` is a flag.

### Exit codes

- `0` — success.
- `1` — any command parse, validation, discovery, import, or filesystem failure.
  Errors are written to stderr as `skill-importer: <message>`, naming the failing
  operation and the specific path, URL, repository, or skill where applicable.

### TUI

`tui` is intentionally a stub in this build: it prints `TUI not implemented` and
exits `1`, and it rejects `--format json`. The interactive UI is a deferred,
separate effort. `make run-tui` therefore exits non-zero by design.

## Root resolution

Every command operates over four roots — `canonical_root`, `imports_root`,
`claude_code_root`, and `codex_root`. Each is resolved **independently**: an
explicit `--*-root` override is used verbatim; otherwise a per-root default is
computed.

Defaults:

- `canonical_root` = `<agent-skills-repo>/third-party`, where
  `agent-skills-repo` is `$AGENT_SKILLS_REPO` when set, otherwise
  `$HOME/dev/agent-skills`.
- `imports_root` = `<runtime-root>/.skill-importer/imports`.
- `claude_code_root` = `$HOME/.claude/skills`.
- `codex_root` = `$HOME/.agents/skills`.

`runtime-root` is the nearest ancestor of the current working directory
(inclusive) that contains **both** `AGENTS.md` and `catalog/portable/`. If no
such ancestor exists, `runtime-root` is the current working directory.

`HOME` is consulted **only** when a surviving default needs it, and it must be an
absolute path. Providing all four roots explicitly never requires `HOME`.

Missing roots are valid and are treated as empty during discovery. Mutating
commands create only the roots they need for the specific operation.

## Examples

Run against disposable roots so real user storage is never touched:

```bash
zig build

ROOTS=(
  --canonical-root  .skill-importer/dev/canonical
  --imports-root    .skill-importer/dev/imports
  --claude-code-root .skill-importer/dev/claude
  --codex-root      .skill-importer/dev/codex
)

# Inspect (empty inventory when roots are missing).
./zig-out/bin/skill-importer "${ROOTS[@]}" --format json list

# Import a skill from stdin, promote it, and enable it for Claude Code.
printf '%s\n' '---' 'name: demo' 'description: a demo skill' '---' \
  | ./zig-out/bin/skill-importer "${ROOTS[@]}" import markdown
./zig-out/bin/skill-importer "${ROOTS[@]}" promote --skill demo
./zig-out/bin/skill-importer "${ROOTS[@]}" enable --skill demo --agent claude-code

# See the result.
./zig-out/bin/skill-importer "${ROOTS[@]}" --format json list
```

## Project layout

```text
build.zig          # build graph: exe, `run` step, and `test` step
build.zig.zon      # package manifest; pins minimum_zig_version 0.16.0
Makefile           # build / test / fmt-check / check / run-list / run-tui
.github/workflows/ # CI: pinned Zig 0.16.0 + fmt-check + test
src/               # CLI source and tests (root_test.zig is the test entry)
cli-clean-room-spec.md   # normative product contract and data model
zig-clean-room-cli.md    # implementation plan and Zig 0.16 notes
```
