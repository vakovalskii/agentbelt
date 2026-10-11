# The toolbelt window: an Edge app window (no tabs, no address bar) on the right edge of the
# primary screen, with its own profile so it keeps size and position between runs.
$port = 47811
$cfg = Join-Path $env:USERPROFILE ".config\agentbelt\config.json"
if (Test-Path $cfg) { try { $port = (Get-Content $cfg -Raw | ConvertFrom-Json).port } catch {} }
Add-Type -AssemblyName System.Windows.Forms
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$w = 460
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$profile = Join-Path $env:LOCALAPPDATA "agentbelt\edge-profile"
# already open (the keeper restarted the server): leave the window and its dock alone
if (Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*--app=*$profile*" }) { return }
Start-Process -FilePath $edge -ArgumentList @(
    "--app=http://127.0.0.1:$port/belt", "--user-data-dir=$profile",
    "--window-size=$w,$($wa.Height)", "--window-position=$($wa.Right - $w),$($wa.Top)",
    "--no-first-run", "--disable-features=Translate")

