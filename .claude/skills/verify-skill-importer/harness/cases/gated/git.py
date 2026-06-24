"""§7.13 (live git clone) and §7.14 (git unavailable).

7.14 strips PATH so the binary can't find git -> git_unavailable; runs everywhere.
7.13 needs a reachable repo URL (--git-url); N/A otherwise.
"""

import os


def run(cli, sb, rep, git_url=None):
    sb.reset()
    with rep.case("7.14", "git unavailable -> git not available") as c:
        # Empty PATH so `git` (resolved via PATH) cannot be spawned.
        r = cli.si("import", "repository", "--repository",
                   "https://example.invalid/x.git", extra_env={"PATH": ""})
        c.exit(r, 1)
        c.stderr_has(r, "git is not available")

    sb.reset()
    with rep.case("7.13", "live git clone") as c:
        if not git_url:
            c.na("no --git-url provided")
        else:
            r = cli.si("--format", "json", "import", "repository",
                       "--repository", git_url)
            c.exit(r, 0)
            c.json(r, lambda o: o.get("kind") in ("imported", "selection", "imported_batch"))
