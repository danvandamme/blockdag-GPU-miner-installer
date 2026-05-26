@echo off
:: DagTech GPU Miner - Force Stop
:: Kills all miner and control server processes, including orphaned instances
:: that the normal stop tool misses. Safe to run at any time.

echo.
echo   DagTech GPU Miner - Force Stop
echo   --------------------------------
echo.

REM ============================================================================
REM STEP 1 — Write the stop sentinel FIRST.
REM          The control server checks this file on startup and after every
REM          miner exit. Writing it first means even if any later step fails
REM          or the scheduled task restarts the control server in between, the
REM          miner will NOT be relaunched.
REM ============================================================================
if exist "C:\dagtech-gpu-miner\logs" (
    echo. > "C:\dagtech-gpu-miner\logs\.stop"
    echo   [OK] Stop sentinel written
) else (
    echo   [--] Install dir not found - sentinel skipped
)

REM ============================================================================
REM STEP 2 — Disable the scheduled task so its restart policy cannot
REM          relaunch the control server while we are killing processes.
REM          We re-enable it at the end so the miner still auto-starts on
REM          the next boot / login.
REM ============================================================================
echo   Stopping scheduled task...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Disable-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue | Out-Null;" ^
    "Stop-ScheduledTask   -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue" >nul 2>&1
echo   [OK] Scheduled task stopped and disabled

REM ============================================================================
REM STEP 3 — Kill the miner binary (all instances).
REM ============================================================================
echo   Killing dagtech-gpu-miner.exe...
taskkill /f /im dagtech-gpu-miner.exe >nul 2>&1 ^
    && echo   [OK] dagtech-gpu-miner.exe killed ^
    || echo   [--] dagtech-gpu-miner.exe was not running

REM ============================================================================
REM STEP 4 — Kill all control server processes (PowerShell 5 and 7).
REM          Matches by command-line so orphaned instances are caught too.
REM ============================================================================
echo   Killing control server processes...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$killed = 0;" ^
    "foreach ($exe in @('powershell.exe','pwsh.exe')) {" ^
    "    Get-CimInstance Win32_Process -Filter \"Name='$exe'\" |" ^
    "    Where-Object { $_.CommandLine -like '*dagtech-control*' } |" ^
    "    ForEach-Object {" ^
    "        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue;" ^
    "        Write-Host ('  [OK] Killed ' + $exe + ' PID ' + $_.ProcessId);" ^
    "        $killed++" ^
    "    }" ^
    "};" ^
    "if ($killed -eq 0) { Write-Host '  [--] No control server processes found' }"

REM ============================================================================
REM STEP 5 — Also kill by PID file in case command-line match missed it.
REM ============================================================================
if exist "C:\dagtech-gpu-miner\logs\control.pid" (
    set /p CTRLPID=<"C:\dagtech-gpu-miner\logs\control.pid"
    taskkill /f /pid %CTRLPID% >nul 2>&1
    del "C:\dagtech-gpu-miner\logs\control.pid" >nul 2>&1
    echo   [OK] Killed PID from pid file
)

REM ============================================================================
REM STEP 6 — Brief pause, then verify. Retry kill once if anything survived.
REM ============================================================================
echo   Verifying...
timeout /t 2 /nobreak >nul

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$m = Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue;" ^
    "$c = @('powershell.exe','pwsh.exe') | ForEach-Object {" ^
    "    Get-CimInstance Win32_Process -Filter \"Name='$_'\" |" ^
    "    Where-Object { $_.CommandLine -like '*dagtech-control*' }" ^
    "};" ^
    "if ($m -or $c) {" ^
    "    Write-Host '  [RETRY] Processes still running - sending second kill...' -ForegroundColor Yellow;" ^
    "    if ($m) { $m | Stop-Process -Force -ErrorAction SilentlyContinue };" ^
    "    if ($c) { $c | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } };" ^
    "    Start-Sleep -Seconds 2;" ^
    "    $m2 = Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue;" ^
    "    $c2 = @('powershell.exe','pwsh.exe') | ForEach-Object {" ^
    "        Get-CimInstance Win32_Process -Filter \"Name='$_'\" |" ^
    "        Where-Object { $_.CommandLine -like '*dagtech-control*' }" ^
    "    };" ^
    "    if ($m2 -or $c2) {" ^
    "        Write-Host '  [WARN] Processes still alive after two kill attempts.' -ForegroundColor Red;" ^
    "        Write-Host '         Try rebooting, or run this file as Administrator.' -ForegroundColor Red" ^
    "    } else {" ^
    "        Write-Host '  [OK] All miner processes stopped (needed second kill)' -ForegroundColor Green" ^
    "    }" ^
    "} else {" ^
    "    Write-Host '  [OK] All miner processes are stopped' -ForegroundColor Green" ^
    "}"

REM ============================================================================
REM STEP 7 — Re-enable the scheduled task so the miner auto-starts on next
REM          boot / login as normal. The .stop sentinel is still in place so
REM          even if the task fires, the control server won't start the miner
REM          until the user explicitly starts it (dagtech-start.bat clears it).
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Enable-ScheduledTask -TaskName 'DagTech GPU Miner' -ErrorAction SilentlyContinue | Out-Null" >nul 2>&1
echo   [OK] Scheduled task re-enabled (miner will stay stopped until you click Start)

echo.
pause
