"""MCP client for lab checks: starts a server from .mcp.json and runs a named check."""
import asyncio
import json
import os
import re
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def server_params(mcp_json, name):
    spec = json.load(open(mcp_json, encoding="utf-8"))["mcpServers"][name]
    return StdioServerParameters(command=spec["command"], args=spec.get("args", []), env={**os.environ, **spec.get("env", {})})


def text(result):
    return "".join(c.text for c in result.content if getattr(c, "text", None))


# ida-mcp has no list or rename tools; analysis runs as IDAPython through execute_python.
IDA_LIST = """
import re, ida_auto, ida_funcs, idautils
ida_auto.auto_wait()
print("\\n".join(n for n in map(ida_funcs.get_func_name, idautils.Functions()) if re.search(%s, n)))
"""

IDA_RENAME = """
import ida_auto, ida_funcs, ida_name, idautils
ida_auto.auto_wait()
ea = next(ea for ea in idautils.Functions() if ida_funcs.get_func_name(ea).startswith("sub_"))
if not ida_name.set_name(ea, %s):
    raise RuntimeError("set_name failed")
print(hex(ea))
"""

# mov eax, 7; add eax, 5 under unicorn, then z3 recovers the 7 from the emulated result.
IDA_EMU = """
import unicorn, z3
from unicorn import x86_const
code = bytes.fromhex("b80700000083c005")
mu = unicorn.Uc(unicorn.UC_ARCH_X86, unicorn.UC_MODE_32)
mu.mem_map(0x1000, 0x1000)
mu.mem_write(0x1000, code)
mu.emu_start(0x1000, 0x1000 + len(code))
eax = mu.reg_read(x86_const.UC_X86_REG_EAX)
x = z3.BitVec("x", 32)
s = z3.Solver()
s.add(x + 5 == eax)
assert s.check() == z3.sat
print("eax=%d x=%s" % (eax, s.model()[x]))
"""


async def ida_call(session, tool, arguments):
    result = await session.call_tool(tool, arguments)
    if result.isError:
        raise SystemExit(f"{tool} failed: {text(result)}")
    return text(result)


async def run(mcp_json, name, check, args):
    async with stdio_client(server_params(mcp_json, name)) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            if check == "count":
                print(f"tools={len((await s.list_tools()).tools)}")
            elif check == "ghidra-functions":
                opened = json.loads(text(await s.call_tool("open_database", {"file_path": args[0], "run_auto_analysis": True})))
                db = opened.get("database", "")
                await s.call_tool("wait_for_analysis", {"database": db})
                print(text(await s.call_tool("list_functions", {"database": db, "filter_pattern": args[1], "limit": 20})))
            elif check == "ghidra-rename-save":
                # Renames the first FUN_ function to args[1] and saves, as an analyst would before case-save.
                db = json.loads(text(await s.call_tool("open_database", {"file_path": args[0]})))["database"]
                await s.call_tool("wait_for_analysis", {"database": db})
                first = json.loads(text(await s.call_tool("list_functions", {"database": db, "filter_pattern": "^FUN_", "limit": 1})))
                await s.call_tool("rename_function", {"database": db, "address": first["items"][0]["start"], "new_name": args[1]})
                saved = await s.call_tool("save_database", {"database": db})
                if saved.isError:
                    raise SystemExit(f"save_database failed: {text(saved)}")
                print(text(saved))
            elif check == "ghidra-list":
                db = json.loads(text(await s.call_tool("open_database", {"file_path": args[0]})))["database"]
                await s.call_tool("wait_for_analysis", {"database": db})
                print(text(await s.call_tool("list_functions", {"database": db, "filter_pattern": args[1], "limit": 20})))
            elif check in ("ida-functions", "ida-list"):
                await ida_call(s, "open_database", {"path": args[0]})
                print(await ida_call(s, "execute_python", {"code": IDA_LIST % json.dumps(args[1])}))
            elif check == "ida-rename-save":
                # Renames the first sub_ function to args[1] and saves, as an analyst would before case-save.
                await ida_call(s, "open_database", {"path": args[0]})
                print(await ida_call(s, "execute_python", {"code": IDA_RENAME % json.dumps(args[1])}))
                print(await ida_call(s, "save_database", {}))
            elif check == "ida-emu":
                await ida_call(s, "open_database", {"path": args[0]})
                print(await ida_call(s, "execute_python", {"code": IDA_EMU}))
            elif check == "windbg-lm":
                opened = text(await s.call_tool("open_cdb_remote", {"connection_string": args[0]}))
                # mcp-windbg answers in text: first line "session_id: cdb-xxxxxxxx".
                session = re.search(r"session_id:\s*(\S+)", opened).group(1)
                print(text(await s.call_tool("run_cdb_command", {"session_id": session, "command": "lm"})))
                await s.call_tool("close_cdb_session", {"session_id": session})
            else:
                raise SystemExit(f"unknown check {check}")


if __name__ == "__main__":
    asyncio.run(run(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]))
