#!/usr/bin/env python3
"""Unit tests for the verification harness core library (harness.py).

These cover the pure-Python infrastructure — Sandbox fixtures, the Case
assertion accumulator, and the Reporter tallies/exit-semantics — with no
dependency on the real skill-importer binary. Run from the harness/ dir:

    python3 -m unittest test_harness -v

(The case modules under cases/ are validated separately by running run.py
against the built binary; that end-to-end run is the harness's own
integration test.)
"""

import json
import os
import unittest
from pathlib import Path

from harness import Sandbox, Reporter, Result, section_of, plan_case_ids


class TestSandbox(unittest.TestCase):
    def test_creates_all_roots(self):
        with Sandbox() as sb:
            for p in (sb.home, sb.canonical, sb.imports, sb.claude, sb.codex, sb.work):
                self.assertTrue(Path(p).is_dir(), f"{p} should be a dir")

    def test_roots_live_under_one_tempdir(self):
        with Sandbox() as sb:
            # Every root must be inside the single mkdtemp sandbox — never a real
            # user path. This is the load-bearing safety invariant.
            for p in (sb.home, sb.canonical, sb.imports, sb.claude, sb.codex):
                self.assertTrue(str(p).startswith(str(sb.root)))
            # And the sandbox root must not be a real home-relative path.
            self.assertNotIn(str(Path.home()), str(sb.root))

    def test_cleanup_removes_tree(self):
        sb = Sandbox()
        root = sb.root
        self.assertTrue(Path(root).exists())
        sb.cleanup()
        self.assertFalse(Path(root).exists())

    def test_reset_clears_prior_state(self):
        with Sandbox() as sb:
            (Path(sb.imports) / "leftover").mkdir()
            sb.reset()
            self.assertFalse((Path(sb.imports) / "leftover").exists())
            self.assertTrue(Path(sb.imports).is_dir())

    def test_mk_skill_md_writes_frontmatter(self):
        with Sandbox() as sb:
            dest = Path(sb.work) / "s" / "SKILL.md"
            sb.mk_skill_md(dest, "my-skill", "a desc")
            text = dest.read_text()
            self.assertIn("---\nname: my-skill\ndescription: a desc\n---", text)

    def test_mk_canonical_creates_skill_dir(self):
        with Sandbox() as sb:
            sb.mk_canonical("canon-x")
            md = Path(sb.canonical) / "canon-x" / "SKILL.md"
            self.assertTrue(md.is_file())
            self.assertIn("name: canon-x", md.read_text())


class TestSectionOf(unittest.TestCase):
    def test_plain_id(self):
        self.assertEqual(section_of("4.1"), "4")

    def test_two_digit_section(self):
        self.assertEqual(section_of("12.9"), "12")

    def test_lettered_id(self):
        # 11.2a must map to section 11, not "11.2a".
        self.assertEqual(section_of("11.2a"), "11")


class TestCaseAssertions(unittest.TestCase):
    def setUp(self):
        self.rep = Reporter()

    def test_exit_pass(self):
        with self.rep.case("1.1", "ok") as c:
            c.exit(Result(0, "", ""), 0)
        self.assertEqual(self.rep.results[-1].status, "pass")

    def test_exit_fail(self):
        with self.rep.case("1.2", "bad exit") as c:
            c.exit(Result(1, "", "boom"), 0)
        r = self.rep.results[-1]
        self.assertEqual(r.status, "fail")
        self.assertTrue(any("exit" in m for m in r.messages))

    def test_stderr_has_pass(self):
        with self.rep.case("1.3", "err") as c:
            c.exit(Result(1, "", "skill-importer: unknown skill (skill: x)\n"), 1)
            c.stderr_has(Result(1, "", "skill-importer: unknown skill (skill: x)\n"), "unknown skill")
        self.assertEqual(self.rep.results[-1].status, "pass")

    def test_stderr_has_requires_prefix(self):
        with self.rep.case("1.4", "noprefix") as c:
            c.stderr_has(Result(1, "", "unknown skill\n"), "unknown skill")
        self.assertEqual(self.rep.results[-1].status, "fail")

    def test_stderr_has_flags_nonempty_stdout(self):
        # Failure cases must write nothing to stdout (§13 contract).
        with self.rep.case("1.5", "leak") as c:
            c.stderr_has(Result(1, "leaked output", "skill-importer: unknown skill\n"), "unknown skill")
        self.assertEqual(self.rep.results[-1].status, "fail")

    def test_json_predicate_pass(self):
        out = json.dumps({"skill_name": "x"}) + "\n"
        with self.rep.case("1.6", "json") as c:
            obj = c.json(Result(0, out, ""), lambda o: o["skill_name"] == "x")
        self.assertEqual(self.rep.results[-1].status, "pass")
        self.assertEqual(obj["skill_name"], "x")

    def test_json_predicate_fail(self):
        out = json.dumps({"skill_name": "y"}) + "\n"
        with self.rep.case("1.7", "json") as c:
            c.json(Result(0, out, ""), lambda o: o["skill_name"] == "x")
        self.assertEqual(self.rep.results[-1].status, "fail")

    def test_json_invalid_is_fail_not_crash(self):
        with self.rep.case("1.8", "badjson") as c:
            c.json(Result(0, "not json", ""), lambda o: True)
        self.assertEqual(self.rep.results[-1].status, "fail")

    def test_json_newline_single(self):
        with self.rep.case("1.9", "nl") as c:
            c.json_newline(Result(0, '{"a":1}\n', ""))
        self.assertEqual(self.rep.results[-1].status, "pass")

    def test_json_newline_rejects_double(self):
        with self.rep.case("1.10", "nl2") as c:
            c.json_newline(Result(0, '{"a":1}\n\n', ""))
        self.assertEqual(self.rep.results[-1].status, "fail")

    def test_json_newline_rejects_missing(self):
        with self.rep.case("1.11", "nonl") as c:
            c.json_newline(Result(0, '{"a":1}', ""))
        self.assertEqual(self.rep.results[-1].status, "fail")

    def test_path_exists_and_absent(self):
        with Sandbox() as sb:
            present = Path(sb.work) / "here"
            present.write_text("x")
            with self.rep.case("1.12", "paths") as c:
                c.path_exists(present)
                c.path_absent(Path(sb.work) / "nope")
            self.assertEqual(self.rep.results[-1].status, "pass")

    def test_na_terminal(self):
        with self.rep.case("1.13", "skip") as c:
            c.na("no network")
        r = self.rep.results[-1]
        self.assertEqual(r.status, "na")
        self.assertIn("no network", r.messages[0])

    def test_indeterminate_terminal(self):
        with self.rep.case("1.14", "maybe") as c:
            c.indeterminate("rollback not exercised")
        self.assertEqual(self.rep.results[-1].status, "indeterminate")

    def test_failure_wins_over_na(self):
        # A recorded failure must NOT be masked by a terminal marker.
        with self.rep.case("1.15", "skip") as c:
            c.exit(Result(1, "", ""), 0)  # fails
            c.na("env unavailable")
        self.assertEqual(self.rep.results[-1].status, "fail")

    def test_failure_wins_over_indeterminate(self):
        # 7.12/9.11 assert a postcondition then mark indeterminate; a regressed
        # postcondition must surface as FAIL, not be hidden as INDETERMINATE.
        with self.rep.case("1.17", "postcondition + indet") as c:
            c.path_absent("/")  # fails: "/" exists
            c.indeterminate("rollback not exercised")
        self.assertEqual(self.rep.results[-1].status, "fail")

    def test_clean_indeterminate_still_reports_indeterminate(self):
        with self.rep.case("1.18", "clean indet") as c:
            c.exit(Result(0, "", ""), 0)  # passes
            c.indeterminate("external effect; verify by hand")
        self.assertEqual(self.rep.results[-1].status, "indeterminate")

    def test_exception_in_body_records_fail(self):
        # A bug in case setup must be a FAIL for that case, not a harness crash.
        with self.rep.case("1.16", "boom") as c:
            raise RuntimeError("setup blew up")
        self.assertEqual(self.rep.results[-1].status, "fail")


class TestReporter(unittest.TestCase):
    def test_groups_by_section_and_tallies(self):
        rep = Reporter()
        with rep.case("4.1", "a") as c:
            c.exit(Result(0, "", ""), 0)
        with rep.case("4.2", "b") as c:
            c.exit(Result(1, "", "x"), 0)
        with rep.case("5.1", "c") as c:
            c.na("no net")
        tallies = rep.section_tallies()
        self.assertEqual(tallies["4"], {"pass": 1, "fail": 1, "na": 0, "indeterminate": 0})
        self.assertEqual(tallies["5"], {"pass": 0, "fail": 0, "na": 1, "indeterminate": 0})

    def test_exit_code_one_on_any_fail(self):
        rep = Reporter()
        with rep.case("4.1", "a") as c:
            c.exit(Result(1, "", "x"), 0)
        self.assertEqual(rep.exit_code(), 1)

    def test_exit_code_zero_when_only_na_and_indeterminate(self):
        rep = Reporter()
        with rep.case("5.1", "a") as c:
            c.na("no net")
        with rep.case("7.12", "b") as c:
            c.indeterminate("rollback")
        self.assertEqual(rep.exit_code(), 0)

    def test_executed_ids(self):
        rep = Reporter()
        with rep.case("3.1", "a") as c:
            c.exit(Result(0, "", ""), 0)
        with rep.case("11.2a", "b") as c:
            c.na("linux")
        self.assertEqual(rep.executed_ids(), {"3.1", "11.2a"})


class TestPlanCaseIds(unittest.TestCase):
    def test_parses_table_row_ids_from_markdown(self):
        sample = "\n".join(
            [
                "| # | Command | Expect |",
                "| - | ------- | ------ |",
                "| 3.1 | `si list` | exit 0 |",
                "| 11.2a | non-macos | exit 1 |",
                "- [ ] 3.1 checklist line should NOT be counted as a separate id",
            ]
        )
        ids = plan_case_ids(sample)
        self.assertIn("3.1", ids)
        self.assertIn("11.2a", ids)
        # The checklist bullet shares id 3.1; set dedups, so still 2 unique.
        self.assertEqual(len(ids), 2)


if __name__ == "__main__":
    unittest.main()
