# BlockDAG GPU Miner — Windows Installer

A Windows installer for the DagTech GPU Miner (Scrypt-DT algorithm).  
Supports NVIDIA, AMD, and Intel GPUs via OpenCL. CPU mining runs in parallel.

---

## Quick Start

1. Right-click `install-gpu-miner.bat` → **Run as administrator**
2. Enter your wallet address, pool, and worker name when prompted
3. Choose a start mode (see below)
4. Open the dashboard at **http://127.0.0.1:8883** while mining

---

## Desktop Shortcuts

| Shortcut | Action |
|---|---|
| `DagTech GPU Miner` | Start mining |
| `DagTech GPU Miner - Stop` | Stop mining |
| `DagTech GPU Miner - Logs` | Open live log terminal |
| `DagTech GPU Miner - Restart Control` | Restart the dashboard server |
| `DagTech GPU Miner - Uninstall` | Remove the miner completely |

---

## Start Modes

**Service** — starts at boot, runs as SYSTEM. No login required. Best for dedicated mining machines.

**Login** — starts when you log in, runs as your user. Shows a live log window on your desktop.

**Manual** — does not auto-start. Use the `DagTech GPU Miner` desktop shortcut when you want to mine.

You can change the start mode at any time by re-running the installer.

---

## Dashboard

While the miner is running, open **http://127.0.0.1:8883** in a browser.

The dashboard shows live hash rates (CPU and GPU separately), share counts, pool connection status, difficulty, and a live activity log. You can also open the log viewer and adjust settings from the Config button.

If the dashboard is blank or stale after an update, use the **Restart Control** shortcut and refresh the page.

---

## Files and Folders

| Path | Contents |
|---|---|
| `C:\dagtech-gpu-miner\config.env` | All miner settings |
| `C:\dagtech-gpu-miner\logs\` | Daily log files (`miner_YYYY-MM-DD.log`) |
| `C:\dagtech-gpu-miner\bin\` | Miner binary and launcher scripts |
| `C:\dagtech-gpu-miner\dashboard\` | Dashboard HTML and assets |

---

## Config Reference

Open `C:\dagtech-gpu-miner\config.env` in Notepad to edit settings. Restart the miner after saving.

| Key | Description |
|---|---|
| `WALLET` | Your BlockDAG wallet address (0x...) |
| `POOL_HOST` | Mining pool hostname |
| `POOL_PORT` | Mining pool port |
| `POOL_PASSWORD` | Pool password (often `x` or a number) |
| `WORKER_NAME` | Worker label shown on the pool |
| `THREADS` | Number of CPU threads to use for mining |
| `GPU_ENABLED` | `1` to enable GPU mining, `0` to disable |
| `GPU_INTENSITY` | GPU workload size 0–100 (higher = more VRAM used) |
| `GPU_THROTTLE` | GPU duty cycle limit 5–100 (`80` = 80% max, reduces heat) |
| `GPU_PLATFORM` | OpenCL platform index — try `1` if GPU shows 0 H/s |
| `GPU_DEVICE` | OpenCL device index within the platform (usually `0`) |
| `GPU_VENDOR` | Detected vendor (`amd`, `nvidia`, `intel`) — informational |
| `WATCHDOG_RESTART_DELAY` | Seconds miner must be continuously down before the first auto-restart attempt (default `60`) |
| `WATCHDOG_RETRY_INTERVAL` | Seconds to wait between subsequent restart attempts if the miner keeps failing (default `300`) |
| `WATCHDOG_MAX_RETRIES` | Max number of auto-restart attempts before giving up; `0` = unlimited (default `0`) |
| `START_MODE` | `service`, `login`, or `manual` |
| `MINING_MODE` | `both` (CPU+GPU), `gpu`, or `cpu` |
| `METRICS_PORT` | Port for the miner metrics API (default `8882`) |

---

## Troubleshooting

### GPU shows 0 H/s

**Most common cause on AMD:** OpenCL enumerates platforms in an order that varies by system. The miner defaults to platform `0`, which may be Intel integrated graphics rather than your Radeon card.

**Fix:**
1. Open `C:\dagtech-gpu-miner\config.env` in Notepad
2. Change `GPU_PLATFORM=0` to `GPU_PLATFORM=1`
3. Save and restart the miner (`DagTech GPU Miner - Stop`, then `DagTech GPU Miner`)
4. If still 0 H/s, try `GPU_PLATFORM=2`

---

### "No OpenCL platforms found" — NVIDIA

The registry entry that points OpenCL to the NVIDIA driver is missing. This can happen after a driver update or clean Windows install.

**Fix — PowerShell (recommended):**

Run in an elevated PowerShell window:

```powershell
$dll = Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" `
    -Recurse -Filter "nvopencl64.dll" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if ($dll) {
    New-Item -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" `
        -Name $dll -Value 0 -PropertyType DWORD -Force
    Write-Host "Done: $dll"
} else {
    Write-Host "nvopencl64.dll not found - reinstall your NVIDIA drivers."
}
```

**Fix — Manual (regedit):**

1. Open **regedit** as Administrator
2. Navigate to `HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors`
   (create the `Khronos\OpenCL\Vendors` keys if they don't exist)
3. Find your NVIDIA OpenCL DLL — look inside:
   `C:\Windows\System32\DriverStore\FileRepository\` for a folder containing `nvopencl64.dll`
4. Right-click `Vendors` → **New → DWORD (32-bit) Value**
5. Set the **name** to the full DLL path
6. Set the **value data** to `0`
7. Restart the miner

---

### "No OpenCL platforms found" — AMD

The AMD OpenCL ICD is not registered. This usually means AMD drivers are not installed or were installed incorrectly.

**Fix — Install/reinstall AMD drivers:**

1. Download AMD Radeon Software from **https://www.amd.com/support**
2. Run the installer and select **Full Install**
3. Reboot, then re-run `install-gpu-miner.bat`

**Fix — Manual registry (if drivers are installed but OpenCL still missing):**

Run in an elevated PowerShell window:

```powershell
$dll = Get-ChildItem "C:\Windows\System32" -Filter "amdocl64.dll" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $dll) {
    $dll = Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" `
        -Recurse -Filter "amdocl64.dll" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if ($dll) {
    New-Item -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" `
        -Name $dll -Value 0 -PropertyType DWORD -Force
    Write-Host "Done: $dll"
} else {
    Write-Host "amdocl64.dll not found - reinstall AMD Radeon Software."
}
```

---

### GPU intensity — out of memory / crashes

If the miner crashes or the GPU shows errors, the intensity may be too high for your VRAM.

**Fix:** Lower `GPU_INTENSITY` in `config.env` in steps of 10 until stable.  
The installer recommends an intensity that uses ~75% of detected VRAM. If VRAM detection was inaccurate, start at `30` and work up.

---

### Miner not starting after reboot (service mode)

1. Open **Task Scheduler** (search in Start Menu)
2. Look for **DagTech GPU Miner** in the task list
3. Check that the task status is **Ready** and the last run result is `0x0`
4. If the task is missing, re-run the installer and choose **Service** mode again

---

### Dashboard not loading

1. Check that the miner is running — use `DagTech GPU Miner - Status` or check Task Manager for `dagtech-gpu-miner.exe` and `powershell.exe`
2. Use the **Restart Control** shortcut and try **http://127.0.0.1:8883** again
3. If still not loading, check `C:\dagtech-gpu-miner\logs\` for errors

---

### Windows Defender blocking the miner

The installer adds Defender exclusions automatically. If Defender removes the binary after install:

1. Open **Windows Security** → **Virus & threat protection** → **Protection history**
2. Find the quarantined item and select **Allow**
3. Re-run the installer to restore the binary

To add exclusions manually in PowerShell (elevated):

```powershell
Add-MpPreference -ExclusionPath "C:\dagtech-gpu-miner"
Add-MpPreference -ExclusionProcess "C:\dagtech-gpu-miner\bin\dagtech-gpu-miner.exe"
```

---

## Uninstall

Double-click the **DagTech GPU Miner - Uninstall** shortcut on your desktop, or run:

```
C:\dagtech-gpu-miner\bin\dagtech-uninstall.bat
```

This stops the miner, removes the scheduled task, deletes all installed files, and removes the desktop shortcuts.

---

## Credits

Original DagTech GPU Mining Suite v1.0.0  
By Dawie Nel / DagTech Ltd — https://dagtech.network  
Modified by Dan Van Damme
