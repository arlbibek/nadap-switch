#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:singleInstanceMutex = $null

function Acquire-SingleInstanceLock {
    $createdNew = $false
    $mutexName = "Global\nadap-switch-single-instance"
    $script:singleInstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)

    if (-not $createdNew) {
        # Another instance is already running.
        exit
    }
}

function Release-SingleInstanceLock {
    if ($script:singleInstanceMutex) {
        try {
            $script:singleInstanceMutex.ReleaseMutex() | Out-Null
        } catch {
            # Ignore release failures.
        } finally {
            $script:singleInstanceMutex.Dispose()
            $script:singleInstanceMutex = $null
        }
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $argsList = @(
        "-NoProfile"
        "-ExecutionPolicy", "Bypass"
        "-File", "`"$PSCommandPath`""
    )
    Start-Process -FilePath "powershell.exe" -ArgumentList $argsList -Verb RunAs | Out-Null
    exit
}

Acquire-SingleInstanceLock

try {
    $nativeMethods = @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition $nativeMethods -ErrorAction SilentlyContinue
    $consoleHandle = [Win32.NativeMethods]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [Win32.NativeMethods]::ShowWindow($consoleHandle, 0) | Out-Null
    }
} catch {
    # Continue even if console hiding fails.
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:isRefreshing = $false
$script:statusLabel = $null
$script:physicalPanel = $null
$script:virtualPanel = $null
$script:toolTip = $null
$script:notifyIcon = $null
$script:isExiting = $false
$script:hasShownTrayTip = $false
$script:startMinimizedToTray = $true
$script:physicalNamePrefixes = @("ethernet", "eth", "wi-fi", "wifi", "wlan")

function Update-Status {
    param([string]$Message)
    if ($script:statusLabel) {
        $script:statusLabel.Text = $Message
    }
}

function Get-IsVirtualAdapter {
    param($Adapter)

    $name = [string]$Adapter.Name
    $description = [string]$Adapter.InterfaceDescription
    $pnpDeviceId = [string]$Adapter.PnPDeviceID

    $combined = ("{0} {1} {2}" -f $name, $description, $pnpDeviceId).ToLowerInvariant()

    foreach ($prefix in $script:physicalNamePrefixes) {
        if ($name.ToLowerInvariant().StartsWith($prefix)) {
            return $false
        }
    }

    $virtualKeywords = @(
        "virtual", "hyper-v", "vmware", "vmbus", "loopback",
        "tunnel", "tap-", "wintun", "npcap", "docker", "vethernet"
    )

    foreach ($keyword in $virtualKeywords) {
        if ($combined.Contains($keyword)) {
            return $true
        }
    }

    if ($Adapter.PSObject.Properties.Name -contains "Virtual" -and [bool]$Adapter.Virtual) {
        return $true
    }

    # Most software adapters use ROOT\\ or SWD\\ style device IDs.
    if (-not [string]::IsNullOrWhiteSpace($pnpDeviceId) -and $pnpDeviceId -match "^(ROOT|SWD|VMBUS|BTH|TAP|WINTUN)\\") {
        return $true
    }

    # Physical hints: PCI/USB device IDs and explicit hardware interface flag.
    if (-not [string]::IsNullOrWhiteSpace($pnpDeviceId) -and $pnpDeviceId -match "^(PCI|USB)\\") {
        return $false
    }
    if ($Adapter.PSObject.Properties.Name -contains "HardwareInterface" -and [bool]$Adapter.HardwareInterface) {
        return $false
    }

    # Fallback: non-hardware interfaces are usually virtual.
    if ($Adapter.PSObject.Properties.Name -contains "HardwareInterface" -and -not [bool]$Adapter.HardwareInterface) {
        return $true
    }

    return $false
}

function Get-Adapters {
    $adapters = Get-NetAdapter -Name * | Sort-Object -Property Name

    $physical = @()
    $virtual = @()
    $physicalNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    try {
        Get-NetAdapter -Physical -Name * | ForEach-Object {
            [void]$physicalNameSet.Add([string]$_.Name)
        }
    } catch {
        # If -Physical lookup fails, we still classify with heuristics below.
    }

    foreach ($adapter in $adapters) {
        if ($physicalNameSet.Contains([string]$adapter.Name)) {
            $physical += $adapter
        } elseif (Get-IsVirtualAdapter -Adapter $adapter) {
            $virtual += $adapter
        } else {
            $physical += $adapter
        }
    }

    return @{
        Physical = $physical
        Virtual  = $virtual
    }
}

function New-AdapterCheckbox {
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [int]$RowWidth = 420
    )

    $checkbox = New-Object System.Windows.Forms.CheckBox
    $checkbox.AutoSize = $false
    $checkbox.Width = [Math]::Max(260, $RowWidth)
    $checkbox.Height = 22
    $checkbox.Margin = New-Object System.Windows.Forms.Padding(8, 3, 8, 3)
    $checkbox.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $checkbox.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 255)
    $checkbox.BackColor = [System.Drawing.Color]::FromArgb(30, 33, 50)
    $checkbox.Tag = $Adapter.Name

    $status = [string]$Adapter.Status
    $description = [string]$Adapter.InterfaceDescription
    if ([string]::IsNullOrWhiteSpace($description)) {
        $description = "No description"
    }

    $mac = [string]$Adapter.MacAddress
    if ([string]::IsNullOrWhiteSpace($mac)) {
        $mac = "N/A"
    }

    $speed = [string]$Adapter.LinkSpeed
    if ([string]::IsNullOrWhiteSpace($speed)) {
        $speed = "N/A"
    }

    $checkbox.Text = "{0} [{1}]" -f $Adapter.Name, $status
    if ($status -eq "Disabled") {
        $checkbox.ForeColor = [System.Drawing.Color]::FromArgb(170, 178, 205)
    }

    if ($script:toolTip) {
        $tip = "Description: {0}`r`nMAC: {1}`r`nSpeed: {2}" -f $description, $mac, $speed
        $script:toolTip.SetToolTip($checkbox, $tip)
    }

    $checkbox.Checked = ($status -ne "Disabled")

    $checkbox.add_CheckedChanged({
        param($sender, $eventArgs)

        if ($script:isRefreshing) {
            return
        }

        $adapterName = [string]$sender.Tag
        $shouldEnable = [bool]$sender.Checked
        $actionName = if ($shouldEnable) { "Enabling" } else { "Disabling" }

        try {
            Update-Status ("{0} {1}..." -f $actionName, $adapterName)

            if ($shouldEnable) {
                Enable-NetAdapter -Name $adapterName -Confirm:$false | Out-Null
            } else {
                Disable-NetAdapter -Name $adapterName -Confirm:$false | Out-Null
            }

            Start-Sleep -Milliseconds 300
            Refresh-AdapterPanels
            Update-Status ("Done: {0} {1}" -f $actionName.ToLower(), $adapterName)
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                ("Failed to update adapter {0}.`r`n`r`n{1}" -f $adapterName, $_.Exception.Message),
                "Adapter Update Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            Refresh-AdapterPanels
            Update-Status "Error updating adapter. See dialog for details."
        }
    })

    return $checkbox
}

function Add-EmptyLabel {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.FlowLayoutPanel]$Panel,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $true
    $label.Margin = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(170, 180, 205)
    $label.Text = $Text
    $Panel.Controls.Add($label) | Out-Null
}

function Resize-AdapterRows {
    $physicalWidth = [Math]::Max(260, $script:physicalPanel.ClientSize.Width - 28)
    $virtualWidth = [Math]::Max(260, $script:virtualPanel.ClientSize.Width - 28)

    foreach ($control in $script:physicalPanel.Controls) {
        if ($control -is [System.Windows.Forms.CheckBox]) {
            $control.Width = $physicalWidth
        }
    }

    foreach ($control in $script:virtualPanel.Controls) {
        if ($control -is [System.Windows.Forms.CheckBox]) {
            $control.Width = $virtualWidth
        }
    }
}

function Show-MainWindow {
    $form.ShowInTaskbar = $true
    $form.Show()
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    $form.Activate()
}

function Hide-MainWindow {
    $form.ShowInTaskbar = $false
    $form.Hide()
    if ($script:notifyIcon -and -not $script:hasShownTrayTip) {
        $script:notifyIcon.BalloonTipTitle = "nadap-switch"
        $script:notifyIcon.BalloonTipText = "Still running in the system tray."
        $script:notifyIcon.ShowBalloonTip(1800)
        $script:hasShownTrayTip = $true
    }
}

function Enable-AllAdapters {
    try {
        Update-Status "Enabling all adapters..."
        Get-NetAdapter -Name * | Where-Object { $_.Status -eq "Disabled" } | Enable-NetAdapter -Confirm:$false | Out-Null
        Start-Sleep -Milliseconds 300
        Refresh-AdapterPanels
        Update-Status "All disabled adapters have been enabled."
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Failed to enable all adapters.`r`n`r`n{0}" -f $_.Exception.Message),
            "Enable All Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        Update-Status "Error enabling all adapters."
    }
}

function Open-NetworkSettings {
    Start-Process -FilePath "ncpa.cpl" | Out-Null
}

function Exit-Application {
    $script:isExiting = $true
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
    Release-SingleInstanceLock
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
}

function Refresh-AdapterPanels {
    $script:isRefreshing = $true

    try {
        $script:physicalPanel.Controls.Clear()
        $script:virtualPanel.Controls.Clear()

        Update-Status "Loading adapters..."
        $groups = Get-Adapters

        if ($groups.Physical.Count -eq 0) {
            Add-EmptyLabel -Panel $script:physicalPanel -Text "No physical adapters found."
        } else {
            $physicalRowWidth = $script:physicalPanel.ClientSize.Width - 28
            foreach ($adapter in $groups.Physical) {
                $script:physicalPanel.Controls.Add((New-AdapterCheckbox -Adapter $adapter -RowWidth $physicalRowWidth)) | Out-Null
            }
        }

        if ($groups.Virtual.Count -eq 0) {
            Add-EmptyLabel -Panel $script:virtualPanel -Text "No virtual adapters found."
        } else {
            $virtualRowWidth = $script:virtualPanel.ClientSize.Width - 28
            foreach ($adapter in $groups.Virtual) {
                $script:virtualPanel.Controls.Add((New-AdapterCheckbox -Adapter $adapter -RowWidth $virtualRowWidth)) | Out-Null
            }
        }

        $allCount = $groups.Physical.Count + $groups.Virtual.Count
        Update-Status ("Ready - {0} adapters found" -f $allCount)
    } catch {
        Update-Status ("Error loading adapters: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(
            ("Could not load network adapters.`r`n`r`n{0}" -f $_.Exception.Message),
            "Load Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $script:isRefreshing = $false
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "nadap-switch"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(860, 560)
$form.MinimumSize = New-Object System.Drawing.Size(760, 480)
$form.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 42)
$form.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 255)
$form.Padding = New-Object System.Windows.Forms.Padding(10)

$script:toolTip = New-Object System.Windows.Forms.ToolTip
$script:toolTip.AutoPopDelay = 8000
$script:toolTip.InitialDelay = 300
$script:toolTip.ReshowDelay = 200

$iconPath = Join-Path -Path $PSScriptRoot -ChildPath "logo.ico"
if (Test-Path -Path $iconPath) {
    $form.Icon = New-Object System.Drawing.Icon($iconPath)
}

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Top"
$headerPanel.Height = 66
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(32, 35, 52)
$headerPanel.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$form.Controls.Add($headerPanel) | Out-Null

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Network Adapter Switcher"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(240, 244, 255)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(12, 8)
$headerPanel.Controls.Add($titleLabel) | Out-Null

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "PowerShell-only tool to enable or disable network adapters."
$subtitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(166, 173, 200)
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = New-Object System.Drawing.Point(14, 34)
$headerPanel.Controls.Add($subtitleLabel) | Out-Null

$buttonsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonsPanel.FlowDirection = "LeftToRight"
$buttonsPanel.WrapContents = $false
$buttonsPanel.AutoSize = $true
$buttonsPanel.AutoSizeMode = "GrowAndShrink"
$buttonsPanel.Anchor = "Top,Right"
$buttonsPanel.Location = New-Object System.Drawing.Point(460, 16)
$headerPanel.Controls.Add($buttonsPanel) | Out-Null

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Size = New-Object System.Drawing.Size(88, 28)
$btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(54, 57, 79)
$btnRefresh.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 255)
$btnRefresh.FlatStyle = "Flat"
$btnRefresh.FlatAppearance.BorderSize = 0
$buttonsPanel.Controls.Add($btnRefresh) | Out-Null

$btnEnableAll = New-Object System.Windows.Forms.Button
$btnEnableAll.Text = "Enable All"
$btnEnableAll.Size = New-Object System.Drawing.Size(92, 28)
$btnEnableAll.BackColor = [System.Drawing.Color]::FromArgb(54, 57, 79)
$btnEnableAll.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 255)
$btnEnableAll.FlatStyle = "Flat"
$btnEnableAll.FlatAppearance.BorderSize = 0
$buttonsPanel.Controls.Add($btnEnableAll) | Out-Null

$btnNetworkSettings = New-Object System.Windows.Forms.Button
$btnNetworkSettings.Text = "Settings"
$btnNetworkSettings.Size = New-Object System.Drawing.Size(86, 28)
$btnNetworkSettings.BackColor = [System.Drawing.Color]::FromArgb(54, 57, 79)
$btnNetworkSettings.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 255)
$btnNetworkSettings.FlatStyle = "Flat"
$btnNetworkSettings.FlatAppearance.BorderSize = 0
$buttonsPanel.Controls.Add($btnNetworkSettings) | Out-Null

$positionHeaderButtons = {
    $buttonsPanel.Left = $headerPanel.ClientSize.Width - $buttonsPanel.Width - 12
}
$headerPanel.Add_SizeChanged($positionHeaderButtons)
$positionHeaderButtons.Invoke()

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = "Fill"
$layout.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 8)
$layout.ColumnCount = 2
$layout.RowCount = 1
$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$form.Controls.Add($layout) | Out-Null

$grpPhysical = New-Object System.Windows.Forms.GroupBox
$grpPhysical.Text = "Physical Adapters"
$grpPhysical.Dock = "Fill"
$grpPhysical.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$grpPhysical.ForeColor = [System.Drawing.Color]::FromArgb(180, 220, 255)
$grpPhysical.BackColor = [System.Drawing.Color]::FromArgb(30, 33, 50)
$layout.Controls.Add($grpPhysical, 0, 0) | Out-Null

$script:physicalPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$script:physicalPanel.Dock = "Fill"
$script:physicalPanel.FlowDirection = "TopDown"
$script:physicalPanel.WrapContents = $false
$script:physicalPanel.AutoScroll = $true
$script:physicalPanel.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
$script:physicalPanel.BackColor = [System.Drawing.Color]::FromArgb(30, 33, 50)
$grpPhysical.Controls.Add($script:physicalPanel) | Out-Null

$grpVirtual = New-Object System.Windows.Forms.GroupBox
$grpVirtual.Text = "Virtual Adapters"
$grpVirtual.Dock = "Fill"
$grpVirtual.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$grpVirtual.ForeColor = [System.Drawing.Color]::FromArgb(180, 220, 255)
$grpVirtual.BackColor = [System.Drawing.Color]::FromArgb(30, 33, 50)
$layout.Controls.Add($grpVirtual, 1, 0) | Out-Null

$script:virtualPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$script:virtualPanel.Dock = "Fill"
$script:virtualPanel.FlowDirection = "TopDown"
$script:virtualPanel.WrapContents = $false
$script:virtualPanel.AutoScroll = $true
$script:virtualPanel.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
$script:virtualPanel.BackColor = [System.Drawing.Color]::FromArgb(30, 33, 50)
$grpVirtual.Controls.Add($script:virtualPanel) | Out-Null

$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.AutoSize = $false
$script:statusLabel.TextAlign = "MiddleLeft"
$script:statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(166, 173, 200)
$script:statusLabel.BackColor = [System.Drawing.Color]::FromArgb(22, 24, 36)
$script:statusLabel.Dock = "Bottom"
$script:statusLabel.Height = 22
$script:statusLabel.Text = "Ready"
$form.Controls.Add($script:statusLabel) | Out-Null

$footerPanel = New-Object System.Windows.Forms.Panel
$footerPanel.Dock = "Bottom"
$footerPanel.Height = 24
$footerPanel.BackColor = [System.Drawing.Color]::FromArgb(22, 24, 36)
$form.Controls.Add($footerPanel) | Out-Null

$linkGitHub = New-Object System.Windows.Forms.LinkLabel
$linkGitHub.AutoSize = $true
$linkGitHub.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$linkGitHub.LinkColor = [System.Drawing.Color]::FromArgb(137, 180, 250)
$linkGitHub.ActiveLinkColor = [System.Drawing.Color]::FromArgb(180, 210, 255)
$linkGitHub.VisitedLinkColor = [System.Drawing.Color]::FromArgb(137, 180, 250)
$linkGitHub.Location = New-Object System.Drawing.Point(8, 4)
$linkGitHub.Text = "View project on GitHub"
$footerPanel.Controls.Add($linkGitHub) | Out-Null

$creditPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$creditPanel.FlowDirection = "LeftToRight"
$creditPanel.WrapContents = $false
$creditPanel.AutoSize = $true
$creditPanel.AutoSizeMode = "GrowAndShrink"
$creditPanel.BackColor = [System.Drawing.Color]::FromArgb(22, 24, 36)
$footerPanel.Controls.Add($creditPanel) | Out-Null

$footerText = New-Object System.Windows.Forms.Label
$footerText.AutoSize = $true
$footerText.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$footerText.ForeColor = [System.Drawing.Color]::FromArgb(166, 173, 200)
$footerText.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)
$footerText.Text = "Made with v3 by"
$creditPanel.Controls.Add($footerText) | Out-Null

$linkAuthor = New-Object System.Windows.Forms.LinkLabel
$linkAuthor.AutoSize = $true
$linkAuthor.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$linkAuthor.LinkColor = [System.Drawing.Color]::FromArgb(137, 180, 250)
$linkAuthor.ActiveLinkColor = [System.Drawing.Color]::FromArgb(180, 210, 255)
$linkAuthor.VisitedLinkColor = [System.Drawing.Color]::FromArgb(137, 180, 250)
$linkAuthor.Margin = New-Object System.Windows.Forms.Padding(4, 3, 0, 0)
$linkAuthor.Text = "Bibek Aryal"
$creditPanel.Controls.Add($linkAuthor) | Out-Null

$positionFooterCredits = {
    $creditPanel.Left = [Math]::Max(8, $footerPanel.ClientSize.Width - $creditPanel.Width - 8)
    $creditPanel.Top = 2
}
$footerPanel.Add_SizeChanged($positionFooterCredits)
$positionFooterCredits.Invoke()

# Tray icon + menu (portable app behavior)
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = New-Object System.Windows.Forms.ToolStripMenuItem("Open")
$miRefresh = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh")
$miEnableAll = New-Object System.Windows.Forms.ToolStripMenuItem("Enable All")
$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem("Network Settings")
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
$null = $trayMenu.Items.Add($miOpen)
$null = $trayMenu.Items.Add($miRefresh)
$null = $trayMenu.Items.Add($miEnableAll)
$null = $trayMenu.Items.Add($miSettings)
$null = $trayMenu.Items.Add("-")
$null = $trayMenu.Items.Add($miExit)

$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon.Text = "nadap-switch"
$script:notifyIcon.Visible = $true
$script:notifyIcon.ContextMenuStrip = $trayMenu
if (Test-Path -Path $iconPath) {
    $script:notifyIcon.Icon = New-Object System.Drawing.Icon($iconPath)
} else {
    $script:notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$script:notifyIcon.add_DoubleClick({ Show-MainWindow })

$miOpen.add_Click({ Show-MainWindow })
$miRefresh.add_Click({ Refresh-AdapterPanels })
$miEnableAll.add_Click({ Enable-AllAdapters })
$miSettings.add_Click({ Open-NetworkSettings })
$miExit.add_Click({ Exit-Application })

$linkAuthor.add_LinkClicked({
    Start-Process -FilePath "https://bibeka.com.np/" | Out-Null
})

$linkGitHub.add_LinkClicked({
    Start-Process -FilePath "https://github.com/arlbibek/nadap-switch/" | Out-Null
})

$btnRefresh.add_Click({
    Refresh-AdapterPanels
})

$btnEnableAll.add_Click({
    Enable-AllAdapters
})

$btnNetworkSettings.add_Click({
    Open-NetworkSettings
})

$form.add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        Hide-MainWindow
        return
    }
    Resize-AdapterRows
})

$form.add_FormClosing({
    param($sender, $e)
    if (-not $script:isExiting -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Hide-MainWindow
    }
})

$form.add_FormClosed({
    Release-SingleInstanceLock
})

Refresh-AdapterPanels
[void]$form.add_Shown({
    if ($script:startMinimizedToTray) {
        Hide-MainWindow
    }
})
[System.Windows.Forms.Application]::Run($form)
