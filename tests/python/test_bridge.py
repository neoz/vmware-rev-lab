import json
import socket
import sys
import threading
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


def message(obj):
    return json.dumps(obj).encode() + b"\n"


INIT = message({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
INITIALIZED = message({"jsonrpc": "2.0", "method": "notifications/initialized"})


class Output:
    def __init__(self):
        self.lines = []
        self.changed = threading.Condition()

    def write(self, data):
        with self.changed:
            self.lines.extend(json.loads(x) for x in data.splitlines() if x.strip())
            self.changed.notify_all()

    def wait_for(self, request_id, timeout=10):
        with self.changed:
            self.changed.wait_for(lambda: any(x.get("id") == request_id for x in self.lines), timeout)
            return next(x for x in self.lines if x.get("id") == request_id)


class Guest:
    """The guest end of one connection, over a local socket pair."""

    def __init__(self):
        self.sock, self.bridge_end = socket.socketpair()
        self.file = self.sock.makefile("rb")

    def read(self):
        return json.loads(self.file.readline())

    def reply(self, request_id, result=None):
        self.sock.sendall(message({"jsonrpc": "2.0", "id": request_id, "result": result or {}}))

    def close(self):
        self.file.close()
        self.sock.close()


class BridgeTests(unittest.TestCase):
    def start(self, guests):
        out = Output()
        pending = list(guests)
        b = bridge.Bridge(lambda: pending.pop(0).bridge_end, out.write, "vsock port 5001")
        return b, out

    def test_closed_before_any_reply_says_the_relay_is_busy(self):
        guest = Guest()
        guest.close()
        b, out = self.start([guest])
        b.send_line(INIT)
        self.assertIn("another session", out.wait_for(1)["error"]["message"])

    def test_unreachable_guest_answers_the_request_and_keeps_running(self):
        def connect():
            raise OSError("refused")
        out = Output()
        b = bridge.Bridge(connect, out.write, "vsock port 5001")
        b.send_line(INIT)
        self.assertIn("refused", out.wait_for(1)["error"]["message"])
        b.send_line(message({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}))
        self.assertIn("refused", out.wait_for(2)["error"]["message"])

    def test_revert_fails_in_flight_calls_then_reconnects_and_replays_the_handshake(self):
        first, second = Guest(), Guest()
        b, out = self.start([first, second])
        b.send_line(INIT)
        self.assertEqual(first.read()["method"], "initialize")
        first.reply(1, {"serverInfo": {"name": "x"}})
        out.wait_for(1)
        b.send_line(INITIALIZED)
        b.send_line(message({"jsonrpc": "2.0", "id": 2, "method": "tools/call"}))
        first.read(), first.read()
        first.close()  # VM reverted
        self.assertIn("reverted", out.wait_for(2)["error"]["message"])

        b.send_line(message({"jsonrpc": "2.0", "id": 3, "method": "tools/list"}))
        replay = second.read()
        self.assertEqual(replay["method"], "initialize")
        self.assertNotIn(replay["id"], (1, 2, 3))
        self.assertEqual(second.read()["method"], "notifications/initialized")
        self.assertEqual(second.read()["id"], 3)
        second.reply(replay["id"])
        second.reply(3, {"tools": []})
        self.assertEqual(out.wait_for(3)["result"], {"tools": []})
        self.assertFalse(any(x.get("id") == replay["id"] for x in out.lines))


if __name__ == "__main__":
    unittest.main()
