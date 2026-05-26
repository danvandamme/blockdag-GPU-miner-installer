@echo off
:: DagTech GPU Miner - Force Stop
:: Kills all miner and control server processes, including orphaned instances
:: that the normal stop tool misses. Safe to run at any time.
:: Does NOT require the miner to be installed at any specific path.

echo.
echo   DagTech GPU Miner - Force Stop
echo   --------------------------------

REM 1. Prevent the scheduled task from restarting the miner
echo   Stopping scheduled task...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Stop-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1
echo   [OK] Scheduled task stopped (or was not running)

REM 2. Kill the miner executable (all instances)
echo   Killing dagtech-gpu-miner.exe...
taskkill /f /im dagtech-gpu-miner.exe >nul 2>&1 ^
    && echo   [OK] dagtech-gpu-miner.exe killed ^
    || echo   [--] dagtech-gpu-miner.exe was not running

REM 3. Kill all PowerShell processes running dagtech-control (by command line)
REM    This catches orphaned instances not tracked in the PID file.
echo   Killing orphaned dagtech-control.ps1 processes...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$procs = Get-CimInstance Win32_Process -Filter \"Name = 'powershell.exe'\" | Where-Object { $_.CommandLine -like '*dagtech-control*' }; if ($procs) { $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host ('  [OK] Killed PowerShell PID ' + $_.ProcessId) } } else { Write-Host '  [--] No orphaned control server processes found' }"

REM 4. Also kill by saved PID file if the standard install path exists
if exist "C:\dagtech-gpu-miner\logs\control.pid" (
    set /p CTRLPID=<"C:\dagtech-gpu-miner\logs\control.pid"
    taskkill /f /pid %CTRLPID% >nul 2>&1
    del "C:\dagtech-gpu-miner\logs\control.pid" >nul 2>&1
)

REM 5. Write the stop sentinel so the control server stays stopped after restart
if exist "C:\dagtech-gpu-miner\logs" (
    echo. > "C:\dagtech-gpu-miner\logs\.stop"
)

REM 6. Confirm nothing is left running
echo   Verifying...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$m = Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue; $c = Get-CimInstance Win32_Process -Filter \"Name = 'powershell.exe'\" | Where-Object { $_.CommandLine -like '*dagtech-control*' }; if ($m -or $c) { Write-Host '  [WARN] Some processes are still running - try again or reboot' -ForegroundColor Yellow } else { Write-Host '  [OK] All miner processes are stopped' -ForegroundColor Green }"

echo.
pause
