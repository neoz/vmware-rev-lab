# IDA Pro integration

`scripts/add-ida.ps1` installs IDA Pro and the official Hex-Rays `ida-mcp`
server into the clean snapshot. Claude then reaches IDA through the
`revlab-ida` MCP server (idalib, headless).

## Requirements

- The lab is set up (`setup.ps1` finished) and the VM runs.
- In `tools/ida/` (ignored by git):
  - exactly one installer, `ida-pro_<version>_x64win.exe` (for example
    `ida-pro_94_x64win.exe`; IDA 9.4 or newer);
  - your license, `idapro.hexlic`;
  - optional `data/`: copied over `C:\Tools\IDA` (for example `cfg/idauser.cfg`).

```text
tools/ida/
├── ida-pro_94_x64win.exe   # exactly one installer, any version 9.4+
├── idapro.hexlic           # license, copied next to ida.exe
└── data/                   # optional, expanded over C:\Tools\IDA
    ├── IDA-MCP.md
    └── cfg/
        └── idauser.cfg
```

## Install

A person runs it, never Claude: the guest gets Internet during the install.

```powershell
pwsh -File scripts/add-ida.ps1
```

It reverts to `clean`, switches the guest to NAT and runs
`templates/guest/ida-install.ps1`, which:

1. installs IDA into `C:\Tools\IDA` (skipped when it is already there);
2. installs `ida-hcli` into `C:\lab\mcp\venv-hcli` and accepts the EULA;
3. asks hcli for the newest `ida-mcp` release compatible with the installed
   IDA and installs that version into `C:\lab\mcp\venv-ida`;
4. adds `unicorn` and `z3-solver` to `venv-ida` and `angr[unicorn]` to
   `C:\lab\venv-emu`;
5. registers the `RevlabMcpIda` relay task.

The script then switches back to the isolated network, waits for the three
relays, retakes the clean snapshot and adds `revlab-ida` to `.mcp.json`.
Reconnect `revlab-ida` in `/mcp`.

## Upgrading IDA

1. Uninstall IDA inside the guest (the installer is skipped while
   `C:\Tools\IDA\ida.exe` exists), or start from a VM without it.
2. Replace the installer in `tools/ida/` with the new one.
3. Run `add-ida.ps1` again. hcli picks the `ida-mcp` release that matches.

## Use

```powershell
pwsh -File scripts/case-open.ps1 -Case <case>
```

Then, through `revlab-ida`: `open_database` on the staged sample under
`C:\lab\in\sample\`, `execute_python` for IDAPython. Call `save_database`
before any revert; `case-save.ps1` packs the `.i64` into
`cases/<case>/static/ghidra.zip`.

## Troubleshooting

- `revlab-ida lists no tools`: read `C:\lab\mcp\relay-5003.log` and
  `C:\lab\mcp\child-5003.log` in the guest.
- `hcli lists no ida-mcp release compatible`: the installed IDA is older than
  any `ida-mcp` release supports.
- The install failed halfway: the guest is still on NAT. Fix it and rerun, or
  run `scripts/net.ps1 -Mode Analysis` to go back without keeping the changes.
