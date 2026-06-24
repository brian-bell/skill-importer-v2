"""§8 enable / disable. Symlink management with multi-agent preflight."""

import os
from pathlib import Path


def _actions(o):
    return o.get("actions", [])


def run(cli, sb, rep):
    sb.reset()
    sb.mk_canonical("canon-skill")

    with rep.case("8.1", "enable one agent -> create_symlink") as c:
        r = cli.si("--format", "json", "enable", "--skill", "canon-skill",
                   "--agent", "claude-code")
        c.exit(r, 0)
        c.json(r, lambda o: (
            len(_actions(o)) == 1
            and _actions(o)[0]["action"] == "create_symlink"
            and _actions(o)[0]["agent"] == "claude_code"
            and sb.canonical in _actions(o)[0]["target"]
        ))
        c.path_exists(Path(sb.claude) / "canon-skill")

    with rep.case("8.2", "idempotent enable -> skip_unchanged") as c:
        r = cli.si("--format", "json", "enable", "--skill", "canon-skill",
                   "--agent", "claude-code")
        c.exit(r, 0)
        c.json(r, lambda o: any(a["action"] == "skip_unchanged" for a in _actions(o)))

    sb.reset()
    sb.mk_canonical("canon-skill")
    with rep.case("8.3", "two agents -> ordered create_symlink") as c:
        r = cli.si("--format", "json", "enable", "--skill", "canon-skill",
                   "--agent", "claude-code", "--agent", "codex")
        c.exit(r, 0)
        c.json(r, lambda o: [a["agent"] for a in _actions(o)] == ["claude_code", "codex"])
        c.path_exists(Path(sb.claude) / "canon-skill")
        c.path_exists(Path(sb.codex) / "canon-skill")

    sb.reset()
    sb.mk_canonical("canon-skill")
    with rep.case("8.4", "dedupe agents first-seen order") as c:
        r = cli.si("--format", "json", "enable", "--skill", "canon-skill",
                   "--agent", "codex", "--agent", "claude-code", "--agent", "codex")
        c.exit(r, 0)
        c.json(r, lambda o: [a["agent"] for a in _actions(o)] == ["codex", "claude_code"])

    sb.reset()
    sb.mk_canonical("canon-skill")
    with rep.case("8.5", "unknown skill") as c:
        r = cli.si("enable", "--skill", "nope", "--agent", "codex")
        c.exit(r, 1)
        c.stderr_has(r, "unknown skill")
        c.path_absent(Path(sb.codex) / "nope")

    with rep.case("8.6", "missing --agent") as c:
        r = cli.si("enable", "--skill", "canon-skill")
        c.exit(r, 1)
        c.stderr_has(r, "at least one --agent")

    with rep.case("8.7", "invalid --agent value") as c:
        r = cli.si("enable", "--skill", "canon-skill", "--agent", "vim")
        c.exit(r, 1)
        c.stderr_has(r, "invalid --agent value")

    sb.reset()
    sb.mk_canonical("canon-skill")
    with rep.case("8.8", "unsafe entry (real dir) left intact") as c:
        (Path(sb.codex) / "canon-skill").mkdir(parents=True)
        r = cli.si("enable", "--skill", "canon-skill", "--agent", "codex")
        c.exit(r, 1)
        c.stderr_has(r, "unsafe")
        if not (Path(sb.codex) / "canon-skill").is_dir():
            c.fail("real dir must be left intact")

    sb.reset()
    sb.mk_canonical("canon-skill")
    with rep.case("8.9", "atomic preflight: later unsafe -> earlier not mutated") as c:
        (Path(sb.codex) / "canon-skill").write_text("real file")  # unsafe codex slot
        r = cli.si("enable", "--skill", "canon-skill",
                   "--agent", "claude-code", "--agent", "codex")
        c.exit(r, 1)
        c.stderr_has(r, "unsafe")
        c.path_absent(Path(sb.claude) / "canon-skill")  # claude must be untouched

    sb.reset()
    sb.mk_canonical("canon-skill")
    with rep.case("8.10", "disable removes symlink") as c:
        cli.si("enable", "--skill", "canon-skill", "--agent", "claude-code")
        r = cli.si("--format", "json", "disable", "--skill", "canon-skill",
                   "--agent", "claude-code")
        c.exit(r, 0)
        c.json(r, lambda o: any(a["action"] == "remove_symlink" for a in _actions(o)))
        c.path_absent(Path(sb.claude) / "canon-skill")

    with rep.case("8.11", "disable missing -> skip_unchanged") as c:
        r = cli.si("--format", "json", "disable", "--skill", "canon-skill",
                   "--agent", "codex")
        c.exit(r, 0)
        c.json(r, lambda o: any(a["action"] == "skip_unchanged" for a in _actions(o)))

    sb.reset()
    sb.mk_canonical("canon-skill")
    with rep.case("8.12", "disable unsafe external symlink left intact") as c:
        link = Path(sb.claude) / "canon-skill"
        os.symlink("/etc", str(link))  # external symlink (outside managed roots)
        r = cli.si("disable", "--skill", "canon-skill", "--agent", "claude-code")
        c.exit(r, 1)
        c.stderr_has(r, "unsafe")
        if not os.path.islink(str(link)):
            c.fail("external symlink must be left intact")

    sb.reset()
    with rep.case("8.13", "agent-only skill cannot be enabled") as c:
        os.symlink("/tmp/outside-all-roots", str(Path(sb.codex) / "ghost"))
        r = cli.si("enable", "--skill", "ghost", "--agent", "codex")
        c.exit(r, 1)
        c.stderr_has(r, "exists only as an agent entry")

    sb.reset()
    with rep.case("8.14", "unpromoted import cannot be enabled") as c:
        cli.si("import", "markdown",
               stdin="---\nname: draft\ndescription: d\n---\n")
        r = cli.si("enable", "--skill", "draft", "--agent", "codex")
        c.exit(r, 1)
        c.stderr_has(r, "not promoted")
