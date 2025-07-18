#Requires AutoHotkey v2
#SingleInstance Force
Persistent()

; Auto-elevate if not admin
if !A_IsAdmin {
    Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp
}

; Global variables
global tray := A_TrayMenu


global txt_startup := "Run at startup"
global txt_start_menu := "Start menu entry"

; Script shortcut paths
global startup_shortcut := A_Startup "\" A_ScriptName ".lnk"
global start_menu_shortcut := A_StartMenu "\Programs\" A_ScriptName ".lnk"


toggle_startup_shortcut(*) {
    ; Function: toggleStartupShortcut
    ; Description: Toggles the script's startup shortcut in the Windows Startup folder.

    ; Check if the startup shortcut already exists
    if FileExist(startup_shortcut) {
        ; If it exists, delete the shortcut
        FileDelete(startup_shortcut)

        ; Display a TrayTip indicating the result
        if not FileExist(startup_shortcut) {
            tray.unCheck(txt_startup)
            TrayTip("Startup shortcut removed", "This script won't start automatically", "Iconi")
        } else {
            TrayTip("Startup shortcut removal failed", "Something went wrong", "Iconx")
        }
    } else {
        ; If it doesn't exist, create the shortcut
        FileCreateShortcut(A_ScriptFullPath, startup_shortcut)

        ; Display a TrayTip indicating the result
        if FileExist(startup_shortcut) {
            tray.check(txt_startup)
            TrayTip("Startup shortcut added", "This script will run at startup", "Iconi")
        } else {
            TrayTip("Startup shortcut creation failed", "Something went wrong", "Iconx")
        }
    }

}

toggle_start_menu_shortcut(*) {
    ; Function: toggleStartMenuShortcut
    ; Description: Toggles the script's Start Menu shortcut.

    ; Check if the Start Menu shortcut already exists
    if FileExist(start_menu_shortcut) {
        ; If it exists, delete the shortcut
        FileDelete(start_menu_shortcut)

        ; Display a TrayTip indicating the result
        if !FileExist(start_menu_shortcut) {
            tray.unCheck(txt_start_menu)
            TrayTip("Start menu shortcut removed", "The script won't be shown in the Start Menu", "Iconi")
        } else {
            TrayTip("Start menu shortcut removal failed", "Something went wrong", "Iconx")
        }
    } else {
        ; If it doesn't exist, create the shortcut
        FileCreateShortcut(A_ScriptFullPath, start_menu_shortcut)

        ; Display a TrayTip indicating the result
        if FileExist(start_menu_shortcut) {
            tray.check(txt_start_menu)
            TrayTip("Start Menu shortcut added", "The script will be shown in the Start Menu", "Iconi")
        } else {
            TrayTip("Start menu shortcut creation failed", "Something went wrong", "Iconx")
        }
    }
}


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

        TrayTip("Successfully switched to " item_name, "Network Adapter Switcher", "Iconi")

        ; Optional: Show output only if user wants to see it (comment out for cleaner UX)
        ; MsgBox("Output:`n" output, "Adapter switched successfully!", "Iconi T3")

        ; Refresh menu after 2 seconds to allow network state to settle
        SetTimer(() => Reload(), -2000)

    } catch Error as e {
        TrayTip("Failed to switch adapter: " e.Message, "Network Adapter Switcher", "Icon!")
        MsgBox("Error switching to " item_name ":`n" e.Message, "Error", "Icon!")
    }
}

build_tray_menu() {
    tray.Delete()

    ; Set tooltip
    A_IconTip := A_ScriptName . "`nRight click to switch between network adapters."

    ; Header
    tray.Add("Switch Network Adapter", (*) => {})
    tray.Add()
    ; Add the "Run at startup" menu item to the tray menu
    tray.Add(txt_startup, toggle_startup_shortcut)
    if FileExist(startup_shortcut) {
        tray.check(txt_startup)
    } else {
        tray.unCheck(txt_startup)
    }
    ; Add the "Start menu" menu item to the tray menu
    tray.Add(txt_start_menu, toggle_start_menu_shortcut)
    if FileExist(start_menu_shortcut) {
        tray.check(txt_start_menu)
    } else {
        tray.unCheck(txt_start_menu)
    }

    tray.Add()

    ; Get adapter info
    adapters := get_adapter_info()

    if adapters.Count = 0 {
        tray.Add("No adapters found", (*) => {})
    } else {
        ; Add adapters and set check marks for enabled ones
        for adapter_name, adapter_status in adapters {
            menu_text := adapter_name . " (" . adapter_status . ")"

            ; Add menu item
            tray.Add(menu_text, update_adapters.Bind(adapter_name))

            ; Check the item if adapter is enabled (Up or Disconnected)
            ; "Up" = enabled and connected, "Disconnected" = enabled but no connection
            if adapter_status = "Up" or adapter_status = "Disconnected" {
                tray.Check(menu_text)
            }
        }
    }

    ; Footer
    tray.Add()
    tray.Add("Refresh Adapters", (*) => build_tray_menu())
    tray.Add("Reload App", (*) => Reload())
    tray.Add("Exit", (*) => ExitApp())
    tray.Add()
    tray.Add("Made with ❤️ by Bibek Aryal.", (*) => Run("https://bibeka.com.np/"))
}

; Initialize menu
build_tray_menu()