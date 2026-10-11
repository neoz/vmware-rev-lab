"""Fix re-mcp-ghidra 3.0.3 saving: edits re_mcp_ghidra/session.py in the venv that runs the workers.

GhidraProject keeps a transaction open on every program it opens or imports. Session.save() calls
df.save() for a program that already has a file, which fails with "Unable to lock due to active
transaction", so renames, comments and types never reach disk. GhidraProject.save() ends that
transaction, saves and restarts it. Patching the file (not monkeypatching) also covers the worker
processes re-mcp starts per database. Upstream: https://github.com/jtsylve/re-mcp/issues/55
"""
import sys
from pathlib import Path

BROKEN = "            df.save(TaskMonitor.DUMMY)\n"
FIXED = "            self._project.save(self._program)  # revlab: GhidraProject owns the open transaction\n"


def patch(path):
    path = Path(path)
    text = path.read_text(encoding="utf-8")
    if FIXED in text:
        return False
    if text.count(BROKEN) != 1:
        raise RuntimeError(f"{path}: Session.save() is not the re-mcp-ghidra 3.0.3 code this patch expects; "
                           "check whether the new version still needs it")
    path.write_text(text.replace(BROKEN, FIXED), encoding="utf-8")
    return True


if __name__ == "__main__":
    import importlib.util
    # Locate without importing: the package may pull in pyghidra/JVM setup.
    target = Path(importlib.util.find_spec("re_mcp_ghidra").submodule_search_locations[0]) / "session.py"
    print(("patched " if patch(target) else "already patched ") + str(target))
    sys.exit(0)
