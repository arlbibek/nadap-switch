#Requires AutoHotkey v2
#SingleInstance Force
Persistent()

; Auto-elevate if not admin
if !A_IsAdmin {
    Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp
}

; Global variables
trayMenu := A_TrayMenu

; Improved adapter info retrieval with error handling
get_adapter_info() {
    ps_command := 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-NetAdapter -Name * -Physical | ForEach-Object { Write-Output \"$($_.Name) : $($_.Status)\" }"'
    adapters := Map()

    try {
        output := RunWaitOne(ps_command)
        if !output {
            throw Error("No output from PowerShell command")
        }

        for line in StrSplit(output, "`n") {
            line := Trim(line, "`n`r")
            if (line = "") or InStr(line, "Name") or InStr(line, "Status") or InStr(line, "---") {
                continue
            }

            parts := StrSplit(line, " : ")
            if parts.Length >= 2 {
                adapter_name := Trim(parts[1])
                adapter_status := Trim(parts[2])
                adapters[adapter_name] := adapter_status
            }
        }
    } catch Error as e {
        TrayTip("Error getting adapter info: " e.Message, "Network Adapter Switcher", "Icon!")
        return Map()
    }

    return adapters
}

; Improved command execution with timeout
RunWaitOne(command, timeout := 10000) {
    try {
        shell := ComObject("WScript.Shell")
        exec := shell.Exec(command)

        ; Wait for completion with timeout
        start_time := A_TickCount
        while exec.Status = 0 {
            if (A_TickCount - start_time) > timeout {
                throw Error("Command timed out")
            }
            Sleep(50)
        }

        return exec.StdOut.ReadAll()
    } catch Error as e {
        throw Error("Command execution failed: " e.Message)
    }
}

; Improved adapter switching with better error handling
update_adapters(item_name, *) {
    TrayTip("Switching to " item_name "...", "Network Adapter Switcher")

    ps_command := 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "try { Get-NetAdapter -Name * -Physical | ForEach-Object { if ($_.Name -eq \"' item_name '\") { Write-Host \"Enabling $($_.Name)\"; Enable-NetAdapter -Name $_.Name -Confirm:$false } else { Write-Host \"Disabling $($_.Name)\"; Disable-NetAdapter -Name $_.Name -Confirm:$false } }; Write-Host \"Done!\" } catch { Write-Host \"Error: $($_.Exception.Message)\" }"'

    try {
        output := RunWaitOne(ps_command, 15000)  ; 15 second timeout for network operations

        if InStr(output, "Error:") {
            throw Error("PowerShell error: " output)
        }

        TrayTip("Successfully switched to " item_name, "Network Adapter Switcher", "Icon!")

        ; Optional: Show output only if user wants to see it (comment out for cleaner UX)
        ; MsgBox("Output:`n" output, "Adapter switched successfully!", "Iconi T3")

        ; Refresh menu after 2 seconds to allow network state to settle
        SetTimer(() => Reload(), -2000)

    } catch Error as e {
        TrayTip("Failed to switch adapter: " e.Message, "Network Adapter Switcher", "Icon!")
        MsgBox("Error switching to " item_name ":`n" e.Message, "Error", "Icon!")
    }
}

; Improved menu building with proper checkmarks
build_menu() {
    trayMenu.Delete()

    ; Set tooltip
    A_IconTip := A_ScriptName . "`nRight click to switch between network adapters."

    ; Header
    trayMenu.Add("Switch Network Adapter", (*) => {})
    trayMenu.Add()

    ; Get adapter info
    adapters := get_adapter_info()

    if adapters.Count = 0 {
        trayMenu.Add("No adapters found", (*) => {})
    } else {
        ; Add adapters and set checkmarks for enabled ones
        for adapter_name, adapter_status in adapters {
            menu_text := adapter_name . " (" . adapter_status . ")"

            ; Add menu item
            trayMenu.Add(menu_text, update_adapters.Bind(adapter_name))

            ; Check the item if adapter is enabled (Up or Disconnected)
            ; "Up" = enabled and connected, "Disconnected" = enabled but no connection
            if adapter_status = "Up" or adapter_status = "Disconnected" {
                trayMenu.Check(menu_text)
            }
        }
    }

    ; Footer
    trayMenu.Add()
    trayMenu.Add("Refresh", (*) => build_menu())
    trayMenu.Add("Exit", (*) => ExitApp())
}

; Initialize menu
build_menu()