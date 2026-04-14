$ErrorActionPreference = "Stop"

# Keep compatibility with older Windows PowerShell builds.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # Ignore if unsupported and continue.
}

$appDirectory = Join-Path $env:ProgramData "nadap-switch"
$appScriptPath = Join-Path $appDirectory "nadap-switch.ps1"
$appSource = "https://raw.githubusercontent.com/arlbibek/nadap-switch/refs/heads/master/nadap-switch.ps1"

New-Item -ItemType Directory -Path $appDirectory -Force | Out-Null
Invoke-RestMethod -Uri $appSource -OutFile $appScriptPath

Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$appScriptPath`""
) | Out-Null
