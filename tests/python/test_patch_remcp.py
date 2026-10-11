import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "templates" / "guest" / "mcp"))
import patch_remcp  # noqa: E402

# re_mcp_ghidra 3.0.3 session.py, Session.save().
ORIGINAL = '''    def save(self) -> None:
        """Persist the current program to disk."""
        if self._program is None or self._project is None:
            raise GhidraError("No database is open.", error_type="NoDatabase")

        from ghidra.util.task import TaskMonitor  # noqa: PLC0415

        self._end_open_transactions()

        df = self._program.getDomainFile()
        if df is not None and df.canSave():
            df.save(TaskMonitor.DUMMY)
        else:
            self._project.saveAs(self._program, "/", self._program.getName(), True)
'''


def session_file(text):
    path = Path(tempfile.mkdtemp()) / "session.py"
    path.write_text(text, encoding="utf-8")
    return path


class PatchTests(unittest.TestCase):
    def test_saves_through_ghidra_project(self):
        # GhidraProject keeps a transaction open on every program it opens; df.save() then fails with
        # "Unable to lock due to active transaction" and renames are lost. GhidraProject.save() handles it.
        path = session_file(ORIGINAL)
        self.assertTrue(patch_remcp.patch(path))
        text = path.read_text(encoding="utf-8")
        self.assertIn("self._project.save(self._program)", text)
        self.assertNotIn("df.save(TaskMonitor.DUMMY)", text)

    def test_second_run_changes_nothing(self):
        path = session_file(ORIGINAL)
        patch_remcp.patch(path)
        once = path.read_text(encoding="utf-8")
        self.assertFalse(patch_remcp.patch(path))
        self.assertEqual(path.read_text(encoding="utf-8"), once)

    def test_unknown_version_fails_loudly(self):
        path = session_file("def save(self):\n    pass\n")
        with self.assertRaisesRegex(RuntimeError, "re-mcp-ghidra"):
            patch_remcp.patch(path)


if __name__ == "__main__":
    unittest.main()
