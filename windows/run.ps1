# agentbelt on Windows: keep the server running (it exits on purpose after settings that need a
# restart, like launchd restarts it on macOS) and open the toolbelt window next to WezTerm.
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $env:LOCALAPPDATA "agentbelt"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "agentbelt.log"
$py = (Get-Command pyw.exe, pythonw.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $py) { $py = (Get-Command py.exe).Source }

$opened = $false
while ($true) {
    Add-Content $log ("{0} start {1}" -f (Get-Date -Format s), $py)
    $p = Start-Process -FilePath $py -ArgumentList @("-u", (Join-Path $root "agentbelt.py")) `
        -WorkingDirectory $root -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err" `
        -WindowStyle Hidden -PassThru
    if (-not $opened) {
        Start-Sleep -Seconds 2
        & (Join-Path $PSScriptRoot "open-belt.ps1")
        $opened = $true
    }
    $p.WaitForExit()
    Get-Content "$log.out", "$log.err" -ErrorAction SilentlyContinue | Add-Content $log
    Start-Sleep -Seconds 2
}
