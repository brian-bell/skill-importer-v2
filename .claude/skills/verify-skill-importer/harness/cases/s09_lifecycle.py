"""§9 promote / unpromote / delete — the imported-draft lifecycle."""

import json as _json
import os
from pathlib import Path

DRAFT = "---\nname: draft\ndescription: a draft\n---\n# d\n"


def _import_draft(cli, name="draft", desc="a draft"):
    cli.si("import", "markdown",
           stdin="---\nname: {}\ndescription: {}\n---\n# d\n".format(name, desc))


def _manifest_promoted(sb, name="draft"):
    p = Path(sb.imports) / name / "import.json"
    return _json.loads(p.read_text())["promoted"] if p.exists() else None


def run(cli, sb, rep):
    # --- promote ---
    sb.reset()
    _import_draft(cli)
    with rep.case("9.1", "promote happy: copies, excludes import.json, marks promoted") as c:
        r = cli.si("--format", "json", "promote", "--skill", "draft")
        c.exit(r, 0)
        c.path_exists(Path(sb.canonical) / "draft" / "SKILL.md")
        c.path_absent(Path(sb.canonical) / "draft" / "import.json")
        if _manifest_promoted(sb) is not True:
            c.fail("draft manifest promoted should be true")

    with rep.case("9.2", "already promoted") as c:
        r = cli.si("promote", "--skill", "draft")
        c.exit(r, 1)
        c.stderr_has(r, "already promoted")

    with rep.case("9.3", "promote unknown") as c:
        r = cli.si("promote", "--skill", "nope")
        c.exit(r, 1)
        c.stderr_has(r, "unknown skill")

    sb.reset()
    sb.mk_canonical("conly")
    with rep.case("9.4", "promote canonical-only") as c:
        r = cli.si("promote", "--skill", "conly")
        c.exit(r, 1)
        c.stderr_has(r, "exists only in the canonical root")

    sb.reset()
    sb.mk_canonical("draft")  # canonical collision target
    _import_draft(cli)
    with rep.case("9.5", "promote collision without --overwrite") as c:
        r = cli.si("promote", "--skill", "draft")
        c.exit(r, 1)
        c.stderr_has(r, "a canonical skill already exists at the destination")

    with rep.case("9.6", "promote with --overwrite") as c:
        r = cli.si("--format", "json", "promote", "--skill", "draft", "--overwrite")
        c.exit(r, 0)
        c.path_exists(Path(sb.canonical) / "draft" / "SKILL.md")

    sb.reset()
    # Existing canonical dest whose SKILL.md frontmatter name differs.
    sb.mk_skill_md(Path(sb.canonical) / "draft" / "SKILL.md", "different-name", "x")
    _import_draft(cli)
    with rep.case("9.7", "overwrite name mismatch must fail") as c:
        r = cli.si("promote", "--skill", "draft", "--overwrite")
        c.exit(r, 1)
        c.stderr_has(r, "a canonical skill already exists at the destination")

    sb.reset()
    # A different-named canonical dir whose SKILL.md name equals the draft's.
    sb.mk_skill_md(Path(sb.canonical) / "other-dir" / "SKILL.md", "draft", "x")
    _import_draft(cli)
    with rep.case("9.8", "frontmatter name collision elsewhere") as c:
        r = cli.si("promote", "--skill", "draft")
        c.exit(r, 1)
        c.stderr_has(r, "frontmatter name already exists")

    sb.reset()
    _import_draft(cli)
    with rep.case("9.9", "unsupported import entry (symlink)") as c:
        os.symlink("/etc/hosts", str(Path(sb.imports) / "draft" / "link"))
        r = cli.si("promote", "--skill", "draft")
        c.exit(r, 1)
        c.stderr_has(r, "unsupported filesystem entry")

    sb.reset()
    _import_draft(cli)
    with rep.case("9.10", "relink legacy managed import symlink on promote") as c:
        # A legacy managed import symlink points straight into the import dir (the
        # normal `enable` refuses unpromoted imports, per 8.14, so create it by
        # hand). Promote must relink it to the canonical promoted copy.
        link = Path(sb.codex) / "draft"
        os.symlink(str(Path(sb.imports) / "draft"), str(link))
        r = cli.si("promote", "--skill", "draft")
        c.exit(r, 0)
        c.path_exists(link)
        # macOS /var -> /private/var, so compare resolved paths on both sides.
        tgt = os.path.realpath(str(link))
        want = os.path.realpath(str(Path(sb.canonical) / "draft"))
        if tgt != want:
            c.fail("symlink should relink to {}, got {}".format(want, tgt))

    sb.reset()
    _import_draft(cli)
    with rep.case("9.11", "overwrite safety (postcondition only)") as c:
        # Forcing a mid-copy failure from outside the process is unreliable; assert
        # the observable invariant on a normal overwrite and flag for manual review.
        sb.mk_skill_md(Path(sb.canonical) / "draft" / "SKILL.md", "draft", "old")
        r = cli.si("promote", "--skill", "draft", "--overwrite")
        c.exit(r, 0)
        c.path_exists(Path(sb.canonical) / "draft" / "SKILL.md")
        c.indeterminate("mid-copy failure not simulable externally; happy path only")

    # --- unpromote ---
    sb.reset()
    _import_draft(cli)
    cli.si("promote", "--skill", "draft")
    cli.si("enable", "--skill", "draft", "--agent", "codex")  # promoted -> enable ok
    with rep.case("9.12", "unpromote removes canonical + agent symlinks, marks not promoted") as c:
        c.path_exists(Path(sb.codex) / "draft")  # precondition: symlink present
        r = cli.si("--format", "json", "unpromote", "--skill", "draft")
        c.exit(r, 0)
        c.path_absent(Path(sb.canonical) / "draft")
        c.path_absent(Path(sb.codex) / "draft")  # managed agent symlink removed
        if _manifest_promoted(sb) is not False:
            c.fail("manifest promoted should be false after unpromote")

    with rep.case("9.13", "unpromote not promoted") as c:
        r = cli.si("unpromote", "--skill", "draft")
        c.exit(r, 1)
        c.stderr_has(r, "not promoted")

    sb.reset()
    sb.mk_canonical("conly")
    with rep.case("9.14", "unpromote canonical-only") as c:
        r = cli.si("unpromote", "--skill", "conly")
        c.exit(r, 1)
        c.stderr_has(r, "exists only in the canonical root")

    with rep.case("9.15", "unpromote unknown") as c:
        r = cli.si("unpromote", "--skill", "nope")
        c.exit(r, 1)
        c.stderr_has(r, "unknown skill")

    # --- delete ---
    sb.reset()
    _import_draft(cli)
    with rep.case("9.16", "delete unpromoted draft removes imports dir") as c:
        r = cli.si("--format", "json", "delete", "--skill", "draft")
        c.exit(r, 0)
        c.path_absent(Path(sb.imports) / "draft")

    sb.reset()
    _import_draft(cli)
    cli.si("promote", "--skill", "draft")
    with rep.case("9.17", "delete promoted blocked") as c:
        r = cli.si("delete", "--skill", "draft")
        c.exit(r, 1)
        c.stderr_has(r, "already promoted")

    sb.reset()
    _import_draft(cli)
    with rep.case("9.18", "delete blocked by legacy enabled import symlink") as c:
        # Legacy managed import symlink (created by hand; see 9.10). Delete must
        # refuse it ("the import is enabled; disable it first").
        os.symlink(str(Path(sb.imports) / "draft"), str(Path(sb.codex) / "draft"))
        r = cli.si("delete", "--skill", "draft")
        c.exit(r, 1)
        c.stderr_has(r, "enabled")

    sb.reset()
    sb.mk_canonical("conly")
    with rep.case("9.19", "delete canonical-only") as c:
        r = cli.si("delete", "--skill", "conly")
        c.exit(r, 1)
        c.stderr_has(r, "exists only in the canonical root")

    sb.reset()
    _import_draft(cli)
    with rep.case("9.20", "delete leaves unrelated same-name agent entry") as c:
        # An unrelated unsafe agent entry with the same name must not block delete.
        os.symlink("/tmp/outside", str(Path(sb.claude) / "draft"))
        r = cli.si("delete", "--skill", "draft")
        c.exit(r, 0)
        c.path_absent(Path(sb.imports) / "draft")
        if not os.path.islink(str(Path(sb.claude) / "draft")):
            c.fail("unrelated agent symlink must be left untouched")
