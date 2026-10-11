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
