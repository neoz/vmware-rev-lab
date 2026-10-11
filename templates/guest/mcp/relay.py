"""Serve one stdio MCP server over one vSocket port: one connection at a time, one child per connection."""
import argparse
import logging
import os
import subprocess
import sys
import threading

GRACE_SECONDS = 30


def _socket_to_child(conn, child):
    try:
        while True:
            data = conn.recv(65536)
            if not data:
                break
            child.stdin.write(data)
            child.stdin.flush()
    except (OSError, ValueError):
        pass
    finally:
        try:
            child.stdin.close()
        except OSError:
            pass


def serve_connection(conn, command, env, child_log=None):
    # Under pythonw the relay has no stderr; MCP servers log to stderr and die without a usable one.
    err = open(child_log, "ab") if child_log else subprocess.DEVNULL
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, env=env)
    threading.Thread(target=_socket_to_child, args=(conn, child), daemon=True).start()
    try:
        while True:
            chunk = child.stdout.read1(65536)
            if not chunk:
                break
            conn.sendall(chunk)
    except OSError:
        pass
    finally:
        try:
            conn.shutdown(2)
        except OSError:
            pass
        conn.close()
        # Closing stdin lets the server save its state; kill it if it does not exit in time.
        try:
            child.wait(GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        child.stdout.close()  # the relay runs for days; do not leak a handle per connection
        if child_log:
            err.close()


def run(listener, command, env, child_log=None):
    busy = threading.Lock()
    while True:
        conn = listener.accept()
        if not busy.acquire(blocking=False):
            # One session per port: two clients must not drive one Ghidra project or debugger.
            conn.close()
            continue

        def work(c=conn):
            try:
                serve_connection(c, command, env, child_log)
            except Exception:
                logging.exception("connection failed")
            finally:
                busy.release()

        threading.Thread(target=work, daemon=True).start()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--env", action="append", default=[], help="KEY=VALUE for the child")
    parser.add_argument("--log")
    parser.add_argument("--child-log", help="stderr of the MCP server child")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.log:
        logging.basicConfig(filename=args.log, level=logging.INFO, format="%(asctime)s %(message)s")
    env = dict(os.environ)
    for item in args.env:
        key, _, value = item.partition("=")
        env[key] = value
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import vsock
    try:
        listener = vsock.Listener(args.port)
        logging.info("listening on vsock port %s for %s", args.port, command)
        run(listener, command, env, args.child_log)
    except Exception:
        logging.exception("relay stopped")
        raise


if __name__ == "__main__":
    main()
