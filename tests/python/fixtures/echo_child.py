import os
import sys

# Like FastMCP servers, write a banner to stderr first; the relay must give the child a usable stderr.
sys.stderr.write("child banner on stderr\n")
sys.stderr.flush()
# Binary I/O so Windows does not turn "\n" into "\r\n"; the relay forwards bytes unchanged.
for line in sys.stdin.buffer:
    if line.strip() == b"exit":
        sys.exit(0)
    sys.stdout.buffer.write(f"{os.getpid()} ".encode() + line)
    sys.stdout.buffer.flush()
