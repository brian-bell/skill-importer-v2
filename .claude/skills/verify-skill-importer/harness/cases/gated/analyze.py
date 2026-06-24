"""§11.2 analyze. Platform gating is by COMPILE-TIME target (is_macos in main.zig),
derived from the binary itself (not the Python host). On a non-macOS build only
11.2a is reachable; on a macOS build 11.2b/11.2c are made deterministic by
controlling the subprocess environment (strip PATH so codex is unfindable; plant a
sandbox auth.json), and 11.2d stays indeterminate because it would launch real
`codex exec`."""

import os
import shutil
from pathlib import Path


def _is_macos_build(cli):
    """Probe with a nonexistent skill so nothing is ever launched: a non-macOS
    build reports 'supported only on macOS' before skill resolution; a macOS build
    reports 'unknown skill'."""
    r = cli.si("analyze", "--skill", "__verify_probe_nonexistent__")
    return "supported only on macOS" not in r.err


def _fake_bin(sb, names):
    """A dir of no-op executables. Prepended to PATH so the analyze launch can
    never reach the REAL codex/Terminal even if a guard regresses (defense in
    depth for the credential-safety negative test)."""
    d = Path(sb.work) / "fakebin"
    d.mkdir(parents=True, exist_ok=True)
    for n in names:
        p = d / n
        p.write_text("#!/bin/sh\nexit 0\n")
        p.chmod(0o755)
    return str(d)


def run(cli, sb, rep):
    is_macos = _is_macos_build(cli)
    sb.reset()
    sb.mk_canonical("analyze-target")

    with rep.case("11.2a", "non-macOS -> supported only on macOS") as c:
        if is_macos:
            c.na("macOS build: 11.2a (unsupported_platform) is unreachable here")
        else:
            r = cli.si("analyze", "--skill", "analyze-target")
            c.exit(r, 1)
            c.stderr_has(r, "supported only on macOS")

    with rep.case("11.2b", "codex unavailable (PATH stripped)") as c:
        if not is_macos:
            c.na("non-macOS build: analyze never reaches codex detection")
        else:
            # Deterministic, like 7.14 for git: empty PATH so `codex` can't be found.
            r = cli.si("analyze", "--skill", "analyze-target", extra_env={"PATH": ""})
            c.exit(r, 1)
            c.stderr_has(r, "codex CLI was not found")

    with rep.case("11.2c", "file-backed Codex auth refused (safe negative test)") as c:
        if not is_macos:
            c.na("non-macOS build: analyze never reaches the auth check")
        else:
            # Fake codex satisfies the availability check (step 5) without needing
            # a real codex; fake codex+osascript mean a regressed auth guard would
            # fall through to NO-OPS, never the real CLI/Terminal. codex_home is
            # <sandbox HOME>/.codex, so planting auth.json there is deterministic.
            fake = _fake_bin(sb, ["codex", "osascript"])
            env = {"PATH": fake + os.pathsep + os.environ.get("PATH", "")}
            auth = Path(sb.home) / ".codex" / "auth.json"
            auth.parent.mkdir(parents=True, exist_ok=True)
            auth.write_text('{"token":"sandbox-only"}')
            r = cli.si("analyze", "--skill", "analyze-target", extra_env=env)
            c.exit(r, 1)
            c.stderr_has(r, "file-backed Codex auth")
            os.remove(str(auth))

    with rep.case("11.2d", "macOS + working codex launches analysis") as c:
        if not is_macos or not shutil.which("codex"):
            c.na("requires macOS + a working codex CLI + valid auth")
        else:
            # The happy path spawns a real `codex exec`; don't run it from the
            # harness — assert by hand.
            c.indeterminate("would launch real `codex exec`; verify by hand")
