"""§12 list integration — classification of a rich state."""

import json as _json
import os
import shutil
from pathlib import Path

from . import gitfixture


def _inv(out):
    return _json.loads(out)


def _by_name(out):
    return {s["name"]: s for s in _inv(out)["skills"]}


def run(cli, sb, rep):
    sb.reset()
    sb.mk_canonical("canon-only")
    cli.si("import", "markdown", stdin="---\nname: imp\ndescription: i\n---\n")
    cli.si("enable", "--skill", "canon-only", "--agent", "claude-code")
    os.symlink("/nonexistent-target-xyz", str(Path(sb.codex) / "broken"))
    os.symlink("/etc", str(Path(sb.claude) / "external"))

    r = cli.si("--format", "json", "list")

    with rep.case("12.1", "skills sorted ascending by name") as c:
        c.exit(r, 0)
        c.json(r, lambda o: [s["name"] for s in o["skills"]]
               == sorted(s["name"] for s in o["skills"]))

    with rep.case("12.2", "canonical entry classification") as c:
        c.json(r, lambda o, m=_by_name(r.out): (
            "canon-only" in m
            and m["canon-only"]["source"] == "canonical"
            and m["canon-only"]["agent_entries"]["claude_code"] == "canonical_symlink"
            and m["canon-only"]["enablement"]["claude_code"] is True
        ))

    with rep.case("12.3", "imported entry classification") as c:
        c.json(r, lambda o, m=_by_name(r.out): (
            "imp" in m and m["imp"]["source"] == "imported"
            and m["imp"]["promoted"] is False
        ))

    with rep.case("12.4", "broken symlink -> broken_symlink, enablement false") as c:
        c.json(r, lambda o, m=_by_name(r.out): (
            "broken" in m
            and m["broken"]["agent_entries"]["codex"] == "broken_symlink"
            and m["broken"]["enablement"]["codex"] is False
        ))

    with rep.case("12.5", "external symlink -> external_symlink, enablement true") as c:
        c.json(r, lambda o, m=_by_name(r.out): (
            "external" in m
            and m["external"]["agent_entries"]["claude_code"] == "external_symlink"
            and m["external"]["enablement"]["claude_code"] is True
        ))

    sb.reset()
    cli.si("import", "markdown", stdin="---\nname: imp\ndescription: i\n---\n")
    cli.si("promote", "--skill", "imp")
    cli.si("enable", "--skill", "imp", "--agent", "codex")
    with rep.case("12.6", "promoted + enabled reflected in re-list") as c:
        r2 = cli.si("--format", "json", "list")
        c.exit(r2, 0)
        # Post-promote the symlink must point at canonical -> canonical_symlink
        # exactly (accepting imported_symlink would mask a relink regression).
        c.json(r2, lambda o, m=_by_name(r2.out): (
            "imp" in m and m["imp"]["promoted"] is True
            and m["imp"]["agent_entries"]["codex"] == "canonical_symlink"
        ))

    with rep.case("12.7", "repository skill carries source_repository + grouped") as c:
        if not shutil.which("git"):
            c.na("git CLI not available")
        else:
            sb.reset()
            repo = Path(sb.work) / "repo-one"
            sb.mk_skill_md(repo / "SKILL.md", "repo-skill", "from repo")
            gitfixture.init_commit(repo)  # raises on git failure -> setup FAIL
            imp = cli.si("import", "repository", "--repository", str(repo))
            c.exit(imp, 0)
            r3 = cli.si("--format", "json", "list")
            c.exit(r3, 0)

            def check(o, repo=str(repo)):
                entry = {s["name"]: s for s in o["skills"]}.get("repo-skill")
                if not entry:
                    return False
                sr = entry.get("source_repository")
                if not sr or sr.get("repository") != repo or sr.get("skill_path") != ".":
                    return False
                group = next((g for g in o["source_repositories"]
                              if g["repository"] == repo), None)
                return bool(group) and any(
                    s["skill_name"] == "repo-skill" and s["skill_path"] == "."
                    for s in group["skills"])

            c.json(r3, check)

    sb.reset()
    with rep.case("12.8", "malformed import.json fails discovery") as c:
        cli.si("import", "markdown", stdin="---\nname: bad\ndescription: d\n---\n")
        (Path(sb.imports) / "bad" / "import.json").write_text("{ not valid json")
        r4 = cli.si("list")
        c.exit(r4, 1)
        c.stderr_has(r4, "malformed import.json")

    sb.reset()
    with rep.case("12.9", "json output parses + single trailing newline") as c:
        r5 = cli.si("--format", "json", "list")
        c.exit(r5, 0)
        c.json_newline(r5)
