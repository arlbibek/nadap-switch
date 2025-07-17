#Requires AutoHotkey v2
#SingleInstance Force
Persistent()

; Auto-elevate if not admin
if !A_IsAdmin {
    Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp
}

; Global variables
adapters := []
trayMenu := A_TrayMenu
get_adapter_info() {
    ; Use PowerShell to output name and status as Format-List (multi-line)
    ps_command := 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter -Name * -Physical | ForEach-Object { Write-Output \"$($_.Name) : $($_.Status)\" }"'
    adapters := Map()
    output := RunWaitOne(ps_command)
    for line in StrSplit(output, "`n") {
        line := Trim(line, "`n`r")
        if (line = "") or InStr(line, "Name") or InStr(line, "Status") or InStr(line, "---") {
            continue
        }
        lines := StrSplit(line, " : ")
        adapter_name := Trim(lines[1])
        adapter_status := Trim(lines[2])
        adapters[adapter_name] := adapter_status
    }
    return adapters
}


RunWaitOne(command) {
    shell := ComObject("WScript.Shell")
    exec := shell.Exec(command)
    return exec.StdOut.ReadAll()
}


update_adapters(item_name, *) {
    ; Switch selected adapter on and disable others via PowerShell
    TrayTip("Enabling " item_name " and disabling the rest.", "Updating adapter")
    ps_command := 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter -Name * -Physical | ForEach-Object { if ($_.Name -eq \"' item_name '\") { Write-Host \"Enabling $($_.Name)\"; Enable-NetAdapter -Name $_.Name -Confirm:$false } else { Write-Host \"Disabling $($_.Name)\"; Disable-NetAdapter -Name $_.Name -Confirm:$false } }; Write-Host \"Done!\"'
    output := RunWaitOne(ps_command)
    MsgBox("Output:`n" output, "Adapter switched successfully!", "Iconi T3")
    Reload
}


trayMenu.Delete()
A_IconTip := A_ScriptName . "`nRight click to switch between network adapters. "
trayMenu.Add("Switch Network Adapter", (*) => {})
trayMenu.Add()
for adapter_name, adapter_status in get_adapter_info() {
    current_adapter := adapter_name
    trayMenu.Add(adapter_name " (" adapter_status ")", ((name) => (*) => update_adapters(name))(current_adapter))
}
trayMenu.Add()
trayMenu.Add("Reload", (*) => Reload())
trayMenu.Add("Exit", (*) => ExitApp())