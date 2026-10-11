import os
import sys
import time

# An MCP server that keeps running after stdin closes; the relay must not wait on it forever.
for line in sys.stdin.buffer:
    sys.stdout.buffer.write(f"{os.getpid()} ".encode() + line)
    sys.stdout.buffer.flush()
time.sleep(600)
