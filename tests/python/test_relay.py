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


class RelayTests(unittest.TestCase):
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

    def test_child_exit_closes_connection(self):
        port = start_relay()
        with connect(port) as c:
            c.sendall(b"exit\n")
            self.assertEqual(c.recv(10), b"")


if __name__ == "__main__":
    unittest.main()
