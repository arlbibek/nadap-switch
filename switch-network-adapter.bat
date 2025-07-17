:: -------------------------------------------------------------------------
:: Script Name : Toggle-NetworkAdapter.bat
:: Description : Lists all physical network adapters and allows user to 
::               enable one while disabling the rest.
:: Notes       : Useful for switching between Wi-Fi, Ethernet, etc.
:: -------------------------------------------------------------------------

@echo off
:: Auto-elevate to admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo === Physical Network Adapters ===

powershell -Command " $i=1; Get-NetAdapter -Name * -Physical | Sort-Object ifIndex | ForEach-Object { $status = if ($_.Status -eq 'Up') {'Connected'} elseif ($_.Status -eq 'Disabled') {'Disabled'} else {'Disconnected'}; $speed = if ($_.LinkSpeed) { $_.LinkSpeed } else { 'N/A' }; Write-Host ($i.ToString() + '. ' + $_.Name + '  [' + $status + '] - ' + $speed); $i++ }"

echo.
set /p choice=[ input ] Enter adapter [1-3] to enable: 

powershell -Command " $adapters = Get-NetAdapter -Name * -Physical | Sort-Object ifIndex; $i = 1; foreach ($a in $adapters) { if ($i -eq %choice%) { Write-Host 'Enabling ' $a.Name '...'; Enable-NetAdapter -Name $a.Name -Confirm:$false } else { Write-Host 'Disabling ' $a.Name '...'; Disable-NetAdapter -Name $a.Name -Confirm:$false }; $i++ }"

echo.
echo [ done ] Operation complete.
pause