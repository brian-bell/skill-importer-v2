# Manual Verification Plan — `skill-importer` CLI

A hands-on, end-to-end checklist for exercising the entire `skill-importer` CLI
against a built binary. This complements the automated suite (`zig build test`):
the automated tests run hermetically against injected providers and temp roots;
this plan drives the **real binary** with the **real net/git providers** against
**disposable sandbox roots**, so an operator can confirm the shipped artifact
behaves as the [clean-room spec](./cli-clean-room-spec.md) requires.

The spec is normative. Where this plan and the spec disagree, the spec wins.
`--format json` is the normative output; text output is illustrative only.

---

## 0. Safety rules (read first)

> **NEVER point the CLI at your real skill roots.** A misfired `delete`,
> `promote --overwrite`, or `disable` mutates the filesystem for real.

- Every case below runs with **all four roots overridden** to sandbox
  directories, plus a sandboxed `HOME` so no default can ever resolve to
  `~/.claude/skills`, `~/.agents/skills`, or `~/dev/agent-skills`.
- The only cases that may touch defaults are the explicit **Root Resolution**
  cases in §10, and even those use a sandbox `HOME`.
- Do all work under a scratch tree you can `rm -rf`. The examples use
  `$LAB` (the "lab" sandbox). Recreate it fresh for any case that mutates state.

---

## 1. Prerequisites

| Requirement | Check |
| ----------- | ----- |
| Zig 0.16.0  | `zig version` → `0.16.0` |
| Build       | `make build` → produces `zig-out/bin/skill-importer` |
| Suite green | `make check` (fmt + tests) passes before manual work |
| `git` CLI   | needed only for the live `import repository` Git-URL case (§6.10) |
| macOS       | needed only for the live `analyze` case (§11.2) |
| Network     | needed only for the live `import url` case (§5) |

Build once:

```sh
cd /Users/brian/dev/skill-importer-2
make build
BIN="$PWD/zig-out/bin/skill-importer"
```

---

## 2. Sandbox setup

Run this block to create a clean lab and a wrapper that always passes sandbox
roots. Re-run `reset_lab` before any mutating case to start from a known state.

```sh
export LAB="${TMPDIR:-/tmp}/si-lab"

reset_lab() {
  rm -rf "$LAB"
  mkdir -p "$LAB/home" \
           "$LAB/canonical" \
           "$LAB/imports" \
           "$LAB/claude" \
           "$LAB/codex" \
           "$LAB/work"
}

# `si` = the binary with sandbox HOME + all four roots overridden.
# Global options MUST precede the command word, so they go here.
si() {
  HOME="$LAB/home" AGENT_SKILLS_REPO="$LAB/agent-skills-unused" \
  "$BIN" \
    --canonical-root  "$LAB/canonical" \
    --imports-root    "$LAB/imports" \
    --claude-code-root "$LAB/claude" \
    --codex-root      "$LAB/codex" \
    "$@"
}

reset_lab
```

A couple of fixture helpers used throughout:

```sh
# Write a minimal valid SKILL.md to $1, name=$2, description=$3.
mk_skill_md() {
  mkdir -p "$(dirname "$1")"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n# %s\n' "$2" "$3" "$2" > "$1"
}

# Build a canonical skill directory named $1 under the canonical root.
mk_canonical() {
  mk_skill_md "$LAB/canonical/$1/SKILL.md" "$1" "canonical $1"
}
```

### How to read each case

For every case, confirm **all** of:

1. **Exit code** — `echo $?` immediately after. Spec: `0` success, `1` any failure.
2. **stdout** — for `--format json`, valid UTF-8 JSON ending in exactly one `\n`
   (verify with `... | tail -c 1 | xxd` → `0a`). Pipe through `jq .` to confirm
   it parses.
3. **stderr** — on failure, exactly `skill-importer: <message>` naming the
   operation and the offending skill/path/url/repository.
4. **Filesystem** — the side effects (or absence of them) described per case.

---

## 3. Global parsing & smoke tests (§ spec "Root Resolution", "Output Contract")

| # | Command | Expect |
| - | ------- | ------ |
| 3.1 | `si list` | exit 0; text `no skills found` (empty sandbox) |
| 3.2 | `si --format json list \| jq .` | exit 0; `{"skills":[],"source_repositories":[]}`; trailing newline present |
| 3.3 | `si --format json list \| tail -c1 \| xxd` | last byte `0a` |
| 3.4 | `"$BIN"` (no args) | exit 1; stderr `skill-importer: invalid command line: missing command` |
| 3.5 | `si bogus` | exit 1; stderr `... : unknown command` |
| 3.6 | `si --format xml list` | exit 1; stderr `... invalid --format value (expected text\|json)` |
| 3.7 | `si --format` (no value) | exit 1; `... --format requires a value (text\|json)` |
| 3.8 | `si --bogus-root x list` | exit 1; `... unknown global option` |
| 3.9 | `si list --extra` | exit 1; `... command takes no options` |
| 3.10 | `si --format json bogus` | exit 1 (parse error reported regardless of format) |
| 3.11 | `si list --format json` (format **after** command) | exit 1; `--format` is a global option, so `list` rejects it as an unknown option (`command takes no options`) |

Case 3.11 documents an important contract: **global options must precede the
command word.** Verify the operator-facing behavior matches.

---

## 4. `import markdown` (§ spec "import markdown", "Collision Rules")

Reads stdin, validates frontmatter, writes `<imports>/<name>/SKILL.md` +
`import.json`.

```sh
reset_lab
```

| # | Command | Expect |
| - | ------- | ------ |
| 4.1 happy | `printf -- '---\nname: md-skill\ndescription: A skill.\n---\n# Body\n' \| si --format json import markdown --source-location clipboard \| jq .` | exit 0; `skill_name=md-skill`; `manifest.source_type=markdown`; `manifest.source_location=clipboard`; `manifest.promoted=false`; `manifest.content_hash` starts `sha256:`; `actions` = `create_directory`,`write_skill`,`write_manifest` |
| 4.2 fs | inspect `$LAB/imports/md-skill/` | contains `SKILL.md` and `import.json`; `import.json` is 2-space-indented, **no trailing newline** (`tail -c1` is `}`) |
| 4.3 no src-loc | `printf -- '---\nname: md2\ndescription: d\n---\n' \| si --format json import markdown \| jq '.manifest.source_location'` | `null` (field omitted/absent) |
| 4.4 missing open | `printf 'name: x\ndescription: d\n' \| si import markdown` | exit 1; `... missing the opening '---' frontmatter delimiter`; **no** `$LAB/imports/*` created |
| 4.5 missing close | `printf -- '---\nname: x\ndescription: d\n' \| si import markdown` | exit 1; `... missing the closing '---' ...`; no storage |
| 4.6 missing name | `printf -- '---\ndescription: d\n---\n' \| si import markdown` | exit 1; `... missing a name` |
| 4.7 bad name (sep) | `printf -- '---\nname: a/b\ndescription: d\n---\n' \| si import markdown` | exit 1; `... not a single directory-safe path segment` |
| 4.8 bad name (`..`) | name `..` | exit 1; same invalid-name message |
| 4.9 missing desc | `printf -- '---\nname: x\ndescription:\n---\n' \| si import markdown` | exit 1; `... missing a description` |
| 4.10 collision | re-run 4.1's input twice | second run exit 1; `... an import with this name already exists (skill: md-skill)`; first import untouched |
| 4.11 no partial | after any failure (4.4–4.9), `ls $LAB/imports` | empty — failed validation leaves **no** partial directory |

---

## 5. `import url` (§ spec "import url")

Live network; uses the real fetcher (1 MiB cap, finite timeout, UTF-8 only).

```sh
reset_lab
```

| # | Command | Expect |
| - | ------- | ------ |
| 5.1 happy | host a valid `SKILL.md` (e.g. `python3 -m http.server` in a dir with the markdown) and `si --format json import url --url http://127.0.0.1:8000/skill.md` | exit 0; `manifest.source_type=url`; `manifest.source_location` = the URL; storage written |
| 5.2 bad name from body | serve markdown whose frontmatter `name` has a `/` | exit 1; invalid-name; no storage |
| 5.3 404 / unreachable | `si import url --url http://127.0.0.1:9/nope` | exit 1; `... failed to fetch the URL (url: ...)`; no storage |
| 5.4 non-UTF8 | serve a file with invalid UTF-8 bytes | exit 1; `... not valid UTF-8`; no storage |
| 5.5 too big | serve a file > 1 MiB | exit 1; `... exceeded the maximum allowed size`; no storage |
| 5.6 missing flag | `si import url` | exit 1; `... import url requires --url URL` |

> If hosting locally is inconvenient, 5.1/5.4/5.5 can be staged with a tiny
> `python3 -m http.server` over fixture files. 5.3 needs no server.

---

## 6. `import path` (§ spec "import path", "Collision Rules")

Local file or directory import.

```sh
reset_lab
```

### Single Markdown file

| # | Command | Expect |
| - | ------- | ------ |
| 6.1 | `mk_skill_md "$LAB/work/file.md" file-skill 'from a file'; si --format json import path --path "$LAB/work/file.md" \| jq .` | exit 0; `source_type=local_path`; `source_location` = the file path; `actions` include `write_skill` |
| 6.2 | missing `--path`: `si import path` | exit 1; `... import path requires --path PATH` |
| 6.3 | nonexistent path | exit 1; failure names the path |

### Directory import

```sh
reset_lab
mkdir -p "$LAB/work/dir-skill/helpers"
mk_skill_md "$LAB/work/dir-skill/SKILL.md" dir-skill 'a dir skill'
printf 'support\n' > "$LAB/work/dir-skill/helpers/util.txt"
```

| # | Command | Expect |
| - | ------- | ------ |
| 6.4 happy | `si --format json import path --path "$LAB/work/dir-skill" \| jq .` | exit 0; supporting `helpers/util.txt` copied into `$LAB/imports/dir-skill/helpers/`; `actions` include `copy_file` for the support file; content_hash reflects support files |
| 6.5 no SKILL.md | import a dir lacking `SKILL.md` | exit 1; frontmatter/open-delimiter style error; no storage |
| 6.6 symlink rejected | add a symlink inside the source dir, re-import | exit 1; `... unsupported filesystem entry`; no storage |
| 6.7 reserved manifest | place an `import.json` in the source dir, import | exit 1; `... reserved import.json`; no storage |
| 6.8 imports inside source | `--imports-root` set **inside** the source dir | exit 1; `... imports root is inside the source directory` |
| 6.9 collision | import the same dir twice | second run exit 1; `... already exists (skill: dir-skill)` |

> For 6.8, override just `--imports-root` to a subdir of the source on that one
> invocation: `si --imports-root "$LAB/work/dir-skill/nested" import path --path "$LAB/work/dir-skill"`.
> (Roots are resolved independently, so the other three sandbox roots still apply.)

---

## 7. `import repository` (§ spec "import repository", "Collision Rules")

`--repository` may be a local path or Git URL. Build local fixture repos so most
cases need no network. Scan depth limit is **8**.

```sh
reset_lab

# Repo with ONE skill at root.
mkdir -p "$LAB/work/repo-single"
mk_skill_md "$LAB/work/repo-single/SKILL.md" root-skill 'root skill'

# Repo with MULTIPLE skills in subdirs.
mkdir -p "$LAB/work/repo-multi"
mk_skill_md "$LAB/work/repo-multi/alpha/SKILL.md" repo-alpha 'first'
mk_skill_md "$LAB/work/repo-multi/beta/SKILL.md"  repo-beta  'second'
```

| # | Command | Expect |
| - | ------- | ------ |
| 7.1 root skill | `si --format json import repository --repository "$LAB/work/repo-single" \| jq .` | exit 0; `kind="imported"`; `manifest.source_type=repository`; `source_repository.skill_path="."`; `source_location` ends `#.` |
| 7.2 selection | `si --format json import repository --repository "$LAB/work/repo-multi" \| jq .` | exit 0; `kind="selection"`; lists `repo-alpha`(`alpha`) and `repo-beta`(`beta`); **no storage written** (`ls $LAB/imports` empty) |
| 7.3 single select | `si --format json import repository --repository "$LAB/work/repo-multi" --select alpha \| jq .` | exit 0; `kind="imported"`; `skill_name=repo-alpha` |
| 7.4 batch | `si --format json import repository --repository "$LAB/work/repo-multi" --select alpha --select beta \| jq .` | exit 0; `kind="imported_batch"`; `imports` length 2 |
| 7.5 dup select | `--select alpha --select alpha` | exit 1; `... a skill was selected more than once` |
| 7.6 dup name | two distinct subdirs whose `SKILL.md` names collide, both selected | exit 1; `... two selected skills resolve to the same name` |
| 7.7 missing select | `--select does-not-exist` | exit 1; `... the selected skill was not found in the repository` |
| 7.8 empty repo | repo dir with no valid skills | exit 1; `... contains no valid skills` |
| 7.9 invalid root SKILL.md | repo whose root `SKILL.md` is malformed (and has valid nested skills) | exit 1 — must **fail**, not skip the root and import nested |
| 7.10 depth limit | place a valid skill at depth 9; scan a repo where it is the only one | exit 1; `... beyond the repository scan depth limit` (a skill at depth ≤8 is found) |
| 7.11 imports collision | import `repo-alpha`, then re-select it | exit 1; existing imports-root collision before any write |
| 7.12 batch rollback | force a later write to fail in a 2-item batch (e.g. pre-create a read-only dir collision for the 2nd) | exit 1; the **first** import is rolled back — `ls $LAB/imports` shows neither |
| 7.13 git url (live) | `si import repository --repository https://github.com/<small-skill-repo>.git` | clones depth 1; selection/import per repo contents |
| 7.14 git missing | temporarily make `git` unavailable (`PATH=` minimal) and run 7.13 | exit 1; `... git is not available` |

> 7.12 is the key safety case: confirm **no earlier write survives** a later
> failure. Inspect `$LAB/imports` is empty afterward.

---

## 8. `enable` / `disable` (§ spec "enable", "disable", "Filesystem Safety")

Symlink management with multi-agent preflight. Set up a canonical skill and a
promoted import to enable.

```sh
reset_lab
mk_canonical canon-skill
```

| # | Command | Expect |
| - | ------- | ------ |
| 8.1 enable one | `si --format json enable --skill canon-skill --agent claude-code \| jq .` | exit 0; one `create_symlink` action, `agent=claude_code`, `target` inside canonical root; `$LAB/claude/canon-skill` is a symlink → `$LAB/canonical/canon-skill` |
| 8.2 idempotent | re-run 8.1 | exit 0; action `skip_unchanged` (no change) |
| 8.3 two agents | `si --format json enable --skill canon-skill --agent claude-code --agent codex \| jq '.actions'` | exit 0; actions ordered claude-code then codex; both symlinks exist |
| 8.4 dedupe order | `--agent codex --agent claude-code --agent codex` | exit 0; deduped first-seen → codex, claude-code (one action each) |
| 8.5 unknown skill | `si enable --skill nope --agent codex` | exit 1; `... unknown skill (skill: nope)`; no symlink created |
| 8.6 missing agent | `si enable --skill canon-skill` | exit 1; `... requires at least one --agent claude-code\|codex` |
| 8.7 bad agent | `si enable --skill canon-skill --agent vim` | exit 1; `... invalid --agent value (expected claude-code\|codex)` |
| 8.8 unsafe entry | pre-create `$LAB/codex/canon-skill` as a **real dir**, then `enable ... --agent codex` | exit 1; `... an existing agent entry is unsafe and was left untouched`; the real dir is intact |
| 8.9 atomic preflight | `enable --skill canon-skill --agent claude-code --agent codex` where the **codex** slot is unsafe (real file) but claude-code is clean | exit 1; **claude-code symlink is NOT created** — no earlier agent mutated when a later one is unsafe |
| 8.10 disable one | after 8.1, `si --format json disable --skill canon-skill --agent claude-code` | exit 0; `remove_symlink`; `$LAB/claude/canon-skill` gone |
| 8.11 disable missing | `disable` an agent with no entry | exit 0; `skip_unchanged` |
| 8.12 disable unsafe | disable where the entry is an external symlink (points outside roots) | exit 1; `... unsafe ...`; entry left intact |
| 8.13 agent-only fails | create only `$LAB/codex/ghost` symlink→external; `enable --skill ghost ...` | exit 1; `... exists only as an agent entry and cannot be managed` |
| 8.14 unpromoted import fails | import a draft (md), then `enable --skill <draft> --agent codex` | exit 1; unpromoted imports cannot be enabled |

> For 8.13, "agent-only" means discovered only via an agent root entry, not in
> canonical/imports. Use a symlink to somewhere outside all four roots.

---

## 9. `promote` / `unpromote` / `delete` (§ spec "promote", "unpromote", "delete")

The lifecycle of an imported draft. Build a fresh draft import first.

```sh
reset_lab
printf -- '---\nname: draft\ndescription: a draft\n---\n# d\n' | si import markdown >/dev/null
```

### promote

| # | Command | Expect |
| - | ------- | ------ |
| 9.1 happy | `si --format json promote --skill draft \| jq .` | exit 0; `$LAB/canonical/draft/SKILL.md` exists; `$LAB/canonical/draft/import.json` **does NOT** (import.json excluded); draft manifest `promoted` now `true` (`jq .promoted $LAB/imports/draft/import.json`) |
| 9.2 already promoted | re-run 9.1 | exit 1; `... skill is already promoted` |
| 9.3 unknown | `si promote --skill nope` | exit 1; `... unknown skill` |
| 9.4 canonical-only | `mk_canonical conly; si promote --skill conly` | exit 1; `... exists only in the canonical root` |
| 9.5 collision no overwrite | draft `draft2` whose name matches an existing canonical skill, `promote` without `--overwrite` | exit 1; `... a canonical skill already exists at the destination` |
| 9.6 overwrite | same as 9.5 with `--overwrite` | exit 0; canonical replaced |
| 9.7 overwrite name mismatch | `--overwrite` where existing canonical dest `SKILL.md` has a **different** frontmatter name | exit 1 — must fail even with `--overwrite` |
| 9.8 frontmatter collision elsewhere | a different-named canonical dir whose `SKILL.md` name equals the draft's | exit 1; `... a canonical skill with this frontmatter name already exists` |
| 9.9 unsupported import entry | put a symlink inside `$LAB/imports/draft/`, promote | exit 1; `... unsupported filesystem entry` |
| 9.10 relink on promote | enable the unpromoted draft via a legacy import symlink, then promote | managed symlinks pointing at the import dir are relinked to the canonical promoted copy |
| 9.11 overwrite safety | with `--overwrite`, confirm the existing canonical copy is not removed until the replacement is staged and valid (simulate a copy failure → old copy intact) |

### unpromote

```sh
# Continue from a promoted `draft`.
```

| # | Command | Expect |
| - | ------- | ------ |
| 9.12 happy | `si --format json unpromote --skill draft \| jq .` | exit 0; `$LAB/canonical/draft` removed; draft manifest `promoted` back to `false`; managed agent symlinks to the canonical copy removed |
| 9.13 not promoted | re-run 9.12 | exit 1; `... skill is not promoted` |
| 9.14 canonical-only | `unpromote --skill conly` | exit 1; `... exists only in the canonical root` |
| 9.15 unknown | `unpromote --skill nope` | exit 1; `... unknown skill` |

### delete

| # | Command | Expect |
| - | ------- | ------ |
| 9.16 happy | unpromoted draft: `si --format json delete --skill draft \| jq .` | exit 0; `$LAB/imports/draft` removed |
| 9.17 promoted blocked | promote a draft, then `delete` | exit 1; `... already promoted` (unpromote first) |
| 9.18 enabled blocked | legacy-enable an import, then `delete` | exit 1; `... the import is enabled; disable it first` |
| 9.19 canonical/agent-only | `delete --skill conly` | exit 1; canonical-only error |
| 9.20 unrelated same-name agent entry | an unrelated unsafe agent entry with the same name exists | delete still succeeds; the unrelated entry is **left untouched** |

---

## 10. Root resolution (§ spec "Root Resolution")

These verify default computation. Use a sandbox `HOME`; never the real one.

```sh
reset_lab
export H="$LAB/home"
```

| # | Command | Expect |
| - | ------- | ------ |
| 10.1 all explicit, no HOME | `env -u HOME "$BIN" --canonical-root "$LAB/canonical" --imports-root "$LAB/imports" --claude-code-root "$LAB/claude" --codex-root "$LAB/codex" list` | exit 0 — providing all roots must **not** require HOME |
| 10.2 default needs HOME, unset | `env -u HOME "$BIN" --imports-root "$LAB/imports" list` (canonical/claude/codex defaulted) | exit 1; `... HOME is required to resolve a default root but is not set` |
| 10.3 relative HOME | `HOME=relative "$BIN" --imports-root "$LAB/imports" list` | exit 1; `... HOME must be an absolute path ...` |
| 10.4 AGENT_SKILLS_REPO | `AGENT_SKILLS_REPO="$LAB/asr" HOME="$H" "$BIN" --imports-root "$LAB/imports" --claude-code-root "$LAB/claude" --codex-root "$LAB/codex" list` | exit 0; canonical resolves to `$LAB/asr/third-party` (missing → empty, not an error) |
| 10.5 HOME-derived canonical | unset `AGENT_SKILLS_REPO`, set `HOME="$H"` | canonical defaults to `$H/dev/agent-skills/third-party` |
| 10.6 runtime-root for imports | from a cwd whose ancestor has both `AGENTS.md` and `catalog/portable/`, default imports → `<that-ancestor>/.skill-importer/imports`; otherwise → `<cwd>/.skill-importer/imports` |
| 10.7 missing roots empty | point all roots at nonexistent dirs | `list` exit 0 with empty inventory (missing roots are empty, not errors) |

---

## 11. Non-spec extensions

### 11.1 `render-analysis-report` (explicit paths only; no roots, no HOME)

```sh
reset_lab
# Provide a valid Codex report JSON fixture at $LAB/work/report.json
```

| # | Command | Expect |
| - | ------- | ------ |
| 11.1a happy | `"$BIN" render-analysis-report --input "$LAB/work/report.json" --output "$LAB/work/out.html"` | exit 0; `out.html` written; text `wrote <path>` |
| 11.1b json | `... --format json` before the command word | exit 0; stdout `{"output":"<path>"}\n` |
| 11.1c missing input flag | omit `--input` | exit 1; `... requires --input PATH` |
| 11.1d input not a file | `--input` points at a dir / nonexistent | exit 1; `... the analysis report input is not a readable regular file` |
| 11.1e output exists | `--output` points at an existing file | exit 1; `... the analysis report output already exists` |
| 11.1f malformed report | `--input` is invalid JSON | exit 1; `... the analysis report JSON is malformed` |
| 11.1g no HOME needed | run with `env -u HOME` | exit 0 — this command resolves no roots |

### 11.2 `analyze --skill NAME` (macOS only; needs `codex` CLI)

| # | Command | Expect |
| - | ------- | ------ |
| 11.2a non-macOS | run on Linux | exit 1; `... supported only on macOS` |
| 11.2b codex missing | macOS, `codex` not on PATH | exit 1; `... the codex CLI was not found or could not be executed` |
| 11.2c file-backed auth | macOS, Codex configured with file-backed auth | exit 1; `... cannot run with file-backed Codex auth ...` |
| 11.2d happy | macOS + working `codex` + valid skill | exit 0; snapshots the skill and launches `codex exec`; text `analysis launched for <skill>; report: <path>` |

> `analyze` is macOS-gated and shells out to the real `codex` CLI. On other
> platforms only 11.2a is reachable; mark the rest **N/A** in the sign-off.

### 11.3 `tui` (intentional stub)

| # | Command | Expect |
| - | ------- | ------ |
| 11.3a | `si tui` | exit 1; stderr `skill-importer: TUI not implemented` |
| 11.3b | `si --format json tui` | exit 1; stderr `skill-importer: tui does not support --format json` |
| 11.3c | `si tui --extra` | exit 1; `... command takes no options` |

---

## 12. `list` integration (§ spec "list", JSON "Inventory")

After building a rich state, confirm `list --format json` classifies everything.
Construct one of each:

```sh
reset_lab
mk_canonical canon-only                                   # source=canonical
printf -- '---\nname: imp\ndescription: i\n---\n' | si import markdown >/dev/null   # source=imported, promoted=false
si enable --skill canon-only --agent claude-code >/dev/null  # enablement.claude_code=true
ln -s /nonexistent "$LAB/codex/broken"                    # broken_symlink → enablement false
ln -s /etc "$LAB/claude/external"                          # external_symlink → enablement true
```

| # | Check | Expect |
| - | ----- | ------ |
| 12.1 | `si --format json list \| jq '.skills[].name'` | sorted ascending by name (deterministic order) |
| 12.2 | the `canon-only` entry | `source="canonical"`; `agent_entries.claude_code="canonical_symlink"`; `enablement.claude_code=true` |
| 12.3 | the `imp` entry | `source="imported"`, `promoted=false` |
| 12.4 | broken symlink entry | `agent_entries.* = "broken_symlink"`; `enablement=false` |
| 12.5 | external symlink entry | `agent_entries.* = "external_symlink"`; `enablement=true` |
| 12.6 | promote `imp`, enable it, re-list | `agent_entries` reads `imported_symlink` or `canonical_symlink` appropriately; promoted reflects state |
| 12.7 | a repository-imported skill present | appears under `source_repositories`, grouped by `repository`, with `source_repository` on its skill entry |
| 12.8 | malformed `import.json` on a valid imported skill | `list` exit 1; `... a malformed import.json` (discovery error, not silent skip) |
| 12.9 | every `--format json` output | parses with `jq`, is UTF-8, ends in exactly one newline |

---

## 13. Output-contract sweep (run last, across all commands)

A final pass confirming the cross-cutting contract from spec "Output Contract":

- [ ] Every `--format json` success → valid JSON, UTF-8, exactly one trailing `\n`.
- [ ] Every failure → exit `1`, nothing on stdout, `skill-importer: <message>` on stderr.
- [ ] Every failure message names the failing operation and the specific
      skill/path/url/repository where applicable.
- [ ] No command ever mutates a real user root during this entire run
      (`ls ~/.claude/skills ~/.agents/skills` unchanged; you used sandbox roots throughout).
- [ ] Action lists in mutating commands match the documented action vocabulary
      (`create_directory`, `create_symlink`, `remove_symlink`, `copy_file`,
      `write_skill`, `write_manifest`, `remove_directory`, `skip_unchanged`).

---

## 14. Sign-off

| Section | Pass / Fail / N/A | Notes |
| ------- | ----------------- | ----- |
| 3 Global parsing | | |
| 4 import markdown | | |
| 5 import url (live) | | |
| 6 import path | | |
| 7 import repository | | |
| 8 enable / disable | | |
| 9 promote / unpromote / delete | | |
| 10 root resolution | | |
| 11 non-spec (render / analyze / tui) | | |
| 12 list integration | | |
| 13 output contract | | |

Tester: __________   Binary SHA (`git rev-parse HEAD`): __________   Date: __________
