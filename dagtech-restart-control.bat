@echo off
:: DagTech GPU Miner - Restart Control Server
:: Stops and restarts the control server (dagtech-control.ps1) without
:: changing whether the miner itself is running.
:: Useful after a software update to pick up the new control server code.
:: Requires Administrator — will self-elevate if needed.

REM ── Self-elevate ─────────────────────────────────────────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo   DagTech GPU Miner - Restart Control Server
echo   -------------------------------------------
echo.

REM ── Stop the scheduled task (kills the SYSTEM-owned control server process) ──
echo   Stopping control server...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Stop-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1

REM ── Brief pause to let the process fully exit and HTTP.sys release the port ──
timeout /t 3 /nobreak >nul

REM ── Restart ──────────────────────────────────────────────────────────────────
echo   Starting control server...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1

timeout /t 4 /nobreak >nul

REM ── Confirm ──────────────────────────────────────────────────────────────────
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$t = Get-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue;" ^
    "if ($t) {" ^
    "    $proc = Get-CimInstance Win32_Process -Filter ""Name='powershell.exe'"" |" ^
    "            Where-Object { $_.CommandLine -like '*dagtech-control*' };" ^
    "    if ($proc) {" ^
    "        Write-Host ('  [OK] Control server running (PID ' + ($proc | Select-Object -First 1 -ExpandProperty ProcessId) + ')') -ForegroundColor Green" ^
    "    } else {" ^
    "        Write-Host '  [--] Task started but control server process not found yet - may still be starting.' -ForegroundColor Yellow" ^
    "    }" ^
    "} else {" ^
    "    Write-Host '  [WARN] Scheduled task not found - is the miner installed?' -ForegroundColor Red" ^
    "}"

echo.
pause
