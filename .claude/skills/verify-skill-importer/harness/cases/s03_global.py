"""§3 Global parsing & smoke tests. All hermetic; needles from main.zig kindMessage
(parse-error reasons from cli.zig appended after 'invalid command line: ')."""


def run(cli, sb, rep):
    with rep.case("3.1", "list empty -> text 'no skills found'") as c:
        r = cli.si("list")
        c.exit(r, 0)
        if "no skills found" not in r.out:
            c.fail("expected 'no skills found', got {!r}".format(r.out))

    with rep.case("3.2", "--format json list -> empty inventory") as c:
        r = cli.si("--format", "json", "list")
        c.exit(r, 0)
        c.json(r, lambda o: o == {"skills": [], "source_repositories": []})
        c.json_newline(r)

    with rep.case("3.3", "json output ends in single newline") as c:
        r = cli.si("--format", "json", "list")
        c.exit(r, 0)
        c.json_newline(r)

    with rep.case("3.4", "no command -> missing command") as c:
        r = cli.si()
        c.exit(r, 1)
        c.stderr_has(r, "missing command")

    with rep.case("3.5", "unknown command") as c:
        r = cli.si("bogus")
        c.exit(r, 1)
        c.stderr_has(r, "unknown command")

    with rep.case("3.6", "invalid --format value") as c:
        r = cli.si("--format", "xml", "list")
        c.exit(r, 1)
        c.stderr_has(r, "invalid --format value")

    with rep.case("3.7", "--format requires a value") as c:
        r = cli.si("--format")
        c.exit(r, 1)
        c.stderr_has(r, "--format requires a value")

    with rep.case("3.8", "unknown global option") as c:
        r = cli.si("--bogus-root", "x", "list")
        c.exit(r, 1)
        c.stderr_has(r, "unknown global option")

    with rep.case("3.9", "list takes no options") as c:
        r = cli.si("list", "--extra")
        c.exit(r, 1)
        c.stderr_has(r, "command takes no options")

    with rep.case("3.10", "parse error regardless of format") as c:
        r = cli.si("--format", "json", "bogus")
        c.exit(r, 1)
        c.stderr_has(r, "unknown command")

    with rep.case("3.11", "globals must precede command word") as c:
        # --format after the command word is rejected by `list` as an unknown option.
        r = cli.si("list", "--format", "json")
        c.exit(r, 1)
        c.stderr_has(r, "command takes no options")
