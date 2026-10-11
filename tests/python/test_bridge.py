import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "mcp"))
import revlab_bridge as bridge  # noqa: E402


class CidTests(unittest.TestCase):
    def test_read_cid(self):
        self.assertEqual(bridge.read_cid('vmci0.present = "TRUE"\nvmci0.id = "194935677"\n'), 194935677)

    def test_read_cid_negative(self):
        self.assertEqual(bridge.read_cid('vmci0.id = "-1"\n'), 0xFFFFFFFF)

    def test_read_cid_missing(self):
        with self.assertRaisesRegex(LookupError, "setup.ps1 -From McpBridge"):
            bridge.read_cid('displayName = "revlab"\n')


class PasswordTests(unittest.TestCase):
    def test_read_password_unescapes_quotes(self):
        self.assertEqual(bridge.read_password("@{\n    GuestPassword = 'ab''cd'\n}\n"), "ab'cd")


class RetryTests(unittest.TestCase):
    def test_starts_relay_once_then_retries(self):
        calls = {"connect": 0, "start": 0}

        def connect():
            calls["connect"] += 1
            if calls["connect"] < 3:
                raise OSError("refused")
            return "sock"

        def start():
            calls["start"] += 1

        self.assertEqual(bridge.connect_with_retry(connect, start, attempts=3, sleep=lambda s: None), "sock")
        self.assertEqual(calls, {"connect": 3, "start": 1})

    def test_gives_up(self):
        def connect():
            raise OSError("refused")

        with self.assertRaises(OSError):
            bridge.connect_with_retry(connect, lambda: None, attempts=2, sleep=lambda s: None)


class ErrorReplyTests(unittest.TestCase):
    def test_failure_reply_names_cause(self):
        line = json.dumps({"jsonrpc": "2.0", "id": 7, "method": "initialize", "params": {}}).encode() + b"\n"
        reply = json.loads(bridge.error_reply(line, "VM not running"))
        self.assertEqual(reply["id"], 7)
        self.assertIn("VM not running", reply["error"]["message"])

    def test_unparsable_first_line(self):
        reply = json.loads(bridge.error_reply(b"garbage\n", "x"))
        self.assertIsNone(reply["id"])


if __name__ == "__main__":
    unittest.main()
