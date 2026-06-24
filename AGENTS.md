# AGENTS.md

Agent-facing context for `skill-importer`. Keep this in sync with the source; the
code and checked-in configuration are the source of truth.

## What this is

A clean-room **Zig 0.16.0** implementation of the `skill-importer` CLI. It
inspects, imports, and manages local AI skills across four roots:

- **canonical** — the promoted third-party collection,
- **imports** — managed draft import storage,
- **claude_code** — Claude Code skills (`~/.claude/skills`),
- **codex** — Codex skills (`~/.agents/skills`).

The normative product contract and data model live in
[`docs/cli-clean-room-spec.md`](./docs/cli-clean-room-spec.md). The
implementation plan and Zig-0.16 notes live in
[`docs/plans/000-zig-clean-room-cli.md`](./docs/plans/000-zig-clean-room-cli.md),
with follow-up refactor plans in [`docs/plans/`](./docs/plans/). The spec is
normative where it and any doc disagree.

`render-analysis-report` and `analyze` are **non-spec extensions** ported from a
v1 Rust analyzer; their oracle is the v1 behavior captured in
`src/analyzer_test.zig` / `src/analyzer_launch_test.zig`, not the spec.

## Build, test, run

Requires **Zig 0.16.0** (pinned in `build.zig.zon` `minimum_zig_version` and CI).
The `Makefile` wraps the common invocations:

| Command          | Runs                    | Purpose                                   |
| ---------------- | ----------------------- | ----------------------------------------- |
| `make build`     | `zig build`             | Compile the binary to `zig-out/bin/skill-importer`. |
| `make test`      | `zig build test`        | Run the full test suite.                  |
| `make fmt-check` | `zig fmt --check src`   | Verify formatting without rewriting.      |
| `make check`     | `fmt-check` then `test` | The pre-commit / CI gate.                 |
| `make run-list`  | `zig build run -- list` | Build and run `list`.                     |
| `make run-tui`   | `zig build run -- tui`  | Build and run `tui` (a stub; exits 1).    |

`zig build run -- <args>` runs the CLI directly. CI
([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) pins Zig 0.16.0 and
runs `zig fmt --check src` + `zig build test` on pushes to `main` and on PRs.

`git` is only needed at runtime for `import repository` against Git URLs; the
test suite never shells out to it (the provider is injected).

### Acceptance verification

`zig build test` is hermetic (injected providers, temp roots). For **black-box**
acceptance, [`docs/manual-verification-plan.md`](./docs/manual-verification-plan.md)
is a 115-case checklist that drives the real built binary with the real
net/git providers. The `verify-skill-importer` skill
(`.claude/skills/verify-skill-importer/`) runs it automatically: a dependency-free
Python harness (stdlib only) builds the binary, exercises every case against
disposable `mktemp` sandbox roots — all four roots **and** `HOME` overridden, so
no real user root is ever touched — and prints per-section PASS / FAIL / N-A /
INDETERMINATE, a machine-readable `SUMMARY`, an id-coverage diff against the plan,
and a binary content hash for sign-off. Run it with
`python3 .claude/skills/verify-skill-importer/harness/run.py` (or
`/verify-skill-importer`); env-gated sections (url, git, macOS `analyze`)
auto-detect and mark N-A when unavailable. The harness's own unit tests are
`python3 -m unittest test_harness` from its `harness/` dir. Where the harness and
plan disagree the plan (and the spec behind it) is normative, except two cases the
case comments flag and the plan rows already reflect (§7.3, §7.10).

## Commands

```text
skill-importer [global-options] <command> [command-options]
```

Global options precede the command word: `--format text|json` and the four
`--{canonical,imports,claude-code,codex}-root PATH` overrides.

- `list` — discover skills across all four roots; missing roots are empty.
- `import markdown|path|url|repository` — import from stdin Markdown, a local
  file/dir, a URL, or a repository (`--select PATH` repeatable; scan depth 8).
- `enable` / `disable` — manage agent symlinks (`--agent claude-code|codex`,
  repeatable, deduped first-seen).
- `promote` / `unpromote` — move an imported draft into/out of the canonical
  root (`--overwrite` to replace an existing canonical copy).
- `delete` — remove an unpromoted, non-enabled imported draft.
- `render-analysis-report --input PATH --output PATH` — **non-spec**: render a
  Codex report JSON to HTML (explicit paths only; no roots, no `HOME`).
- `analyze --skill NAME` — **non-spec, macOS only**, needs the `codex` CLI:
  snapshot a skill into an isolated workspace and launch `codex exec`.
- `tui` — intentional stub: prints `TUI not implemented`, exits 1, rejects
  `--format json`.

Exit codes: `0` success, `1` everything else. Errors are written to stderr as
`skill-importer: <message>`, naming the failing operation and the specific
path/URL/repository/skill.

## Source layout (`src/`)

Every file is colocated with its `*_test.zig`. `root_test.zig` is the test
aggregator — `zig build test` only runs `test {}` blocks reachable from it, so
**every new `*_test.zig` must be `@import`ed in `root_test.zig`** or its tests are
silently skipped.

Entry / wiring:

- `main.zig` — CLI entry: argv → `cli.parse` → `roots.resolve` → command
  dispatch → JSON/text render → flush → exit code. Owns the per-operation arena,
  injects the real clock / net / git / spawner providers, and maps `ErrorInfo` to
  stderr text.
- `cli.zig` — hand-written argument parser; returns a `result.Result(Parsed)`.
- `roots.zig` — independent per-root resolution; `HOME` consulted only when a
  surviving default needs it.
- `types.zig` — domain model: enums/structs mirroring the spec JSON schemas
  field-for-field, in declaration == emit order.
- `result.zig` — tagged `Result(T)` error model carrying `ErrorInfo`
  (kind + name/path/url/repository/field/reason).
- `json_out.zig` — spec JSON emitters; each enum's `@tagName` IS the wire token.

Commands / domain:

- `discovery.zig` — `list`: scan roots, classify entries, merge duplicates.
- `import.zig` — markdown / path / url imports (validate, collision-check,
  atomic store with rollback).
- `repository.zig` — repository scan / selection / batch import.
- `ops.zig` — enable / disable / promote / unpromote / delete planner+executor.
- `manifest.zig` — `import.json` read/write (2-space indent, no trailing newline).
- `frontmatter.zig` — SKILL.md frontmatter parse + skill-name validation.
- `hash.zig` — content hashing (`sha256:` for manifests / directory imports).

Shared deep modules (consolidate logic that used to be duplicated):

- `managed_entry.zig` — the single classifier for "is this a managed symlink
  pointing inside canonical/imports, accounting for symlinked ancestors, and is
  it broken?" `discovery` and `ops` are thin adapters over it.
- `recording_copy.zig` — deterministic, recording recursive directory copy
  (sorted order; rejects symlinks/unsupported). Callers differ only in `Exclude`
  + `Sink`. Distinct from `fsutil.copyTree`, which *recreates* symlinks and
  records nothing.
- `fsutil.zig` — low-level fs helpers isolating Zig-0.16 fs/symlink churn.

Injected providers (keep tests hermetic):

- `net.zig` — `Fetcher` for `import url` (1 MiB cap, 30 s timeout, UTF-8 only).
- `git.zig` — `Provider` for `import repository` (`RealProvider` shells out to
  `git clone --depth 1`; missing git → `error.GitUnavailable`).
- `analyzer.zig` / `analyzer_launch.zig` — non-spec analyzer: pure report/launch
  builders plus the macOS launch with an injected `Spawner`.

`testutil.zig` — test-only helpers; every test runs inside a unique
`std.testing.tmpDir` tree and never touches a real user root.

## Conventions & gotchas

- **Plan-then-execute.** Mutating commands discover state, validate
  sources/destinations, preflight every requested path, then execute and return
  an auditable action list. No earlier target is mutated if a later one is unsafe
  (e.g. multi-`--agent` enable/disable). Unsafe/external agent entries are
  reported and never overwritten.
- **Tagged results, not error sets.** Domain failures flow through
  `result.Result(T)` / `ErrorInfo` so stderr can name the failing operation and
  path. Add new failure modes to `result.ErrorKind` and a message in
  `main.kindMessage`.
- **Arena per operation.** `main.run` scopes one `ArenaAllocator` per
  invocation; result strings are arena-owned and freed on return.
- **Zig 0.16 std.Io.** Code uses the new `std.Io` API (`init.io`, `std.Io.File`,
  `std.Io.Writer`). Don't reach for older `std.fs`/`std.io` spellings.
- **Determinism is load-bearing.** Directory copies and discovery output are
  sorted so action streams and JSON are stable regardless of readdir order.
  `--format json` is the stable, normative output (UTF-8, single trailing
  newline); text output may change — only exit status and filesystem behavior are
  normative.
- **Tests exec the real binary against disposable temp roots only — never real
  user roots.** `build.zig` passes the built binary's path to the integration
  tests via `build_options.exe_path`; `make test` builds before testing.
- **Formatting gate.** `zig fmt --check src` must pass; run `make check` before
  committing.
- **TUI is deferred.** The command exists only as a stub.

## Repo conventions (from global instructions)

- Prefer TDD (red-green-refactor); write tests first.
- Never commit or push directly to `main`; branch first.
- Pull latest from `main` before starting changes unless told otherwise.
- Use the `commit` skill after a turn that edits files, unless told otherwise.
