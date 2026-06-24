"""§10 root resolution. Uses raw `cli.run` (no overrides). Highest-risk section:
every case hard-codes a sandbox HOME except the variants that test HOME itself,
and asserts the RESOLVED path via observable behavior (a skill placed at the
expected default location shows up in `list`, or imports land where expected)."""

import json as _json
import os
from pathlib import Path

DRAFT = "---\nname: {n}\ndescription: d\n---\n# d\n"


def _skills(out):
    return {s["name"]: s for s in _json.loads(out)["skills"]}


def run(cli, sb, rep):
    sb.reset()

    with rep.case("10.1", "all roots explicit, no HOME -> ok") as c:
        env = cli.base_env(HOME=None)  # env -u HOME
        args = ["--canonical-root", sb.canonical, "--imports-root", sb.imports,
                "--claude-code-root", sb.claude, "--codex-root", sb.codex, "list"]
        r = cli.run(args, env=env)
        c.exit(r, 0)

    with rep.case("10.2", "default needs HOME, unset -> error") as c:
        env = cli.base_env(HOME=None)
        r = cli.run(["--imports-root", sb.imports, "list"], env=env)
        c.exit(r, 1)
        c.stderr_has(r, "HOME is required")

    with rep.case("10.3", "relative HOME -> error") as c:
        env = cli.base_env(HOME="relative/path")
        r = cli.run(["--imports-root", sb.imports, "list"], env=env)
        c.exit(r, 1)
        c.stderr_has(r, "absolute path")

    sb.reset()
    with rep.case("10.4", "AGENT_SKILLS_REPO -> canonical <asr>/third-party") as c:
        asr = Path(sb.lab) / "asr"
        sb.mk_skill_md(asr / "third-party" / "asr-skill" / "SKILL.md",
                       "asr-skill", "via ASR")
        env = cli.base_env(AGENT_SKILLS_REPO=str(asr))  # HOME also set (harmless)
        args = ["--imports-root", sb.imports, "--claude-code-root", sb.claude,
                "--codex-root", sb.codex, "--format", "json", "list"]
        r = cli.run(args, env=env)
        c.exit(r, 0)
        c.json(r, lambda o, out=r.out: "asr-skill" in _skills(out)
               and _skills(out)["asr-skill"]["source"] == "canonical")

    sb.reset()
    with rep.case("10.5", "HOME-derived canonical <home>/dev/agent-skills/third-party") as c:
        sb.mk_skill_md(
            Path(sb.home) / "dev" / "agent-skills" / "third-party" / "home-skill" / "SKILL.md",
            "home-skill", "via HOME")
        env = cli.base_env()  # HOME=sandbox, no ASR
        args = ["--imports-root", sb.imports, "--claude-code-root", sb.claude,
                "--codex-root", sb.codex, "--format", "json", "list"]
        r = cli.run(args, env=env)
        c.exit(r, 0)
        c.json(r, lambda o, out=r.out: "home-skill" in _skills(out)
               and _skills(out)["home-skill"]["source"] == "canonical")

    sb.reset()
    with rep.case("10.6", "runtime-root marker tree vs fallback for default imports") as c:
        # Marker tree: cwd ancestor with BOTH AGENTS.md and catalog/portable/.
        marker = Path(sb.work) / "marker"
        (marker / "catalog" / "portable").mkdir(parents=True)
        (marker / "AGENTS.md").write_text("x\n")
        env = cli.base_env()
        common = ["--canonical-root", sb.canonical, "--claude-code-root", sb.claude,
                  "--codex-root", sb.codex, "import", "markdown"]
        r1 = cli.run(common, env=env, cwd=str(marker), stdin=DRAFT.format(n="mk1"))
        c.exit(r1, 0)
        c.path_exists(marker / ".skill-importer" / "imports" / "mk1" / "SKILL.md")
        # Fallback: a marker-free cwd resolves imports under <cwd>.
        plain = Path(sb.work) / "plain"
        plain.mkdir(parents=True)
        r2 = cli.run(common, env=env, cwd=str(plain), stdin=DRAFT.format(n="mk2"))
        c.exit(r2, 0)
        c.path_exists(plain / ".skill-importer" / "imports" / "mk2" / "SKILL.md")

    sb.reset()
    with rep.case("10.7", "missing roots -> empty inventory") as c:
        ne = Path(sb.work) / "nonexistent"
        env = cli.base_env()
        args = ["--canonical-root", str(ne / "c"), "--imports-root", str(ne / "i"),
                "--claude-code-root", str(ne / "cc"), "--codex-root", str(ne / "cx"),
                "--format", "json", "list"]
        r = cli.run(args, env=env)
        c.exit(r, 0)
        c.json(r, lambda o: o["skills"] == [])
