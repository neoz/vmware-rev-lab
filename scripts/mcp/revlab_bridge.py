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


def connect_with_retry(connect, start_relay, attempts=3, delay=10, sleep=time.sleep):
    last = None
    for attempt in range(attempts):
        try:
            return connect()
        except OSError as exc:
            last = exc
            if attempt == 0:
                try:
                    start_relay()
                except Exception:
                    pass
            if attempt < attempts - 1:
                sleep(delay)
    raise last


def error_reply(first_line, message):
    try:
        request_id = json.loads(first_line).get("id")
    except (ValueError, AttributeError):
        request_id = None
    return (json.dumps({"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32000, "message": message}}) + "\n").encode()


def main():
    parser = argparse.ArgumentParser()
    for name in ("--task", "--vmx", "--vmrun", "--guest-user", "--local-config"):
        parser.add_argument(name, required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()

    def start_relay():
        password = read_password(open(args.local_config, encoding="utf-8-sig").read())
        subprocess.run([args.vmrun, "-T", "ws", "-gu", args.guest_user, "-gp", password, "runProgramInGuest", args.vmx,
                        r"C:\Windows\System32\schtasks.exe", "/run", "/tn", args.task],
                       capture_output=True, timeout=120, creationflags=0x08000000)

    try:
        cid = read_cid(open(args.vmx, encoding="utf-8", errors="replace").read())
        sock = connect_with_retry(lambda: vsock.connect(cid, args.port), start_relay)
    except Exception as exc:
        message = (f"revlab bridge cannot reach the guest MCP relay on vsock port {args.port}: {exc}. "
                   "Is the VM running from a snapshot that has VMCI and the relays (setup.ps1 -From McpBridge)?")
        sys.stdout.buffer.write(error_reply(sys.stdin.buffer.readline(), message))
        sys.stdout.buffer.flush()
        sys.exit(1)

    def to_stdout():
        while True:
            data = sock.recv(65536)
            if not data:
                os._exit(0)
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()

    threading.Thread(target=to_stdout, daemon=True).start()
    for line in sys.stdin.buffer:
        sock.sendall(line)
    sock.close()


if __name__ == "__main__":
    main()
