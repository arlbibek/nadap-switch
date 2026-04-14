$ErrorActionPreference = "Stop"

# Keep compatibility with older Windows PowerShell builds.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # Ignore if unsupported and continue.
}

$appDirectory = Join-Path $env:ProgramData "nadap-switch"
$appScriptPath = Join-Path $appDirectory "nadap-switch.ps1"
$tempScriptPath = Join-Path $appDirectory "nadap-switch.latest.ps1"
$appSource = "https://raw.githubusercontent.com/arlbibek/nadap-switch/refs/heads/master/nadap-switch.ps1"
$cacheBustedSource = "{0}?t={1}" -f $appSource, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

New-Item -ItemType Directory -Path $appDirectory -Force | Out-Null

# Always fetch the latest script from GitHub and replace local copy atomically.
Invoke-RestMethod -Uri $cacheBustedSource -OutFile $tempScriptPath
Move-Item -Path $tempScriptPath -Destination $appScriptPath -Force

Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$appScriptPath`""
) | Out-Null
