"""§4 import markdown. Reads stdin, validates frontmatter, writes
<imports>/<name>/{SKILL.md,import.json}. Needles from main.zig kindMessage."""

import os
from pathlib import Path

GOOD = "---\nname: md-skill\ndescription: A skill.\n---\n# Body\n"


def run(cli, sb, rep):
    with rep.case("4.1", "markdown happy") as c:
        r = cli.si("--format", "json", "import", "markdown",
                   "--source-location", "clipboard", stdin=GOOD)
        c.exit(r, 0)
        c.json_newline(r)
        c.json(r, lambda o: (
            o["skill_name"] == "md-skill"
            and o["manifest"]["source_type"] == "markdown"
            and o["manifest"]["source_location"] == "clipboard"
            and o["manifest"]["promoted"] is False
            and o["manifest"]["content_hash"].startswith("sha256:")
            and [a["action"] for a in o["actions"]]
            == ["create_directory", "write_skill", "write_manifest"]
        ))

    with rep.case("4.2", "manifest 2-space indent, no trailing newline") as c:
        skill = Path(sb.imports) / "md-skill"
        c.path_exists(skill / "SKILL.md")
        c.path_exists(skill / "import.json")
        text = (skill / "import.json").read_text() if (skill / "import.json").exists() else ""
        if text and text.endswith("\n"):
            c.fail("import.json must have no trailing newline")
        if text and "\n  " not in text:
            c.fail("import.json should be 2-space indented")

    sb.reset()
    with rep.case("4.3", "no --source-location -> field omitted") as c:
        md = "---\nname: md2\ndescription: d\n---\n"
        r = cli.si("--format", "json", "import", "markdown", stdin=md)
        c.exit(r, 0)
        # Optional fields are OMITTED, not null -> use .get().
        c.json(r, lambda o: o["manifest"].get("source_location") is None)

    sb.reset()
    with rep.case("4.4", "missing open delimiter -> no storage") as c:
        r = cli.si("import", "markdown", stdin="name: x\ndescription: d\n")
        c.exit(r, 1)
        c.stderr_has(r, "missing the opening '---'")
        c.path_absent(Path(sb.imports) / "x")

    sb.reset()
    with rep.case("4.5", "missing close delimiter -> no storage") as c:
        r = cli.si("import", "markdown", stdin="---\nname: x\ndescription: d\n")
        c.exit(r, 1)
        c.stderr_has(r, "missing the closing '---'")
        if os.listdir(sb.imports):
            c.fail("imports root should be empty after failure")

    sb.reset()
    with rep.case("4.6", "missing name") as c:
        r = cli.si("import", "markdown", stdin="---\ndescription: d\n---\n")
        c.exit(r, 1)
        c.stderr_has(r, "missing a name")

    sb.reset()
    with rep.case("4.7", "bad name with separator") as c:
        r = cli.si("import", "markdown", stdin="---\nname: a/b\ndescription: d\n---\n")
        c.exit(r, 1)
        c.stderr_has(r, "not a single directory-safe path segment")

    sb.reset()
    with rep.case("4.8", "bad name '..'") as c:
        r = cli.si("import", "markdown", stdin="---\nname: ..\ndescription: d\n---\n")
        c.exit(r, 1)
        c.stderr_has(r, "not a single directory-safe path segment")

    sb.reset()
    with rep.case("4.9", "missing description") as c:
        r = cli.si("import", "markdown", stdin="---\nname: x\ndescription:\n---\n")
        c.exit(r, 1)
        c.stderr_has(r, "missing a description")

    sb.reset()
    with rep.case("4.10", "collision on re-import") as c:
        r1 = cli.si("import", "markdown", stdin=GOOD)
        c.exit(r1, 0)
        r2 = cli.si("import", "markdown", stdin=GOOD)
        c.exit(r2, 1)
        c.stderr_has(r2, "already exists")

    sb.reset()
    with rep.case("4.11", "no partial storage after failure") as c:
        cli.si("import", "markdown", stdin="---\nname: x\ndescription:\n---\n")
        if os.listdir(sb.imports):
            c.fail("imports root must be empty after validation failure")
