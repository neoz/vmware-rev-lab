"""Starts the vmware-mcp stdio server and calls vmrun_list through the MCP protocol."""

import asyncio
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main(command: str, vmrun: str, vmcli: str) -> None:
    env = {**os.environ, "VMRUN_PATH": vmrun, "VMCLI_PATH": vmcli}
    params = StdioServerParameters(command=command, args=[], env=env)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool("vmrun_list", {})
            print("".join(c.text for c in result.content if getattr(c, "text", None)))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3]))
