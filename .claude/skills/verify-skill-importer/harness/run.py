#!/usr/bin/env python3
"""Entrypoint for the skill-importer verification harness.

Builds/locates the binary, runs the hermetic case sections against a disposable
sandbox, dispatches the environment-gated sections, prints per-section tallies +
a machine-readable SUMMARY block, and exits 1 if any case FAILed (N/A and
INDETERMINATE never fail the run). Zig-version / build failures exit 2 so the
sign-off can tell an environment gate apart from a regression.

    python3 run.py [--rebuild] [--with-url|--no-url] [--git-url URL] [--only N ...]
"""

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

from harness import Sandbox, Cli, Reporter, plan_case_ids

import cases.s03_global as s03
import cases.s04_import_markdown as s04
import cases.s06_import_path as s06
import cases.s07_import_repository as s07
import cases.s08_enable_disable as s08
import cases.s09_lifecycle as s09
import cases.s10_roots as s10
import cases.s11_extensions as s11
import cases.s12_list as s12
import cases.gated.url as g_url
import cases.gated.git as g_git
import cases.gated.analyze as g_analyze

HARNESS_DIR = Path(__file__).resolve().parent
REQUIRED_ZIG = "0.16.0"

HERMETIC = [
    ("3", s03), ("4", s04), ("6", s06), ("7", s07), ("8", s08),
    ("9", s09), ("10", s10), ("11", s11), ("12", s12),
]

# Every section the harness knows how to run (hermetic + gated §5). `--only` is
# validated against this so a typo (`--only 99`) is a loud error, not a false green.
KNOWN_SECTIONS = {"3", "4", "5", "6", "7", "8", "9", "10", "11", "12"}


def _git_out(args, cwd):
    """Run `git <args>` and return stripped stdout, or None if git is missing or
    errors — so the harness honors its own git-unavailable gating instead of
    crashing before it can mark repository cases N/A."""
    try:
        p = subprocess.run(["git", *args], capture_output=True, text=True, cwd=str(cwd))
    except (FileNotFoundError, OSError):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def repo_root():
    top = _git_out(["rev-parse", "--show-toplevel"], HARNESS_DIR)
    return Path(top) if top else HARNESS_DIR.parents[3]


def die(msg, code=2):
    sys.stderr.write("verify: {}\n".format(msg))
    sys.exit(code)


def preflight(repo, rebuild):
    try:
        zig = subprocess.run(["zig", "version"], capture_output=True, text=True)
    except (FileNotFoundError, OSError):
        die("zig not found on PATH")  # exit 2: environment gate, not a regression
    if zig.returncode != 0:
        die("zig version failed")
    ver = zig.stdout.strip()
    if ver != REQUIRED_ZIG:
        die("zig {} required, found {}".format(REQUIRED_ZIG, ver))
    binp = repo / "zig-out" / "bin" / "skill-importer"
    if rebuild or not binp.exists():
        if subprocess.run(["make", "build"], cwd=str(repo)).returncode != 0:
            die("make build failed")
    if not binp.exists():
        die("binary missing after build: {}".format(binp))
    return binp


def report(rep, repo, binp, partial):
    tallies = rep.section_tallies()
    print("\n=== Verification summary ===")
    for sec in sorted(tallies, key=lambda s: int(s)):
        t = tallies[sec]
        print("§{}: {} PASS / {} FAIL / {} N/A / {} INDET".format(
            sec, t["pass"], t["fail"], t["na"], t["indeterminate"]))
    for r in rep.results:
        if r.status in ("fail", "indeterminate"):
            print("  {} {}: {} — {}".format(
                r.status.upper(), r.id, r.label, "; ".join(r.messages)))
    print("\n--- machine-readable ---")
    for sec in sorted(tallies, key=lambda s: int(s)):
        t = tallies[sec]
        print("SUMMARY §{} {} {} {} {}".format(
            sec, t["pass"], t["fail"], t["na"], t["indeterminate"]))
    # id-coverage diff against the plan (sync join key). Suppressed for partial
    # (`--only`) runs, where a large `missing=` list is expected, not a regression.
    plan = repo / "docs" / "manual-verification-plan.md"
    if partial:
        print("COVERAGE skipped (partial run via --only)")
    elif plan.exists():
        plan_ids = plan_case_ids(plan.read_text())
        run_ids = rep.executed_ids()
        missing = sorted(plan_ids - run_ids)
        extra = sorted(run_ids - plan_ids)
        print("COVERAGE plan={} run={} missing={} extra={}".format(
            len(plan_ids), len(run_ids),
            ",".join(missing) or "-", ",".join(extra) or "-"))
    # BINARY_SHA identifies the bytes that were tested (NOT the git commit). The
    # commit + dirty flag are reported separately for traceability.
    try:
        digest = hashlib.sha256(binp.read_bytes()).hexdigest()
    except OSError:
        digest = "<unavailable>"
    head = _git_out(["rev-parse", "HEAD"], repo)
    dirty = _git_out(["status", "--porcelain"], repo)
    print("BINARY_SHA sha256:{}".format(digest))
    if head is None:
        print("GIT_COMMIT <git unavailable>")
    else:
        print("GIT_COMMIT {}{}".format(head, "-dirty" if dirty else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--with-url", dest="url", action="store_true", default=None)
    ap.add_argument("--no-url", dest="url", action="store_false")
    ap.add_argument("--git-url", default=None)
    ap.add_argument("--only", nargs="*", default=None,
                    help="section numbers to run, e.g. --only 3 4")
    args = ap.parse_args()

    if args.only:
        unknown = [s for s in args.only if s not in KNOWN_SECTIONS]
        if unknown:
            die("unknown --only section(s): {} (known: {})".format(
                ",".join(unknown), ",".join(sorted(KNOWN_SECTIONS, key=int))))

    repo = repo_root()
    binp = preflight(repo, args.rebuild)

    sb = Sandbox()
    rep = Reporter()
    try:
        cli = Cli(binp, sb)
        for sec, mod in HERMETIC:
            if args.only and sec not in args.only:
                continue
            sb.reset()
            mod.run(cli, sb, rep)
        if not args.only or "5" in args.only:
            g_url.run(cli, sb, rep, enabled=args.url)
        if not args.only or "7" in args.only:
            g_git.run(cli, sb, rep, git_url=args.git_url)
        if not args.only or "11" in args.only:
            g_analyze.run(cli, sb, rep)
    finally:
        report(rep, repo, binp, partial=bool(args.only))
        sb.cleanup()
    sys.exit(rep.exit_code())


if __name__ == "__main__":
    main()
