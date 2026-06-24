# Clean-Room `skill-importer` CLI in Zig (TDD)

## Context

This plan implements [`docs/cli-clean-room-spec.md`](../docs/cli-clean-room-spec.md)
from scratch in **Zig (latest stable, 0.16.0 on this machine)** using strict
test-driven development.

It is intentionally **different** from [`plans/zig-rewrite.md`](./zig-rewrite.md):

| | `zig-rewrite.md` | this plan |
|---|---|---|
| Source of truth | the existing **Rust source + `tests/*.rs`** (byte-for-byte parser/test parity) | the **clean-room spec** (product contract only) |
| Zig target | 0.15.1 (pinned) | **0.16.0** (latest stable) |
| `--json` | per-command `--json` flag (Rust quirk) | global `--format text\|json` |
| `unpromote` | core only, no CLI | **first-class CLI command** |
| repo import CLI | TUI-only stub | **first-class CLI command** with `--select` |
| Parser quirks | reproduce clap strings exactly | free to choose clean syntax |
| TUI | deferred Phase 7 | deferred (command exists, prints "not implemented") |

The clean-room spec explicitly frees us from parser quirks, Rust module
boundaries, and content-hash byte layout. The acceptance oracle is **the test
suite we write against the spec**, not the Rust binary. We own a fresh imports
store; we do not read or migrate Rust's `.skill-importer/imports`.

Because there is no Rust behavior to byte-match, **every behavior in this plan is
specified by a test written first**. The spec's "Recommended TDD Acceptance
Suite" (spec §"Recommended TDD Acceptance Suite") is the backbone of the test
matrix below.

## Decisions locked in

- **Target Zig 0.16.0.** `build.zig.zon` sets `.minimum_zig_version = "0.16.0"`;
  CI pins the same. (The other plan targets 0.15.1 — do not mix.)
- **Imports root default:** `<runtime-root>/.skill-importer/imports` per spec
  §"Root Resolution". Fresh store; no migration of any prior tool's data.
- **Repository scan depth limit = 8** (spec allows another explicit limit, but
  requires documenting + testing it; we keep 8 and test the boundary).
- **URL fetch limits:** 1 MiB body cap, 30 s timeout, reject invalid UTF-8 (spec
  §`import url`). `std.http.Client` has no socket timeout in 0.16; implement the
  deadline with a worker thread (best-effort; socket may linger — documented).
- **Content hash:** SHA-256 over a deterministic encoding of skill content +
  supporting files + relative paths. The byte layout is **our choice** (spec does
  not prescribe it); we lock it with a Zig-computed golden test, not a Rust value.
- **Output:** `--format json` is normative and tested per the spec schemas;
  `--format text` is human-only and only asserted for exit status + key
  substrings. JSON stdout ends in exactly one `\n`; on-disk `import.json` has
  **no** trailing newline.
- **TUI:** `tui` subcommand parses roots, rejects `--format json`, and exits
  non-zero with "TUI not implemented" until a later effort. Spec §`tui` allows
  the TUI to be deferred as long as the CLI contract holds.
- **No analyzer / no `render-analysis-report`** — not in the spec.

## Target module layout

```
build.zig
build.zig.zon
Makefile
src/
  main.zig          # entry: parse argv, resolve roots, dispatch, render, exit code
  cli.zig           # hand-written arg parser: global options + subcommands
  roots.zig         # root resolution (env, HOME, runtime-root detection)
  types.zig         # domain enums + structs (Skill, Source, AgentEntryStatus, ...)
  result.zig        # Result(T) tagged union + ErrorInfo payload
  frontmatter.zig   # SKILL.md frontmatter parse + validate_skill_name
  manifest.zig      # import.json read/write
  hash.zig          # content hashing (string + directory tree)
  fsutil.zig        # symlink-safe classify, recursive copy, lexical resolve
  discovery.zig     # list: scan all roots, merge, order
  import.zig        # markdown / path / url import + collision + rollback
  repository.zig    # repo scan (BFS depth-8), selection, batch import + rollback
  ops.zig           # enable / disable / promote / unpromote / delete planner+exec
  json_out.zig      # spec JSON emitters (explicit, declaration-order)
  net.zig           # URL fetch (size/timeout/utf8), injectable
  git.zig           # repo fetch provider, injectable (struct-of-fn-pointers)
  root_test.zig     # aggregates every *_test by @import (MANDATORY for `zig build test`)
tests/              # fixture-heavy integration tests (one file per spec area)
plans/
```

Modules expose pure, allocator-threaded functions returning `Result(T)`. Side
effects (network, git, clock) are injected so tests stay hermetic.

## Dependency mapping (no third-party deps)

| Need | Zig 0.16.0 std |
|---|---|
| JSON output | `std.json.Stringify` struct, method-driven emitter (key order == call order) |
| JSON parse (manifest) | `std.json.parseFromSlice(T, gpa, bytes, .{ .ignore_unknown_fields = true })` |
| SHA-256 | `std.crypto.hash.sha2.Sha256` (`init`/`update`/`final`) |
| URL fetch | `std.http.Client` (no timeout → worker thread; body → `*std.Io.Writer`) |
| Filesystem | `std.Io.Dir` (`.cwd()`), `std.Io.File`, `std.fs.path.{resolve,join,...}` |
| Recursive ops | `Dir.walk` + `makePath` + manual symlink recreate (`readLink`+`symLink`) |
| Subprocess (git) | `std.process.Child.run(.{ .argv = &.{...} })` |
| Lists | `std.ArrayList(T)` — **unmanaged**: `.empty`, `append(alloc, x)`, `deinit(alloc)` |
| Allocation | arena per CLI operation, freed at command end; tests use `std.testing.allocator` |

## Zig 0.16.0 API notes (verified on this machine, load-bearing)

These were probed against the installed 0.16.0 std; the 0.15→0.16 churn makes
them easy to get wrong, so treat each as a thing a test must confirm:

- **`std.fs.Dir`/`std.fs.cwd` are gone.** Use `std.Io.Dir` and
  `std.Io.Dir.cwd()`. File handles are `std.Io.File`. Many fs operations now take
  an `Io` instance — thread one `std.Io` through fsutil; **verify each call's
  signature against the local std** in Phase 1 rather than assuming the 0.15 form.
- **Writergate:** stdout is `File.stdout().writer(&buf)` → `&fw.interface`; you
  **must flush** before exit. Custom formatters are `fn format(self,
  *std.Io.Writer) Error!void`, invoked with `{f}`.
- **`std.json.Stringify`** is the struct emitter (no lowercase `stringify`, no
  `writeStream`). Drive it explicitly: `beginObject`/`objectField`/`write`/
  `endObject`. `Options{ .whitespace = .indent_2 }`. `emit_null_optional_fields`
  defaults true — for omit-vs-null fields, only call `objectField` when present.
- **`std.Io.Writer.Allocating`** exists — use for the bounded URL body buffer,
  checking `written().len > 1<<20` after the fact.
- **`std.ArrayList` is unmanaged.** `var l: std.ArrayList(T) = .empty;
  try l.append(gpa, x); defer l.deinit(gpa);`.
- **`statFile` follows symlinks.** Classify agent entries by directory-iteration
  `entry.kind == .sym_link` or `fstatat(..., AT.SYMLINK_NOFOLLOW)`. Resolve
  symlink targets **lexically** with `std.fs.path.resolve`, never `realpath`
  (which requires existence and dereferences).
- **`build.zig`:** `addExecutable`/`addTest` need `.root_module =
  b.createModule(...)`. `build.zig.zon` needs `.name` as enum literal
  (`.skill_importer`), `.fingerprint`, `.minimum_zig_version`, `.paths`, empty
  `.dependencies`.
- **Test discovery:** `zig build test` only runs `test{}` blocks reachable from
  the root module. `src/root_test.zig` must `@import` every test file or those
  tests are **silently skipped**.

## Domain model (`types.zig`)

```zig
pub const SkillSource = enum { canonical, imported, agent_only };

pub const AgentEntryStatus = enum {
    missing, skill_directory, canonical_symlink,
    imported_symlink, external_symlink, broken_symlink,
};
// enabled == one of {skill_directory, canonical_symlink, imported_symlink, external_symlink}
// disabled == {missing, broken_symlink}     (spec §Inventory)

pub const ImportSourceType = enum { markdown, local_path, url, repository };
pub const ImportActionKind = enum { create_directory, write_skill, copy_file, write_manifest };
pub const SkillActionKind = enum {
    create_directory, create_symlink, remove_symlink,
    copy_file, write_manifest, remove_directory, skip_unchanged,
};
pub const Agent = enum { claude_code, codex }; // CLI input "claude-code"; JSON "claude_code"
pub const RepoImportKind = enum { imported, imported_batch, selection };
```

`SkillEntry`, `SourceRepository`, `ImportManifest`, `ImportResult`,
`RepositoryImportResult` (tagged union on `RepoImportKind`),
`SkillOperationResult`, `SkillAction`, `ImportAction` mirror the spec's JSON
schemas field-for-field, in declaration order = emit order.

## Error model (`result.zig`)

Zig error sets carry no payload, but the spec requires stderr to name the failing
operation and the specific path/URL/repo/skill. Use a tagged result:

```zig
pub fn Result(comptime Ok: type) type {
    return union(enum) { ok: Ok, err: ErrorInfo };
}
pub const ErrorInfo = struct {
    kind: ErrorKind,
    name: ?[]const u8 = null, path: ?[]const u8 = null,
    field: ?[]const u8 = null, reason: ?[]const u8 = null,
    url: ?[]const u8 = null, repository: ?[]const u8 = null,
    // actions completed before an unexpected I/O failure (spec §Filesystem Safety);
    // test-observable, NOT serialized to user JSON
    partial_actions: std.ArrayList(SkillAction) = .empty,
};
```

`ErrorKind` enumerates every spec failure (unknown skill, agent-only, not
promoted, already promoted, collision, canonical collision, unsafe agent entry,
unsupported entry, validation, fetch failure, size exceeded, invalid utf8,
duplicate selection, missing selection, depth, …). `main.zig` renders
`"skill-importer: " ++ message(err)` to stderr and exits 1 (spec exit codes:
0 success, 1 everything else). All strings arena-owned.

## TDD methodology

Follow red → green → refactor for every behavior; use the `tdd` skill mindset.

1. **Write the failing test first** from the spec clause it covers. Reference the
   spec section in a comment so the test is auditable against the contract.
2. Run `zig build test` (or `zig test` on the file) and confirm it fails for the
   *right* reason.
3. Implement the minimum to pass.
4. Refactor with the test green.
5. Commit per the repo's `commit` skill after each green slice.

**Test infrastructure built first (Phase 1):**

- `src/root_test.zig` aggregator (without it tests silently don't run).
- A `TmpRoots` test helper: creates a unique temp dir tree with
  canonical/imports/claude/codex subroots, returns resolved root paths, and
  `deinit` deletes the tree. **Never** touch real `~/.claude/skills` /
  `~/.agents/skills` (CLAUDE.md hard rule).
- A fixture builder: write a `SKILL.md` with given frontmatter, write
  `import.json`, create symlinks (managed/external/broken), create real dirs and
  stray files — so each `AgentEntryStatus` case is constructible.
- A **fake net provider** (`net.Fetcher` = struct of fn pointers): returns canned
  bytes / sizes / errors; tested separately against a loopback `std.http.Server`
  for the real path.
- A **fake git provider** (`git.Provider` = struct of fn pointers): "checks out"
  a prebuilt local tree, so repository tests need no network or `git` binary; one
  smoke test exercises the real `Child.run` path guarded on `git` availability.
- A clock injection (`now: fn () i64`) so `imported_at` is deterministic in
  manifest assertions.
- JSON assertions compare against expected pretty strings (or parse-and-compare
  for order-independent fields), and always assert the single trailing newline.

## Implementation phases

Each phase ends green on `zig build test` + `zig fmt --check src` and is
committed. Test counts are targets derived from the spec acceptance suite.

### Phase 1 — Scaffold + cross-cutting contracts
- `build.zig` (root_module form), `build.zig.zon` (enum name, fingerprint,
  `minimum_zig_version = "0.16.0"`, empty deps, `.paths`), `Makefile`
  (`build/test/fmt-check/check/run-list/run-tui`), `src/root_test.zig`.
- `types.zig`, `result.zig` (full `ErrorInfo`/`ErrorKind`), `json_out.zig`
  emitter skeleton, `TmpRoots`/fixture/fake-provider/clock helpers.
- **Verify the 0.16 `std.Io.Dir` / `Io`-param fs signatures** with a throwaway
  test before building on them.
- *Tests:* one smoke test per helper; one `json_out` enum→string test asserting
  every enum's snake_case spelling (locks the spec enum vocabulary early).
- *Gate:* `zig build`, `zig fmt --check`, aggregator demonstrably runs (a
  deliberately failing test shows up, then is removed).

### Phase 2 — frontmatter + manifest + hashing + fsutil
- `frontmatter.zig`: parse `name:`/`description:` between `---` delimiters; trim
  values; ignore unknown fields; `validate_skill_name` (non-empty, not `.`/`..`,
  single path segment, no separators). Spec §"Skill Metadata".
- `manifest.zig`: read (`ignore_unknown_fields`) + write `import.json` (2-space,
  **no** trailing newline). Spec §"Import Manifest".
- `hash.zig`: string hash + directory-tree hash (supporting files + relative
  paths, deterministic `file_name`-sorted order, error on non-dir/non-file
  entries). Lock with a **Zig-computed golden**.
- `fsutil.zig`: no-follow symlink classify, lexical target resolution
  (`path.resolve`), recursive copy that **recreates** `.sym_link` entries
  (copyFile dereferences), `canonicalize_existing_ancestor` (hand-rolled).
- *Tests (~18):* frontmatter happy + each validation failure (missing open/close
  `---`, missing/empty name, bad name, missing/empty description); manifest
  round-trip incl. optional `source_repository` omitted; golden directory hash;
  string hash stability; symlink classify cases; ancestor canonicalize.

### Phase 3 — discovery + JSON inventory contract
- `discovery.zig`: scan all four roots; missing roots → empty (not error);
  identify canonical/imported by valid `SKILL.md`; **malformed `import.json` for
  an otherwise-valid imported skill is an error**; classify agent entries; merge
  duplicates with precedence (canonical < imported < agent_only; `promoted`
  OR-accumulated; `source_repository` from imported entry); name-sorted output;
  group repo imports in `source_repositories` sorted by `(skill_name, skill_path)`.
- `json_out.zig`: full inventory emitter (key order per spec §Inventory:
  `name`, `description?`, `source`, `source_repository?`, `promoted`,
  `enablement{claude_code,codex}`, `agent_entries{claude_code,codex}`), omit-vs-
  null rules, trailing newline.
- *Tests (~16, spec acceptance bullets 1–3):* canonical/imported/promoted/
  enabled/external/broken/agent-only inventories; missing-roots → empty success;
  malformed manifest → discovery failure; enablement boolean mapping for all six
  statuses; deterministic name ordering incl. shared-prefix; `source_repositories`
  grouping; every JSON command emits valid UTF-8 + trailing `\n`.

### Phase 4a — markdown / path / url imports + net
- `import.zig`: markdown (stdin or `--source-location`), path (file → `SKILL.md`;
  directory → recursive copy with guards), url. Collision rules (spec
  §"Collision Rules": refuse within imports root by dir name **or** frontmatter
  name; allow canonical collisions). `store_import` rollback on failure (no
  partial storage). Directory guards: reject symlinks/unsupported entries, reject
  reserved `import.json` in source, reject imports-root-inside-source.
- `net.zig`: injectable fetch; real impl streams into `Writer.Allocating`, 1 MiB
  cap, worker-thread 30 s deadline, reject invalid UTF-8; on any failure create
  no storage.
- *Tests (spec acceptance bullets 4–6, ~24):* markdown validate + no-partial-on-
  failure; local file + local dir preserving supporting files; reject symlink /
  reserved `import.json` / imports-root-inside-source; url timeout (fake +
  loopback), over-1 MiB reject, invalid-UTF-8 reject, all leaving no storage;
  import-result JSON shape (`create_directory`,`write_skill`,`write_manifest`).

### Phase 4b — repository scan + selection + batch + git
- `repository.zig`: BFS scan depth 8 (no-follow); root-skill-first then nested;
  **invalid root `SKILL.md` fails** (don't skip to nested); `IgnoreInvalid` for
  nested; sort by `file_name`. Selection: one valid skill + no `--select` →
  import; >1 + no `--select` → `selection` result (no storage); `--select`
  normalizes `.`/`./name`; duplicate normalized selections error; unmatched
  selection error. Batch: preflight all (duplicate names, imports-root
  collisions) before any write; reverse-order rollback of created skill paths +
  created roots on later failure. Manifests use `source_type: repository`,
  `source_location: <repo>#<rel-path>`, `source_repository{repository,skill_path}`
  (`.` for root skill).
- `git.zig`: injectable provider; real `Child.run("git","clone","--depth","1",…)`;
  spawn `FileNotFound` → "git not installed".
- *Tests (spec acceptance bullet 7, ~20):* single import; selection;
  selected import; batch import; duplicate selections; missing selection;
  duplicate skill names; rollback on batch failure; root skill import; invalid
  root `SKILL.md`; empty repository; depth-limit boundary (depth 8 included,
  9 skipped — documented); all three `kind` JSON shapes.

### Phase 5a — enable / disable
- `ops.zig` planner + executor. enable: unknown/agent-only/unpromoted fail;
  promoted imports link to **canonical** copy not draft; dedupe agents first-seen;
  **preflight all agents before mutating any** (no earlier agent mutated if a
  later one is unsafe); missing → create root + symlink; already-correct →
  `skip_unchanged`; any unsafe entry (real dir/file/broken/external/wrong target)
  fails untouched. disable: removes correct managed symlink; missing →
  `skip_unchanged`; unsafe → fail untouched; allows legacy enabled unpromoted
  imports. Executor records `create_directory` before `create_symlink`;
  canonicalize source before link for correct skip detection.
- *Tests (spec acceptance bullet 8, ~15):* idempotence, agent order, duplicate
  agents, each unsafe-entry class, unknown skill, agent-only, unpromoted (enable
  rejects), atomic multi-agent preflight (later unsafe ⇒ earlier untouched).

### Phase 5b — promote / unpromote / delete
- promote: unknown/canonical/agent-only/already-promoted fail; existing canonical
  dest fails without `--overwrite`; even with `--overwrite`, dest whose `SKILL.md`
  name differs fails; frontmatter-name collision anywhere in canonical fails;
  unsupported entries (symlinks) in import dir fail; unsafe agent entries fail
  before mutation; copy excludes top-level `import.json`; set draft manifest
  `promoted=true`; relink managed import symlinks to canonical copy; with
  `--overwrite`, don't remove old canonical until replacement is valid/ready
  (staging then swap on same mount). unpromote: unknown/canonical-only/agent-only/
  unpromoted fail; remove managed agent symlinks to canonical copy; remove
  canonical copy; set manifest `promoted=false`. delete: unknown/canonical/
  agent-only fail; promoted fail (unpromote first); legacy-enabled import fail
  (disable first); unrelated same-name unsafe agent entries don't block and are
  left untouched; success removes `<imports-root>/<name>`.
- *Tests (spec acceptance bullets 9–11, ~24):* promote support-file copy,
  manifest update, `import.json` exclusion, relink, canonical collision,
  overwrite (same/different name), unsafe agent entry, unsupported import entry,
  already-promoted; unpromote remove canonical + symlinks + manifest + invalid
  states; delete success, promoted/enabled block, canonical/agent-only errors,
  preserve unrelated same-name entries.

### Phase 6 — CLI + roots + main wiring
- `roots.zig`: independent per-root resolution (spec §"Root Resolution"):
  `--canonical-root`/`--imports-root`/`--claude-code-root`/`--codex-root`
  overrides; `canonical` ← `AGENT_SKILLS_REPO`/`~/dev/agent-skills` + `/third-party`;
  `imports` ← `<runtime-root>/.skill-importer/imports`; claude ← `~/.claude/skills`;
  codex ← `~/.agents/skills`; `runtime-root` = nearest ancestor with both
  `AGENTS.md` and `catalog/portable/`, else cwd; `HOME` required only when a
  default needs it (all-roots-explicit must not need `HOME`); missing roots valid.
- `cli.zig`: hand parser. `skill-importer [global-options] <command>
  [command-options]`; global `--format text|json` + four root options;
  subcommands `list`, `import markdown|path|url|repository`, `enable`, `disable`,
  `promote`, `unpromote`, `delete`, `tui`. `--agent claude-code|codex`
  (repeatable), `--skill`, `--select` (repeatable), `--overwrite`,
  `--source-location`, `--path`, `--url`, `--repository`. Parse errors →
  exit 1 + stderr.
- `main.zig`: arena per op, resolve roots, dispatch, render via `json_out` or
  text, flush stdout, set exit code; inject real net + git providers; `tui` →
  reject `--format json`, print "TUI not implemented", exit 1.
- *Tests (spec acceptance bullet 12–13 + Output Contract, ~16):* root resolution
  matrix (explicit override, env, HOME-needed vs not, runtime-root detection,
  missing roots empty); each command parse happy + error; `--format json` vs
  `text` exit/behavior parity; every failing command non-zero + actionable
  stderr; every JSON command valid UTF-8 + trailing newline (end-to-end).

### Phase 7 — CI / release / docs
- GitHub Actions: `setup-zig` pinned 0.16.0 + `zig build test` + `zig fmt
  --check`. Makefile recipes. Optional release via `zig build -Dtarget=...`
  cross-compile matrix (darwin/linux × amd64/arm64). Update `CLAUDE.md` layout +
  `docs/` to describe the Zig CLI. (Use the `docs` skill.)

### Phase 8 — TUI (deferred, separate effort)
- Replace the `tui` stub with a real interactive UI (libvaxis or hand-rolled
  termios+ANSI) reusing `ops.zig`/`discovery.zig` safety rules. Out of scope here.

## Verification

Per phase and at the end:

```bash
zig fmt --check src
zig build
zig build test          # ported suite via src/root_test.zig — the primary oracle
make check
```

End-to-end smoke against **disposable** roots (real user roots untouched):

```bash
zig build
CANONICAL_ROOT=.skill-importer/dev/canonical \
IMPORTS_ROOT=.skill-importer/dev/imports \
CLAUDE_CODE_ROOT=.skill-importer/dev/claude \
CODEX_ROOT=.skill-importer/dev/codex \
  ./zig-out/bin/skill-importer --format json list
printf '%s\n' '---' 'name: demo' 'description: d' '---' \
  | ./zig-out/bin/skill-importer import markdown
./zig-out/bin/skill-importer promote --skill demo
./zig-out/bin/skill-importer enable --skill demo --agent claude-code
./zig-out/bin/skill-importer --format json list
```

**Acceptance:** the spec's "Recommended TDD Acceptance Suite" is fully covered by
green tests; JSON output matches the spec schemas (keys, enum strings,
omit-vs-null, trailing newline); every failing command exits non-zero with
actionable stderr; no test touches real `~/.claude/skills` or `~/.agents/skills`.

## Risks / watch-items

- **0.16 std churn** (`std.Io.Dir`, `Io`-param fs ops, Writergate) — isolate
  behind `fsutil.zig`/`json_out.zig`/`net.zig`; verify each signature against the
  installed std in Phase 1, not from memory.
- **Silent test skipping** — `src/root_test.zig` aggregator is mandatory; prove
  it runs in Phase 1.
- **Symlink no-follow** — `statFile` follows; classify via `entry.kind`/`fstatat`
  and lexical `path.resolve`, or discovery/classification/promotion all break.
- **No socket timeout in std.http** — worker-thread deadline is best-effort;
  document that the socket may linger past 30 s.
- **Atomic multi-agent / batch operations** — preflight-then-execute with
  reverse-order rollback; the partial-action list is test-observable but not
  user-facing JSON.
- **Allocator discipline** — arena per CLI operation, freed at command end; tests
  on `std.testing.allocator` to catch leaks.
- **Don't conflate with `zig-rewrite.md`** — that plan pins 0.15.1 and matches
  the Rust binary; this one targets 0.16.0 and matches the spec.
```
