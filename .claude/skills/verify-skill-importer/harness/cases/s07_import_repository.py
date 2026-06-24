"""§7 import repository (local fixtures, 7.1-7.12).

The real `RealProvider` ALWAYS shells `git clone`, so a fixture must be a real git
repo (not a plain dir). Hence this whole section is gated on the `git` CLI; absent
git, every 7.x is N/A. 7.13 (live clone) and 7.14 (git-unavailable) live in
gated/git.py.

Note: §7.3 (single --select -> imported_batch) and §7.10 (depth-9 skipped ->
empty_repository) match the real behavior in repository.zig and the (corrected)
plan rows; the comments below explain why, since both are easy to misread.
"""

import os
import shutil
from pathlib import Path

from . import gitfixture


def _make_repo(sb, name, skills, raw=None):
    """skills: list of (rel|None, name, desc); rel None == root skill.
    raw: optional list of (rel|None, text) written verbatim (for invalid SKILL.md)."""
    d = Path(sb.work) / name
    d.mkdir(parents=True, exist_ok=True)
    for rel, sname, desc in skills:
        md = d / "SKILL.md" if rel is None else d / rel / "SKILL.md"
        sb.mk_skill_md(md, sname, desc)
    for rel, text in (raw or []):
        p = d / "SKILL.md" if rel is None else d / rel / "SKILL.md"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    gitfixture.init_commit(d)
    return str(d)


def run(cli, sb, rep):
    if not shutil.which("git"):
        for cid in ["7.1", "7.2", "7.3", "7.4", "7.5", "7.6", "7.7", "7.8",
                    "7.9", "7.10", "7.11", "7.12"]:
            with rep.case(cid, "import repository (local)") as c:
                c.na("git CLI not available")
        return

    sb.reset()
    with rep.case("7.1", "root skill -> kind=imported, skill_path='.'") as c:
        repo = _make_repo(sb, "repo-single", [(None, "root-skill", "root skill")])
        r = cli.si("--format", "json", "import", "repository", "--repository", repo)
        c.exit(r, 0)
        c.json(r, lambda o: (
            o["kind"] == "imported"
            and o["manifest"]["source_type"] == "repository"
            and o["manifest"]["source_repository"]["skill_path"] == "."
            and o["manifest"]["source_location"].endswith("#.")
        ))

    sb.reset()
    with rep.case("7.2", "multi skill, no select -> selection, no storage") as c:
        repo = _make_repo(sb, "repo-multi", [
            ("alpha", "repo-alpha", "first"), ("beta", "repo-beta", "second")])
        r = cli.si("--format", "json", "import", "repository", "--repository", repo)
        c.exit(r, 0)
        c.json(r, lambda o: (
            o["kind"] == "selection"
            and {s["relative_path"] for s in o["skills"]} == {"alpha", "beta"}
        ))
        if os.listdir(sb.imports):
            c.fail("selection must not write storage")

    sb.reset()
    with rep.case("7.3", "single --select -> imported_batch of one") as c:
        # Any --select goes through the batch path (repository.zig routes all
        # non-empty selections to batchImport), so a single selection returns
        # kind=imported_batch (one import), NOT kind=imported. Matches plan §7.3.
        repo = _make_repo(sb, "repo-multi", [
            ("alpha", "repo-alpha", "first"), ("beta", "repo-beta", "second")])
        r = cli.si("--format", "json", "import", "repository",
                   "--repository", repo, "--select", "alpha")
        c.exit(r, 0)
        c.json(r, lambda o: (
            o["kind"] == "imported_batch"
            and len(o["imports"]) == 1
            and o["imports"][0]["skill_name"] == "repo-alpha"
        ))

    sb.reset()
    with rep.case("7.4", "batch select -> imported_batch") as c:
        repo = _make_repo(sb, "repo-multi", [
            ("alpha", "repo-alpha", "first"), ("beta", "repo-beta", "second")])
        r = cli.si("--format", "json", "import", "repository", "--repository", repo,
                   "--select", "alpha", "--select", "beta")
        c.exit(r, 0)
        c.json(r, lambda o: o["kind"] == "imported_batch" and len(o["imports"]) == 2)

    sb.reset()
    with rep.case("7.5", "duplicate selection") as c:
        repo = _make_repo(sb, "repo-multi", [
            ("alpha", "repo-alpha", "first"), ("beta", "repo-beta", "second")])
        r = cli.si("import", "repository", "--repository", repo,
                   "--select", "alpha", "--select", "alpha")
        c.exit(r, 1)
        c.stderr_has(r, "selected more than once")

    sb.reset()
    with rep.case("7.6", "two selected skills resolve to same name") as c:
        repo = _make_repo(sb, "repo-dup", [
            ("alpha", "dupe", "a"), ("beta", "dupe", "b")])
        r = cli.si("import", "repository", "--repository", repo,
                   "--select", "alpha", "--select", "beta")
        c.exit(r, 1)
        c.stderr_has(r, "two selected skills resolve to the same name")

    sb.reset()
    with rep.case("7.7", "missing selection") as c:
        repo = _make_repo(sb, "repo-multi", [
            ("alpha", "repo-alpha", "first"), ("beta", "repo-beta", "second")])
        r = cli.si("import", "repository", "--repository", repo, "--select", "nope")
        c.exit(r, 1)
        c.stderr_has(r, "selected skill was not found")

    sb.reset()
    with rep.case("7.8", "empty repository") as c:
        # A real repo with a committed non-skill file (so the commit is valid) but
        # no SKILL.md anywhere -> empty_repository.
        d = Path(sb.work) / "repo-empty"
        d.mkdir(parents=True, exist_ok=True)
        (d / "readme.md").write_text("no skills here\n")
        gitfixture.init_commit(d)
        r = cli.si("import", "repository", "--repository", str(d))
        c.exit(r, 1)
        c.stderr_has(r, "contains no valid skills")

    sb.reset()
    with rep.case("7.9", "invalid root SKILL.md fails (not skipped)") as c:
        # Root SKILL.md malformed; a nested valid skill exists. Must FAIL.
        repo = _make_repo(sb, "repo-badroot",
                          [("alpha", "repo-alpha", "first")],
                          raw=[(None, "name: x\nno frontmatter\n")])
        r = cli.si("import", "repository", "--repository", repo)
        c.exit(r, 1)
        c.stderr_has(r, "failed to process the repository")

    sb.reset()
    with rep.case("7.10", "depth: 8 found, 9 skipped (-> empty); matches plan") as c:
        deep8 = "a/b/c/d/e/f/g/h"          # 8 components -> depth 8, included
        repo8 = _make_repo(sb, "repo-d8", [(deep8, "deep8", "at depth 8")])
        r8 = cli.si("--format", "json", "import", "repository", "--repository", repo8)
        c.exit(r8, 0)
        c.json(r8, lambda o: o["kind"] == "imported" and o["skill_name"] == "deep8")
        sb.reset()
        deep9 = "a/b/c/d/e/f/g/h/i"        # 9 components -> depth 9, skipped
        repo9 = _make_repo(sb, "repo-d9", [(deep9, "deep9", "at depth 9")])
        r9 = cli.si("import", "repository", "--repository", repo9)
        c.exit(r9, 1)
        c.stderr_has(r9, "contains no valid skills")

    sb.reset()
    with rep.case("7.11", "imports-root collision before write") as c:
        repo = _make_repo(sb, "repo-multi", [
            ("alpha", "repo-alpha", "first"), ("beta", "repo-beta", "second")])
        r1 = cli.si("import", "repository", "--repository", repo, "--select", "alpha")
        c.exit(r1, 0)
        r2 = cli.si("import", "repository", "--repository", repo, "--select", "alpha")
        c.exit(r2, 1)
        c.stderr_has(r2, "already exists")

    sb.reset()
    with rep.case("7.12", "batch rollback (postcondition only)") as c:
        # A pre-existing colliding import for the 2nd item trips the *preflight*
        # collision check (repository.zig batchImport preflights ALL names before
        # writing), so nothing is written and there is nothing to roll back. The
        # observable postcondition (no NEW partial storage) still holds, but true
        # mid-write rollback is not exercised from outside the process.
        repo = _make_repo(sb, "repo-multi", [
            ("alpha", "repo-alpha", "first"), ("beta", "repo-beta", "second")])
        # Pre-create a colliding 'repo-beta' import so the batch preflight fails.
        sb.mk_skill_md(Path(sb.imports) / "repo-beta" / "SKILL.md", "repo-beta", "pre")
        r = cli.si("import", "repository", "--repository", repo,
                   "--select", "alpha", "--select", "beta")
        c.exit(r, 1)
        # alpha must NOT have been written (preflight caught beta first).
        c.path_absent(Path(sb.imports) / "repo-alpha")
        c.indeterminate("preflight collision path, not mid-write rollback (see note)")
