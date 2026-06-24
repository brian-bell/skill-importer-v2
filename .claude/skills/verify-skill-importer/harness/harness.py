#!/usr/bin/env python3
"""Core library for the skill-importer verification harness.

Dependency-free (Python 3.8+ stdlib only). Three pieces:

- `Sandbox` — a single `mkdtemp` tree holding the four roots + HOME + work dir.
  Every root lives under one temp dir, so the harness can NEVER touch a real
  user root. Mirrors the plan's `reset_lab`/`mk_skill_md`/`mk_canonical` helpers.
- `Cli` — runs the real `skill-importer` binary. `si()` prepends sandbox HOME +
  all four `--*-root` overrides (the plan's `si` wrapper); `run()` is raw (no
  overrides, caller controls env/cwd) for the §10 root-resolution cases.
- `Reporter` / `Case` — per-case assertion accumulator and per-section tallies.
  Needles for stderr come from `kindMessage` in src/main.zig; JSON predicates use
  `.get()` semantics because optional fields are omitted (not null).

`run.py` is the entrypoint; `cases/*.py` define the assertions.
"""

import collections
import json
import os
import re
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path

Result = collections.namedtuple("Result", ["rc", "out", "err"])
CaseResult = collections.namedtuple("CaseResult", ["id", "label", "status", "messages"])

# Run-everywhere timeout guard so a hung binary can't wedge the harness.
EXEC_TIMEOUT = 60


def section_of(cid):
    """Map a case id to its section key: '4.1' -> '4', '11.2a' -> '11'."""
    return cid.split(".", 1)[0]


_ID_RE = re.compile(r"^\|\s*([0-9]+\.[0-9]+[a-z]?)\b", re.MULTILINE)


def plan_case_ids(text):
    """Set of table-row case ids in the markdown plan (the sync join key).

    Matches only table rows (`| 3.1 | ... |`), so the §14 checklist bullets
    (`- [ ] 3.1`) reuse the same id and dedup into the set rather than inflating
    the count.
    """
    return set(_ID_RE.findall(text))


class Sandbox:
    """One mkdtemp tree with all four roots + HOME, guaranteeing isolation."""

    SUBDIRS = ("home", "canonical", "imports", "claude", "codex", "work")

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="si-verify-")
        self.lab = os.path.join(self.root, "lab")
        self._mkroots()

    def _mkroots(self):
        for d in self.SUBDIRS:
            os.makedirs(os.path.join(self.lab, d), exist_ok=True)

    @property
    def home(self):
        return os.path.join(self.lab, "home")

    @property
    def canonical(self):
        return os.path.join(self.lab, "canonical")

    @property
    def imports(self):
        return os.path.join(self.lab, "imports")

    @property
    def claude(self):
        return os.path.join(self.lab, "claude")

    @property
    def codex(self):
        return os.path.join(self.lab, "codex")

    @property
    def work(self):
        return os.path.join(self.lab, "work")

    def reset(self):
        if os.path.isdir(self.lab):
            shutil.rmtree(self.lab)
        self._mkroots()

    def mk_skill_md(self, path, name, desc):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "---\nname: {n}\ndescription: {d}\n---\n\n# {n}\n".format(n=name, d=desc)
        )

    def mk_canonical(self, name):
        self.mk_skill_md(
            Path(self.canonical) / name / "SKILL.md", name, "canonical {}".format(name)
        )

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.cleanup()


class Cli:
    """Invokes the real binary against a Sandbox."""

    def __init__(self, bin_path, sandbox):
        self.bin = str(bin_path)
        self.sb = sandbox

    def base_env(self, **overrides):
        """Minimal env: sandbox HOME + passthrough PATH. Pass KEY=None to drop a
        key (e.g. `base_env(HOME=None)` for the §10 `env -u HOME` cases)."""
        env = {"PATH": os.environ.get("PATH", ""), "HOME": self.sb.home}
        env.update(overrides)
        return {k: v for k, v in env.items() if v is not None}

    def si(self, *args, stdin=None, extra_env=None):
        """The plan's `si`: sandbox HOME + all four root overrides prepended."""
        env = self.base_env(AGENT_SKILLS_REPO=os.path.join(self.sb.lab, "asr-unused"))
        if extra_env:
            env.update(extra_env)
        argv = [
            self.bin,
            "--canonical-root", self.sb.canonical,
            "--imports-root", self.sb.imports,
            "--claude-code-root", self.sb.claude,
            "--codex-root", self.sb.codex,
            *args,
        ]
        return self._exec(argv, env, stdin, None)

    def run(self, args, env=None, cwd=None, stdin=None):
        """Raw invocation (no root overrides) for §10. `args` is a list; `env` is
        the COMPLETE environment (build it with `base_env(...)`)."""
        return self._exec([self.bin, *args], env or self.base_env(), stdin, cwd)

    def _exec(self, argv, env, stdin, cwd):
        try:
            p = subprocess.run(
                argv,
                input=stdin,
                capture_output=True,
                text=True,
                env=env,
                cwd=cwd,
                timeout=EXEC_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            return Result(124, "", "skill-importer: <harness: timed out>\n")
        return Result(p.returncode, p.stdout, p.stderr)


class Case:
    """Accumulates assertions for one plan case. Methods never raise; failures
    are collected and the worst outcome decides the case status."""

    def __init__(self, cid, label):
        self.id = cid
        self.label = label
        self.failures = []
        self.terminal = None  # ("na", reason) | ("indeterminate", note)

    def fail(self, msg):
        self.failures.append(msg)

    def exit(self, r, expected):
        if r.rc != expected:
            self.fail(
                "exit {} != expected {}; stderr={!r}".format(
                    r.rc, expected, r.err.strip()
                )
            )

    def stderr_has(self, r, needle):
        """Assert a failure case: `skill-importer:` prefix, needle present, and
        stdout empty (the §13 'nothing on stdout for failures' contract)."""
        if not r.err.startswith("skill-importer:"):
            self.fail("stderr missing 'skill-importer:' prefix: {!r}".format(r.err.strip()))
        if needle not in r.err:
            self.fail("stderr lacks {!r}: got {!r}".format(needle, r.err.strip()))
        # Contract: a failure writes NOTHING to stdout — exact compare, no strip
        # (whitespace-only stdout is still a violation).
        if r.out != "":
            self.fail("stdout nonempty on failure case: {!r}".format(r.out))

    def json(self, r, pred, desc=""):
        try:
            obj = json.loads(r.out)
        except Exception as e:  # noqa: BLE001 - any parse failure is a case fail
            self.fail("stdout not valid JSON ({}): {!r}".format(e, r.out[:120]))
            return None
        try:
            ok = pred(obj)
        except Exception as e:  # noqa: BLE001 - a predicate that raises is a fail
            self.fail("json predicate raised {!r}".format(e))
            return obj
        if not ok:
            self.fail(("json predicate failed " + desc).strip())
        return obj

    def json_newline(self, r):
        if not r.out.endswith("\n") or r.out.endswith("\n\n"):
            self.fail("expected exactly one trailing newline: {!r}".format(r.out[-4:]))
            return
        try:
            json.loads(r.out)
        except Exception as e:  # noqa: BLE001
            self.fail("json does not parse: {}".format(e))

    def path_exists(self, p):
        # lexists: a created symlink counts as present even if its target is gone.
        if not os.path.lexists(str(p)):
            self.fail("expected path to exist: {}".format(p))

    def path_absent(self, p):
        if os.path.lexists(str(p)):
            self.fail("expected path absent: {}".format(p))

    def na(self, reason):
        self.terminal = ("na", reason)

    def indeterminate(self, note):
        self.terminal = ("indeterminate", note)


class Reporter:
    """Collects CaseResults, groups by section, decides the process exit code."""

    STATUSES = ("pass", "fail", "na", "indeterminate")

    def __init__(self):
        self.results = []

    @contextmanager
    def case(self, cid, label):
        c = Case(cid, label)
        try:
            yield c
        except Exception as e:  # noqa: BLE001 - a bug in case setup is a FAIL, not a crash
            c.fail("exception in case body: {!r}".format(e))
        self.results.append(self._finalize(c))

    @staticmethod
    def _finalize(c):
        # Failures ALWAYS win: a recorded assertion failure must never be masked
        # by a terminal na/indeterminate. This matters for cases (7.12, 9.11) that
        # assert an observable postcondition and THEN mark themselves indeterminate
        # — if that postcondition regresses, the case must FAIL, not report INDET.
        if c.failures:
            return CaseResult(c.id, c.label, "fail", list(c.failures))
        if c.terminal:
            status, msg = c.terminal
            return CaseResult(c.id, c.label, status, [msg])
        return CaseResult(c.id, c.label, "pass", [])

    def section_tallies(self):
        tallies = {}
        for r in self.results:
            d = tallies.setdefault(section_of(r.id), {s: 0 for s in self.STATUSES})
            d[r.status] += 1
        return tallies

    def exit_code(self):
        return 1 if any(r.status == "fail" for r in self.results) else 0

    def executed_ids(self):
        return {r.id for r in self.results}
