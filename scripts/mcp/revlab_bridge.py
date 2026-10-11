"""Stdio MCP entry for Claude Code: forwards stdio to an MCP server inside the lab VM over VMCI vSockets."""
import os

# Winsock providers (vSockets) fail with WSAEPROVIDERFAILEDINIT when SystemRoot is missing,
# and Winsock starts when the socket module is imported, so set it first.
os.environ.setdefault("SystemRoot", r"C:\Windows")

import argparse  # noqa: E402
import json  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402
import sys  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vsock  # noqa: E402


def read_cid(vmx_text):
    match = re.search(r'^\s*vmci0\.id\s*=\s*"(-?\d+)"', vmx_text, re.M)
    if not match:
        raise LookupError("vmci0.id not found in the VMX: the VM has no VMCI device; run .\\setup.ps1 -From McpBridge")
    return int(match.group(1)) & 0xFFFFFFFF


def read_password(local_text):
    match = re.search(r"GuestPassword\s*=\s*'((?:[^']|'')*)'", local_text)
    if not match:
        raise LookupError("GuestPassword not found in lab.local.psd1")
    return match.group(1).replace("''", "'")


def connect_with_retry(connect, start_relay, attempts=3, delay=5, budget=25, sleep=time.sleep, clock=time.monotonic):
    # Claude Code abandons a server that has not answered initialize in about 30 s; fail inside that budget
    # (VM paused or mid-revert) so the error message reaches the analyst.
    end = clock() + budget
    last = None
    for attempt in range(attempts):
        try:
            return connect()
        except OSError as exc:
            last = exc
        if attempt == 0:
            try:
                start_relay(timeout=max(1, end - clock()))
            except Exception:
                pass
        if attempt == attempts - 1 or clock() + delay >= end:
            break
        sleep(delay)
    raise last


def error_reply(first_line, message):
    try:
        request_id = json.loads(first_line).get("id")
    except (ValueError, AttributeError):
        request_id = None
    return (json.dumps({"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32000, "message": message}}) + "\n").encode()


REPLAY_ID = "revlab-bridge-replay"


class Bridge:
    """Forwards newline-delimited JSON-RPC between Claude Code and the guest relay.

    A VM revert or relay restart drops the connection. In-flight requests then get an error instead of hanging,
    and the next request reconnects and replays the cached handshake so the new server accepts it.
    """

    def __init__(self, connect, write, where):
        self.connect = connect
        self.write = write
        self.where = where
        self.lock = threading.Lock()
        self.sock = None
        self.answered = False
        self.pending = {}
        self.handshake = {}

    def send_line(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            msg = {}
        method = msg.get("method") if isinstance(msg, dict) else None
        is_request = method is not None and "id" in msg
        with self.lock:
            if method in ("initialize", "notifications/initialized"):
                self.handshake[method] = msg
            if self.sock is None:
                try:
                    self._open(replay=method != "initialize")
                except Exception as exc:
                    if is_request:
                        self.write(error_reply(line, f"revlab bridge cannot reach the guest MCP relay on {self.where}: {exc}. "
                                                     "Is the VM running from a snapshot that has VMCI and the relays "
                                                     "(setup.ps1 -From McpBridge)?"))
                    return
            if is_request:
                self.pending[msg["id"]] = line
            try:
                self.sock.sendall(line)
            except OSError:
                self._drop(self.sock)

    def _open(self, replay):
        sock = self.connect()
        self.sock, self.answered = sock, False
        threading.Thread(target=self._read, args=(sock,), daemon=True).start()
        if replay and "initialize" in self.handshake:
            # The new server has not seen this client: initialize it again under an id whose reply is dropped.
            init = dict(self.handshake["initialize"], id=REPLAY_ID)
            sock.sendall(json.dumps(init).encode() + b"\n")
            if "notifications/initialized" in self.handshake:
                sock.sendall(json.dumps(self.handshake["notifications/initialized"]).encode() + b"\n")

    def _read(self, sock):
        buffer = b""
        try:
            while True:
                data = sock.recv(65536)
                if not data:
                    break
                buffer += data
                *lines, buffer = buffer.split(b"\n")
                with self.lock:
                    self.answered = True
                    for line in lines:
                        self._forward(line + b"\n")
        except OSError:
            pass
        with self.lock:
            if self.sock is sock:
                self._drop(sock)

    def _forward(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            msg = None
        if isinstance(msg, dict) and "method" not in msg and "id" in msg:
            if msg["id"] == REPLAY_ID:
                return
            self.pending.pop(msg["id"], None)
        self.write(line)

    def _drop(self, sock):
        # Called with the lock held.
        if self.answered:
            reason = ("the lab VM was reverted or the guest MCP relay restarted, so the server's state (open databases, "
                      "debugger sessions) is gone; retry the call")
        else:
            reason = (f"the guest MCP relay on {self.where} closed the session before the server answered: another "
                      "session holds this port, the previous one is still closing (up to 30 s), or the server failed "
                      r"to start (see C:\lab\mcp\*.log in the guest); retry in 30 s")
        self.sock = None
        try:
            sock.close()
        except OSError:
            pass
        for line in self.pending.values():
            self.write(error_reply(line, reason))
        self.pending.clear()


def main():
    parser = argparse.ArgumentParser()
    for name in ("--task", "--vmx", "--vmrun", "--guest-user", "--local-config"):
        parser.add_argument(name, required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()

    def start_relay(timeout):
        password = read_password(open(args.local_config, encoding="utf-8-sig").read())
        subprocess.run([args.vmrun, "-T", "ws", "-gu", args.guest_user, "-gp", password, "runProgramInGuest", args.vmx,
                        r"C:\Windows\System32\schtasks.exe", "/run", "/tn", args.task],
                       capture_output=True, timeout=timeout, creationflags=0x08000000)

    def connect():
        cid = read_cid(open(args.vmx, encoding="utf-8", errors="replace").read())
        return connect_with_retry(lambda: vsock.connect(cid, args.port), start_relay)

    def write(data):
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()

    bridge = Bridge(connect, write, f"vsock port {args.port}")
    for line in sys.stdin.buffer:
        bridge.send_line(line)


if __name__ == "__main__":
    main()
