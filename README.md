# Network Adapter Switcher

nadap-switch, short for Network Adapter Switcher, is a lightweight Windows utility that lets you quickly enable or disable network adapters through a clean, modern GUI — powered entirely by PowerShell.

![nadap-switch](https://img.shields.io/badge/nadap--switch-active-brightgreen)
![GitHub License](https://img.shields.io/github/license/arlbibek/nadap-switch)

**Why?**

I work in IT and often need to switch between Wi-Fi and LAN. This usually means disabling or enabling adapters through Control Panel or running commands manually — which gets tedious fast when you do it multiple times a day.

## Features

- View all network adapters organized by **Physical** and **Virtual** categories
- Enable or disable any adapter with a single checkbox toggle
- **Enable All** button to quickly restore all adapters
- Quick access to **Network Settings** (ncpa.cpl)
- Modern dark-themed interface
- No dependencies — just PowerShell and Windows

## Usage

1. Download or clone this repository
2. Right-click `nadap-switch.ps1` and choose **Run with PowerShell**
3. The app will request administrator privileges (required to manage adapters)
4. Use the checkboxes to enable or disable adapters

### One-liner launch (`irm | iex`)

You can also run nadap-switch using a remote bootstrap script:

```powershell
irm "https://bibeka.com.np/net" | iex
```

To enable this URL:

1. Host the contents of `bootstrap.ps1` at `https://bibeka.com.np/net` as plain text.
2. Keep the app source URL in `bootstrap.ps1` pointing to:
   `https://raw.githubusercontent.com/arlbibek/nadap-switch/refs/heads/master/nadap-switch.ps1`
3. The bootstrap script downloads the latest `nadap-switch.ps1` to `C:\ProgramData\nadap-switch\` and launches it in hidden PowerShell.

> [!NOTE]
> Administrator privileges are required to enable or disable network adapters.

## Demo

![ndap-switch app demo](demo.gif)

---

Made with ❤️ by [Bibek Aryal](https://bibeka.com.np/).
