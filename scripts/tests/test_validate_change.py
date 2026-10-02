import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "validate-change.py"
spec = importlib.util.spec_from_file_location("validate_change", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


@unittest.skipUnless(os.name == "posix", "process groups require POSIX")
class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / ".harness").mkdir()
        (self.root / ".gitignore").write_text(".harness/\n")
        (self.root / "source.txt").write_text("original\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.STDOUT)

    def check(self, name, code, timeout=3):
        return {"name": name, "argv": [sys.executable, "-c", code], "timeout_seconds": timeout}

    def run_plan(self, checks, minimum=0):
        plan = self.root / ".harness" / "plan.json"
        plan.write_text(json.dumps({"reason": "Validation runner integration fixtures", "minimum_free_gib": minimum, "checks": checks}))
        result = subprocess.run([sys.executable, str(SCRIPT), str(plan)], cwd=self.root, capture_output=True, text=True, timeout=10)
        paths = sorted((self.root / ".harness" / "validation").glob("*/receipt.json"))
        self.assertTrue(paths, result.stderr + result.stdout)
        return result, json.loads(paths[-1].read_text())

    def test_independent_checks_really_overlap_and_capture_logs(self):
        checks = []
        for name, other in [("one", "two"), ("two", "one")]:
            checks.append(self.check(name, f"from pathlib import Path; import time\nPath('.harness/{name}').touch()\nwhile not Path('.harness/{other}').exists(): time.sleep(.02)\nprint('{name} finished')"))
        result, receipt = self.run_plan(checks)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(receipt["status"], "passed")
        self.assertEqual(len(receipt["checks"]), 2)
        for check in receipt["checks"]:
            self.assertIn("finished", Path(check["log"]).read_text())
            self.assertGreater(check["duration_seconds"], 0)
        self.assertEqual(receipt["source"], receipt["source_after"])

    def test_failure_does_not_hide_other_results(self):
        result, receipt = self.run_plan([self.check("bad", "import sys; sys.exit(7)"), self.check("good", "print('ok')")])
        self.assertEqual(result.returncode, 1)
        checks = {c["name"]: c for c in receipt["checks"]}
        self.assertEqual(checks["bad"]["exit_code"], 7)
        self.assertEqual(checks["good"]["status"], "passed")

    def test_timeout_kills_owned_children_even_if_parent_exits_on_term(self):
        child = "import signal,time; from pathlib import Path; signal.signal(signal.SIGTERM, signal.SIG_IGN)\nwhile True:\n with Path('.harness/beats').open('a') as f: f.write('x')\n time.sleep(.02)"
        parent = f"import subprocess,sys,time; subprocess.Popen([sys.executable, '-c', {child!r}]); time.sleep(30)"
        result, receipt = self.run_plan([self.check("stalled", parent, .5)])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt["checks"][0]["status"], "timeout")
        beats = self.root / ".harness" / "beats"
        size = beats.stat().st_size
        self.assertGreater(size, 0)
        time.sleep(.15)
        self.assertEqual(beats.stat().st_size, size, "a child fixture survived cleanup")

    def test_low_disk_blocks_before_starting_commands(self):
        result, receipt = self.run_plan([self.check("never", "from pathlib import Path; Path('.harness/ran').touch()")], minimum=10**9)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt["status"], "blocked")
        self.assertEqual(receipt["checks"][0]["status"], "not_run")
        self.assertFalse((self.root / ".harness" / "ran").exists())

    def test_source_edit_invalidates_successful_checks(self):
        result, receipt = self.run_plan([self.check("edit", "from pathlib import Path; Path('source.txt').write_text('changed')")])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt["checks"][0]["status"], "passed")
        self.assertEqual(receipt["status"], "source_changed")

    def test_untracked_file_content_is_part_of_fingerprint(self):
        new = self.root / "new.txt"
        new.write_text("one")
        before = runner.source_state(self.root)
        new.write_text("two")
        after = runner.source_state(self.root)
        self.assertEqual(before["commit"], after["commit"])
        self.assertNotEqual(before["working_changes_sha256"], after["working_changes_sha256"])
        self.assertTrue(after["dirty"])

    def test_missing_executable_is_blocked_not_passed(self):
        result, receipt = self.run_plan([{"name": "missing", "argv": ["/no/such/validation-tool"], "timeout_seconds": 1}])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt["checks"][0]["status"], "blocked")

    def test_empty_plan_and_unsafe_log_names_are_rejected(self):
        for checks in [[], [self.check("../escape", "pass")]]:
            plan = self.root / ".harness" / "invalid.json"
            plan.write_text(json.dumps({"reason": "fixture", "checks": checks}))
            with self.assertRaises(ValueError):
                runner.read_plan(plan, self.root)


if __name__ == "__main__":
    unittest.main()
