import socket
import sys
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "templates" / "guest" / "mcp"))
import relay  # noqa: E402

CHILD = [sys.executable, str(Path(__file__).resolve().parent / "fixtures" / "echo_child.py")]


class TcpListener:
    """Stands in for vsock.Listener: same accept() contract over localhost TCP."""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(4)
        self.port = self.sock.getsockname()[1]

    def accept(self):
        return self.sock.accept()[0]


def start_relay():
    listener = TcpListener()
    threading.Thread(target=relay.run, args=(listener, CHILD, None), daemon=True).start()
    return listener.port


def connect(port):
    c = socket.create_connection(("127.0.0.1", port), timeout=10)
    return c


def ask(conn, text):
    conn.sendall(text.encode() + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    return data.decode()


def assert_closed(test, conn):
    # A prompt close is EOF or, with unread data on Windows, a reset; a timeout means the relay left it hanging.
    try:
        test.assertEqual(conn.recv(10), b"")
    except (ConnectionAbortedError, ConnectionResetError):
        pass


class RelayTests(unittest.TestCase):
    def test_child_stderr_goes_to_the_child_log(self):
        # Under pythonw the relay has no stderr; the child must get a real one or it dies on its first log line.
        import tempfile
        log = Path(tempfile.mkdtemp()) / "child.log"
        listener = TcpListener()
        threading.Thread(target=relay.run, args=(listener, CHILD, None, str(log)), daemon=True).start()
        with connect(listener.port) as c:
            ask(c, "hi")
        for _ in range(50):
            if log.exists() and "child banner on stderr" in log.read_text():
                break
            threading.Event().wait(0.1)
        self.assertIn("child banner on stderr", log.read_text())

    def test_round_trip(self):
        port = start_relay()
        with connect(port) as c:
            pid, text = ask(c, "hello").split(" ", 1)
            self.assertEqual(text, "hello\n")

    def test_second_connection_is_refused(self):
        port = start_relay()
        with connect(port) as first:
            ask(first, "one")
            with connect(port) as second:
                self.assertEqual(second.recv(10), b"")
            self.assertTrue(ask(first, "still").endswith("still\n"))

    def test_new_child_per_connection(self):
        port = start_relay()
        with connect(port) as c:
            pid1 = ask(c, "x").split(" ")[0]
        for _ in range(50):
            try:
                with connect(port) as c:
                    reply = ask(c, "y")
                if reply:
                    break
            except OSError:
                pass
        self.assertNotEqual(reply.split(" ")[0], pid1)

    def test_child_ignoring_eof_is_killed_after_grace(self):
        # A server that stays up after the host hangs up must not hold the port's only session forever.
        stubborn = [sys.executable, str(Path(__file__).resolve().parent / "fixtures" / "stubborn_child.py")]
        listener = TcpListener()
        old_grace, relay.GRACE_SECONDS = relay.GRACE_SECONDS, 0.5
        self.addCleanup(setattr, relay, "GRACE_SECONDS", old_grace)
        threading.Thread(target=relay.run, args=(listener, stubborn, None), daemon=True).start()
        with connect(listener.port) as c:
            ask(c, "one")
        reply = ""
        for _ in range(50):
            try:
                with connect(listener.port) as c:
                    reply = ask(c, "two")
            except OSError:
                pass
            if reply:
                break
            threading.Event().wait(0.2)
        self.assertTrue(reply.endswith("two\n"))

    def test_spawn_failure_closes_connection(self):
        listener = TcpListener()
        threading.Thread(target=relay.run, args=(listener, ["no-such-mcp-server.exe"], None), daemon=True).start()
        with connect(listener.port) as c:
            c.sendall(b"hi\n")
            assert_closed(self, c)

    def test_child_log_failure_closes_connection(self):
        listener = TcpListener()
        threading.Thread(target=relay.run, args=(listener, CHILD, None, "Z:/no/such/dir/child.log"), daemon=True).start()
        with connect(listener.port) as c:
            c.sendall(b"hi\n")
            assert_closed(self, c)

    def test_child_exit_closes_connection(self):
        port = start_relay()
        with connect(port) as c:
            c.sendall(b"exit\n")
            self.assertEqual(c.recv(10), b"")


if __name__ == "__main__":
    unittest.main()
