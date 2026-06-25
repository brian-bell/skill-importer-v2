---
name: verify-skill-importer
description: Run the skill-importer black-box verification suite against the real built binary in disposable sandbox roots. Use when asked to verify, sign off on, smoke-test, or acceptance-test the skill-importer CLI before shipping a build.
user_invocable: true
---

# Verify skill-importer

Runs the `docs/manual-verification-plan.md` black-box suite (115 cases) against
the **real built `skill-importer` binary**, complementing the hermetic
`zig build test` unit suite. A bundled Python harness defines the sandbox helpers
once and asserts exit code / stderr / JSON / filesystem per case, printing PASS /
FAIL / N/A / INDETERMINATE and a machine-readable summary.

**Hard safety rule:** the harness only ever touches a `mktemp` sandbox — all four
roots plus `HOME` are overridden to disposable temp dirs. It must NEVER be
pointed at real user roots (`~/.claude/skills`, `~/.agents/skills`,
`~/dev/agent-skills`). Do not edit the harness to remove that isolation.

## Preconditions

1. Be in the repo (the harness resolves it via `git rev-parse --show-toplevel`).
2. `zig version` must be `0.16.0` — the harness aborts with **exit 2** otherwise
   (distinct from exit 1 = a case FAIL, so a sign-off can tell an environment
   gate apart from a regression).
3. The binary is built on demand by `make blackbox-test` / `zig build blackbox-test`;
   pass `--rebuild` to the harness directly to force a rebuild.

## Run it

```sh
make blackbox-test
```

The Make target runs the harness unit tests first, then the 115-case black-box
suite. Use the harness directly for targeted or environment-specific runs:

```sh
python3 .claude/skills/verify-skill-importer/harness/run.py
```

Useful flags:

- `--rebuild` — rebuild the binary first.
- `--git-url URL` — also run §7.13 (live clone) against a small reachable skill repo.
- `--no-url` / `--with-url` — skip / force the §5 url block (auto-detected by default).
- `--only N ...` — run just some sections, e.g. `--only 3 4 12`.

Read the harness's PASS/FAIL summary; do not re-derive cases by hand. Its unit
tests cover the assertion library and coverage-drift reporting:

```sh
python3 -m unittest discover -s .claude/skills/verify-skill-importer/harness -p test_harness.py
```

## Outcomes

- **PASS / FAIL** — deterministic assertions. Any FAIL makes `run.py` exit 1 and
  is printed verbatim; surface the first one.
- **N/A** — an environment-gated case that couldn't run, with a recorded reason
  (no git, no network, wrong platform, codex absent). N/A never fails the run.
- **INDETERMINATE** — a case whose true fault path can't be forced from outside
  the process (7.12 batch rollback, 9.11 overwrite-safety) or that would trigger
  a real external effect (11.2c/d launch `codex exec`). The harness asserts the
  observable postcondition; you confirm the rest by hand.

### Environment gating

- **§5 url** — an in-process HTTP server serves crafted bodies; 5.3 (unreachable)
  and 5.6 (missing flag) always run.
- **§7 repository** — needs the `git` CLI (the provider always `git clone`s, even
  local paths), so fixtures are real git repos; the whole section is N/A without
  git. §7.14 (git unavailable) runs everywhere by stripping `PATH`.
- **§11.2 analyze** — platform gating is by **compile-time** target: 11.2a
  (`supported only on macOS`) runs only on a non-macOS build; 11.2b–d only on a
  macOS build (further gated on the `codex` CLI).

## Sign-off

Map the machine-readable `SUMMARY §N pass fail na indet` lines to the plan's §15
sign-off table (Pass/Fail/N-A + notes per section), and record the `BINARY_SHA`.
The `COVERAGE plan=N run=M missing=… extra=…` line proves the harness still
mirrors every plan case id; any `missing`/`extra`, or a missing plan file, makes a
full run fail. Partial `--only` runs skip coverage enforcement intentionally.

## Layout

```
harness/
  run.py            entrypoint: preflight -> sections -> gated -> summary
  harness.py        Sandbox + Cli + Case/Reporter (helpers defined ONCE)
  test_harness.py   unit tests for the assertion library
  cases/sNN_*.py    one module per plan section (§3–§12), mirrors it 1:1
  cases/gated/      url.py · git.py · analyze.py
  fixtures/         report.json · report.bad.json
```

The markdown plan stays normative: where the harness and plan disagree, the plan
(and the spec behind it) wins, and the harness is the bug. The two cases that read
surprisingly — §7.3 (`imported_batch` for a single `--select`) and §7.10
(depth-9-only repo → empty) — match both the implementation and the plan rows; the
case comments explain why.
