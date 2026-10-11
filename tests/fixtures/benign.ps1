# Harmless smoke-test sample: one file write, one Run key, one DNS + HTTP request.
Set-Content -Path 'C:\Users\Public\revlab-benign.txt' -Value 'benign marker'
New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'RevlabBenign' -Value 'C:\Windows\System32\notepad.exe' -Force | Out-Null
try { Invoke-WebRequest -Uri 'http://c2.revlab.example/beacon' -UseBasicParsing -TimeoutSec 15 | Out-Null } catch { }
