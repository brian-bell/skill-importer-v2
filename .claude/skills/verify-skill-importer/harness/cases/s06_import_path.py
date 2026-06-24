"""§6 import path. Local Markdown file or skill directory."""

import os
from pathlib import Path


def run(cli, sb, rep):
    # --- single Markdown file ---
    with rep.case("6.1", "single markdown file") as c:
        f = Path(sb.work) / "file.md"
        sb.mk_skill_md(f, "file-skill", "from a file")
        r = cli.si("--format", "json", "import", "path", "--path", str(f))
        c.exit(r, 0)
        c.json(r, lambda o: (
            o["manifest"]["source_type"] == "local_path"
            and o["manifest"]["source_location"] == str(f)
            and any(a["action"] == "write_skill" for a in o["actions"])
        ))

    sb.reset()
    with rep.case("6.2", "missing --path") as c:
        r = cli.si("import", "path")
        c.exit(r, 1)
        c.stderr_has(r, "import path requires --path")

    sb.reset()
    with rep.case("6.3", "nonexistent path") as c:
        r = cli.si("import", "path", "--path", str(Path(sb.work) / "nope.md"))
        c.exit(r, 1)
        if not r.err.startswith("skill-importer:"):
            c.fail("expected skill-importer error, got {!r}".format(r.err))

    # --- directory import ---
    def make_dir_skill():
        d = Path(sb.work) / "dir-skill"
        sb.mk_skill_md(d / "SKILL.md", "dir-skill", "a dir skill")
        (d / "helpers").mkdir(parents=True, exist_ok=True)
        (d / "helpers" / "util.txt").write_text("support\n")
        return d

    sb.reset()
    with rep.case("6.4", "directory import copies support files") as c:
        d = make_dir_skill()
        r = cli.si("--format", "json", "import", "path", "--path", str(d))
        c.exit(r, 0)
        c.path_exists(Path(sb.imports) / "dir-skill" / "helpers" / "util.txt")
        c.json(r, lambda o: any(a["action"] == "copy_file" for a in o["actions"]))

    sb.reset()
    with rep.case("6.5", "directory without SKILL.md") as c:
        d = Path(sb.work) / "no-skill"
        (d).mkdir(parents=True, exist_ok=True)
        (d / "readme.md").write_text("hi\n")
        r = cli.si("import", "path", "--path", str(d))
        c.exit(r, 1)
        c.stderr_has(r, "directory has no SKILL.md")
        if os.listdir(sb.imports):
            c.fail("no storage expected")

    sb.reset()
    with rep.case("6.6", "symlink inside source rejected") as c:
        d = make_dir_skill()
        os.symlink(str(d / "helpers" / "util.txt"), str(d / "link.txt"))
        r = cli.si("import", "path", "--path", str(d))
        c.exit(r, 1)
        c.stderr_has(r, "unsupported filesystem entry")
        c.path_absent(Path(sb.imports) / "dir-skill")

    sb.reset()
    with rep.case("6.7", "reserved import.json in source") as c:
        d = make_dir_skill()
        (d / "import.json").write_text("{}")
        r = cli.si("import", "path", "--path", str(d))
        c.exit(r, 1)
        c.stderr_has(r, "reserved import.json")

    sb.reset()
    with rep.case("6.8", "imports root inside source dir") as c:
        d = make_dir_skill()
        nested = d / "nested-imports"
        r = cli.si("--imports-root", str(nested),
                   "import", "path", "--path", str(d))
        c.exit(r, 1)
        c.stderr_has(r, "imports root is inside the source directory")

    sb.reset()
    with rep.case("6.9", "collision on re-import") as c:
        d = make_dir_skill()
        r1 = cli.si("import", "path", "--path", str(d))
        c.exit(r1, 0)
        r2 = cli.si("import", "path", "--path", str(d))
        c.exit(r2, 1)
        c.stderr_has(r2, "already exists")
