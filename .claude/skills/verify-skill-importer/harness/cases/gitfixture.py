"""Shared git-fixture helper for repository cases (§7, §12.7).

The `import repository` provider always shells `git clone`, so fixtures must be
real git repos. These invocations pin identity and disable commit signing so they
can't fail on machines with `commit.gpgsign=true` globally, and every step's exit
code is checked so a fixture failure never masquerades as a product regression.
"""

import os
import subprocess


def _clean_env():
    """Neutralize the operator's git environment so fixtures can't escape the
    sandbox: drop all GIT_* vars (GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE could
    redirect ops at a real worktree) and ignore global/system config (which could
    carry core.hooksPath and run user hooks)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    env["GIT_CONFIG_SYSTEM"] = os.devnull
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def git(args, cwd):
    return subprocess.run(
        ["git", "-c", "user.email=v@v.test", "-c", "user.name=verify",
         "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false",
         "-c", "core.hooksPath=/dev/null", *args],
        cwd=str(cwd), capture_output=True, text=True, env=_clean_env(),
    )


def init_commit(d):
    """git init + add -A + commit in directory `d`; raise on any failure so the
    case reports a setup FAIL rather than silently importing an empty repo."""
    for a in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "init"]):
        r = git(a, d)
        if r.returncode != 0:
            raise RuntimeError("git {} failed: {}".format(" ".join(a), r.stderr.strip()))
