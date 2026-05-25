# BlockDAG GPU Miner — Windows Installer

---

## Troubleshooting

### GPU not detected / "No OpenCL platforms found"

**What it means:** Windows is missing the registry entry that tells OpenCL where to find the NVIDIA GPU driver. This can happen after a driver update or clean Windows install.

**Fix — PowerShell (recommended):**

Run this in an elevated PowerShell window. It finds the correct DLL path automatically:

```powershell
$dll = Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" -Recurse -Filter "nvopencl64.dll" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if ($dll) {
    New-Item -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Khronos\OpenCL\Vendors" -Name $dll -Value 0 -PropertyType DWORD -Force
    Write-Host "Done: $dll"
} else {
    Write-Host "nvopencl64.dll not found - check your NVIDIA driver installation."
}
```

**Fix — Manual (regedit):**

1. Open **regedit** as Administrator
2. Navigate to `HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors`
   - If the `Khronos\OpenCL\Vendors` path does not exist, create each key manually:
     right-click the parent → **New → Key**
3. Find your NVIDIA OpenCL DLL path — it will be inside:
   `C:\Windows\System32\DriverStore\FileRepository\nv_dispig.inf_amd64_XXXXXXXXXXXXXXXX\`
   (the hex suffix varies per machine — look for the folder containing `nvopencl64.dll`)
4. Inside `Vendors`, right-click → **New → DWORD (32-bit) Value**
5. Set the **name** to the full DLL path (e.g. `C:\Windows\System32\DriverStore\...\nvopencl64.dll`)
6. Set the **value data** to `0`
7. Restart the miner
