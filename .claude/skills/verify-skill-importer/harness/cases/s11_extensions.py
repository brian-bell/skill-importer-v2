"""§11 non-spec extensions: render-analysis-report (11.1) and tui (11.3).
analyze (11.2) is platform-gated and lives in gated/analyze.py."""

from pathlib import Path

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


def run(cli, sb, rep):
    sb.reset()
    good = str(FIXTURES / "report.json")
    bad = str(FIXTURES / "report.bad.json")

    with rep.case("11.1a", "render happy") as c:
        out = Path(sb.work) / "out.html"
        r = cli.run(["render-analysis-report", "--input", good, "--output", str(out)],
                    env=cli.base_env())
        c.exit(r, 0)
        c.path_exists(out)
        if "wrote" not in r.out:
            c.fail("expected 'wrote' in text output, got {!r}".format(r.out))

    with rep.case("11.1b", "render --format json -> {output}") as c:
        out = Path(sb.work) / "out2.html"
        r = cli.run(["--format", "json", "render-analysis-report",
                     "--input", good, "--output", str(out)], env=cli.base_env())
        c.exit(r, 0)
        c.json(r, lambda o: o.get("output") == str(out))
        c.json_newline(r)

    with rep.case("11.1c", "render missing --input") as c:
        out = Path(sb.work) / "out3.html"
        r = cli.run(["render-analysis-report", "--output", str(out)], env=cli.base_env())
        c.exit(r, 1)
        c.stderr_has(r, "requires --input")

    with rep.case("11.1d", "render input not a regular file") as c:
        out = Path(sb.work) / "out4.html"
        r = cli.run(["render-analysis-report", "--input", str(sb.work),
                     "--output", str(out)], env=cli.base_env())
        c.exit(r, 1)
        c.stderr_has(r, "not a readable regular file")

    with rep.case("11.1e", "render output exists") as c:
        out = Path(sb.work) / "exists.html"
        out.write_text("already here")
        r = cli.run(["render-analysis-report", "--input", good, "--output", str(out)],
                    env=cli.base_env())
        c.exit(r, 1)
        c.stderr_has(r, "output already exists")

    with rep.case("11.1f", "render malformed report") as c:
        out = Path(sb.work) / "out5.html"
        r = cli.run(["render-analysis-report", "--input", bad, "--output", str(out)],
                    env=cli.base_env())
        c.exit(r, 1)
        c.stderr_has(r, "analysis report JSON is malformed")

    with rep.case("11.1g", "render needs no HOME") as c:
        out = Path(sb.work) / "out6.html"
        r = cli.run(["render-analysis-report", "--input", good, "--output", str(out)],
                    env=cli.base_env(HOME=None))
        c.exit(r, 0)
        c.path_exists(out)

    # --- tui stub (11.3) ---
    with rep.case("11.3a", "tui not implemented") as c:
        r = cli.si("tui")
        c.exit(r, 1)
        c.stderr_has(r, "TUI not implemented")

    with rep.case("11.3b", "tui rejects --format json") as c:
        r = cli.si("--format", "json", "tui")
        c.exit(r, 1)
        c.stderr_has(r, "tui does not support --format json")

    with rep.case("11.3c", "tui takes no options") as c:
        r = cli.si("tui", "--extra")
        c.exit(r, 1)
        c.stderr_has(r, "command takes no options")
