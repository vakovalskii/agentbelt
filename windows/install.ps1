# One-time setup on Windows: Python deps, autostart at logon, start now.
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
$root = Split-Path -Parent $PSScriptRoot
py -m pip install --user --quiet psutil
$run = Join-Path $PSScriptRoot "run.ps1"
# conhost --headless: on Windows 11 the default console is Windows Terminal, which ignores
# -WindowStyle Hidden and would leave an empty terminal window open for the whole session.
$action = New-ScheduledTaskAction -Execute "conhost.exe" `
    -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$run`"" -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User (whoami)
$principal = New-ScheduledTaskPrincipal -UserId (whoami) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "agentbelt" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName "agentbelt"
Write-Output "agentbelt installed: starts at logon; toolbelt window opens on the right."
