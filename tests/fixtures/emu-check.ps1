# Smoke check for C:\lab\venv-emu: angr loads notepad.exe and unicorn and z3 import.
$tools = Get-Content 'C:\lab\tools.json' -Raw | ConvertFrom-Json
# A .py file avoids Windows PowerShell's quoting of native arguments.
$file = 'C:\lab\tmp\emu-check.py'
Set-Content -Path $file -Encoding ASCII -Value @'
import angr, unicorn, z3
p = angr.Project(r"C:\Windows\System32\notepad.exe", auto_load_libs=False)
print("entry=%#x unicorn=%s z3=%s" % (p.entry, unicorn.__version__, z3.get_version_string()))
'@
& $tools.PythonEmu $file
exit $LASTEXITCODE
