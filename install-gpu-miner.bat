@echo off
REM ============================================================================
REM DagTech GPU Miner - Windows Installer
REM Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
REM https://dagtech.network
REM
REM Builds and installs the DagTech GPU Miner on Windows.
REM
REM Bundled files (must be in the same folder as this .bat):
REM   dagtech_miner.c           Source code (CPU+GPU)
REM   dagtech_sha256.h          SHA256 header
REM   dagtech_gpu.cl            OpenCL kernel (required for GPU)
REM   dagtech-gpu-miner.exe     Pre-built binary (used if no compiler is found)
REM   dashboard\index.html      Web dashboard
REM
REM Usage: Double-click this file, or run from a command prompt.
REM ============================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "VERSION=GPU-2026.0522.1"
set "INSTALL_DIR=C:\dagtech-gpu-miner"
set "BIN_DIR=%INSTALL_DIR%\bin"
set "DASHBOARD_DIR=%INSTALL_DIR%\dashboard"
set "LOG_DIR=%INSTALL_DIR%\logs"
set "CONFIG_FILE=%INSTALL_DIR%\config.env"

echo.
echo   =====================================================
echo     DagTech GPU Miner v%VERSION% - Windows Installer
echo     dagtech.network
echo     By Dawie Nel / DagTech Ltd
echo   =====================================================
echo.

REM ============================================================================
REM 0. Administrator elevation
REM ============================================================================
net session >nul 2>&1
if errorlevel 1 (
    echo [GPU Miner] Administrator rights required - click Yes on the UAC prompt.
    echo [GPU Miner] The installer will continue in a new window.
    set "_SELF=%~f0"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -Verb RunAs -ArgumentList ('/d /k ' + [char]34 + $env:_SELF + [char]34)"
    timeout /t 3 /nobreak >nul
    exit /b
)

REM ============================================================================
REM 0b. Windows Defender exclusions (before any file copies)
REM ============================================================================
echo [GPU Miner] Configuring Windows Defender exclusions...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction SilentlyContinue; Add-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue; Add-MpPreference -ExclusionProcess '%BIN_DIR%\dagtech-gpu-miner.exe' -ErrorAction SilentlyContinue" >nul 2>&1
echo [GPU Miner] Defender exclusions set.

REM ============================================================================
REM 0c. Firewall rule for control server (port 8880)
REM ============================================================================
echo [GPU Miner] Configuring firewall rule for control server (port 8880)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Remove-NetFirewallRule -DisplayName 'DagTech GPU Miner Control' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'DagTech GPU Miner Control' -Direction Inbound -Protocol TCP -LocalPort 8880 -Profile Private,Domain -Action Allow | Out-Null" >nul 2>&1
echo [GPU Miner] Firewall rule set.

REM ============================================================================
REM 1. System Checks
REM ============================================================================
echo [GPU Miner] Checking system...
ver | findstr /i "10\. 11\." >nul 2>&1
if errorlevel 1 echo [GPU Miner] WARNING: Recommended Windows 10 or newer.

for /f %%a in ('powershell -nologo -command "(Get-CimInstance Win32_Processor).NumberOfLogicalProcessors" 2^>nul') do set "CPU_CORES=%%a"
for /f "delims=" %%a in ('powershell -nologo -command "(Get-CimInstance Win32_Processor).Name" 2^>nul') do set "CPU_NAME=%%a"
for /f %%a in ('powershell -nologo -command "[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)" 2^>nul') do set "RAM_MB=%%a"

if "%RAM_MB%"==""    set "RAM_MB=0"
if "%CPU_CORES%"=="" set "CPU_CORES=1"

echo.
echo   Hardware:
echo   CPU:   %CPU_NAME%
echo   Cores: %CPU_CORES%
echo   RAM:   %RAM_MB% MB
echo.

if %RAM_MB% LSS 512 (
    echo [GPU Miner] ERROR: Minimum 512MB RAM required.
    pause & exit /b 1
)

REM Disk space check
for /f "tokens=*" %%s in ('powershell -NoProfile -Command "(Get-PSDrive C).Free" 2^>nul') do set "FREE_BYTES=%%s"
for /f "tokens=*" %%g in ('powershell -NoProfile -Command "[math]::Round(%FREE_BYTES% / 1GB, 2)" 2^>nul') do set "FREE_GB=%%g"
for /f "tokens=*" %%c in ('powershell -NoProfile -Command "if (%FREE_BYTES% -lt 500MB) { 'LOW' } else { 'OK' }" 2^>nul') do set "SPACE_CHECK=%%c"
if "!SPACE_CHECK!"=="LOW" (
    echo [GPU Miner] WARNING: Only !FREE_GB! GB free on C:. At least 500 MB recommended.
    echo         Press any key to continue anyway, or close this window to cancel.
    pause >nul
) else (
    echo [GPU Miner] Disk space OK ^(!FREE_GB! GB free^).
)

REM ============================================================================
REM 1b. Detect GPU(s)
REM ============================================================================
echo [GPU Miner] Detecting GPU(s)...
powershell -Command "Get-WmiObject Win32_VideoController | Select-Object Name | Format-List" 2>nul
for /f "tokens=*" %%g in ('powershell -NoProfile -Command "(Get-WmiObject Win32_VideoController).Name -join ',' " 2^>nul') do set "GPU_NAME=%%g"
if "!GPU_NAME!"=="" (
    echo [GPU Miner] WARNING: No GPU detected. GPU mining will fall back to CPU-only at runtime.
) else (
    echo [GPU Miner] GPU detected: !GPU_NAME!
)

REM ============================================================================
REM 2. Find C Compiler
REM ============================================================================
echo [GPU Miner] Checking for C compiler...

for %%d in (
    "%INSTALL_DIR%\mingw64\bin"
    "C:\MinGW\bin"
    "C:\MinGW64\bin"
    "C:\mingw64\bin"
    "C:\mingw32\bin"
    "C:\TDM-GCC-64\bin"
    "C:\tools\mingw64\bin"
    "C:\msys64\mingw64\bin"
    "C:\msys64\mingw32\bin"
) do (
    if exist "%%~d\gcc.exe" set "PATH=%%~d;!PATH!"
)

set "HAS_GCC=0"
where gcc >nul 2>&1 && set "HAS_GCC=1"

set "HAS_BUNDLED=0"
if exist "%~dp0dagtech-gpu-miner.exe" set "HAS_BUNDLED=1"

if "%HAS_GCC%"=="1" (
    echo [GPU Miner] Compiler found - will compile from source.
    goto :compiler_ready
)
if "%HAS_BUNDLED%"=="1" (
    echo [GPU Miner] No compiler found - will use bundled pre-built binary.
    goto :compiler_ready
)

REM No compiler and no bundled binary - try to download MinGW
echo [GPU Miner] No compiler found. Downloading portable MinGW-w64...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

set "MINGW_PS=%TEMP%\dagtech-mingw-dl.ps1"
del "%MINGW_PS%" 2>nul

echo $ErrorActionPreference = 'Stop'                                                                   >> "%MINGW_PS%"
echo $dest = '%INSTALL_DIR%'                                                                           >> "%MINGW_PS%"
echo try {                                                                                             >> "%MINGW_PS%"
echo     Write-Host '[GPU Miner] Fetching MinGW-w64 release info...'                                  >> "%MINGW_PS%"
echo     $r = Invoke-RestMethod 'https://api.github.com/repos/brechtsanders/winlibs_mingw/releases/latest' -UseBasicParsing >> "%MINGW_PS%"
echo     $a = $r.assets ^| Where-Object { $_.name -like '*x86_64-posix-seh*ucrt*.zip' } ^| Select-Object -First 1 >> "%MINGW_PS%"
echo     if (-not $a) { $a = $r.assets ^| Where-Object { $_.name -like '*x86_64-posix-seh*.zip' } ^| Select-Object -First 1 } >> "%MINGW_PS%"
echo     if (-not $a) { throw 'No suitable MinGW-w64 asset found' }                                   >> "%MINGW_PS%"
echo     $mb = [math]::Round^($a.size / 1MB, 1^)                                                      >> "%MINGW_PS%"
echo     Write-Host "[GPU Miner] Downloading $($a.name) ($mb MB)..."                                   >> "%MINGW_PS%"
echo     $zip = "$env:TEMP\dagtech-mingw.zip"                                                         >> "%MINGW_PS%"
echo     Invoke-WebRequest $a.browser_download_url -OutFile $zip -UseBasicParsing                     >> "%MINGW_PS%"
echo     Write-Host '[GPU Miner] Extracting...'                                                      >> "%MINGW_PS%"
echo     $mingwDest = Join-Path $dest 'mingw64'                                                      >> "%MINGW_PS%"
echo     if (Test-Path $mingwDest) { Remove-Item $mingwDest -Recurse -Force }                         >> "%MINGW_PS%"
echo     Expand-Archive $zip -DestinationPath $dest -Force                                            >> "%MINGW_PS%"
echo     Remove-Item $zip -Force -ErrorAction SilentlyContinue                                        >> "%MINGW_PS%"
echo     Write-Host '[GPU Miner] MinGW-w64 installed.'                                               >> "%MINGW_PS%"
echo     exit 0                                                                                       >> "%MINGW_PS%"
echo } catch {                                                                                        >> "%MINGW_PS%"
echo     Write-Host "[GPU Miner] Download failed: $_"                                                  >> "%MINGW_PS%"
echo     exit 1                                                                                       >> "%MINGW_PS%"
echo }                                                                                                >> "%MINGW_PS%"

powershell -nologo -ExecutionPolicy Bypass -File "%MINGW_PS%"
if errorlevel 1 (
    echo.
    echo [GPU Miner] Could not auto-install MinGW-w64.
    echo         To build from source, download from https://winlibs.com/ and add gcc.exe to PATH.
    echo         Or place dagtech-gpu-miner.exe (pre-built) in the same folder as this installer.
    pause & exit /b 1
)

set "FOUND_GCC="
if exist "%INSTALL_DIR%\mingw64\bin\gcc.exe" set "FOUND_GCC=%INSTALL_DIR%\mingw64\bin"
if not defined FOUND_GCC (
    for /f "delims=" %%g in ('where /r "%INSTALL_DIR%" gcc.exe 2^>nul') do (
        if not defined FOUND_GCC for %%f in ("%%g") do set "FOUND_GCC=%%~dpf"
    )
)
if not defined FOUND_GCC (
    echo [GPU Miner] ERROR: gcc.exe not found after extraction. Please try again.
    pause & exit /b 1
)
set "PATH=%FOUND_GCC%;%PATH%"
set "HAS_GCC=1"
echo [GPU Miner] MinGW-w64 ready at %FOUND_GCC%
powershell -nologo -command "[Environment]::SetEnvironmentVariable('PATH','%FOUND_GCC%;'+[Environment]::GetEnvironmentVariable('PATH','User'),'User')" >nul 2>&1

:compiler_ready

REM ============================================================================
REM 2b. Download OpenCL headers if compiler is available and headers missing
REM ============================================================================
set "OPENCL_HEADERS_DIR=%~dp0opencl-headers"
if "%HAS_GCC%"=="1" if not exist "%OPENCL_HEADERS_DIR%\CL\cl.h" (
    echo [GPU Miner] OpenCL headers not found. Downloading from Khronos...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$zip='$env:TEMP\opencl-headers.zip'; $ext='$env:TEMP\ocl-ext'; Invoke-WebRequest 'https://github.com/KhronosGroup/OpenCL-Headers/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing; if (Test-Path $ext) { Remove-Item $ext -Recurse -Force }; Expand-Archive $zip -DestinationPath $ext -Force; $clSrc=Join-Path $ext 'OpenCL-Headers-main\CL'; $dest='%OPENCL_HEADERS_DIR%'; if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }; Copy-Item $clSrc -Destination $dest -Recurse -Force; Remove-Item $zip,$ext -Recurse -Force -ErrorAction SilentlyContinue; Write-Host '[GPU Miner] OpenCL headers installed.'"
    if errorlevel 1 (
        echo [GPU Miner] WARNING: Could not download OpenCL headers. GPU compile may fail.
    ) else (
        echo [GPU Miner] OpenCL headers ready.
    )
)

REM ============================================================================
REM 2c. Generate libOpenCL.a import library from system OpenCL.dll
REM     gendef + dlltool are bundled with MinGW-w64. The Khronos headers repo
REM     only ships .h files — libOpenCL.a must be generated from the system DLL
REM     that GPU drivers install at C:\Windows\System32\OpenCL.dll.
REM ============================================================================
if "%HAS_GCC%"=="1" if not exist "%OPENCL_HEADERS_DIR%\libOpenCL.a" (
    if exist "%SystemRoot%\System32\OpenCL.dll" (
        echo [GPU Miner] Generating libOpenCL.a from system OpenCL.dll...
        set "_GCC_BIN_FOR_OCL="
        for /f "tokens=*" %%g in ('where gcc 2^>nul') do if not defined _GCC_BIN_FOR_OCL set "_GCC_BIN_FOR_OCL=%%~dpg"
        if defined _GCC_BIN_FOR_OCL (
            if exist "!_GCC_BIN_FOR_OCL!gendef.exe" if exist "!_GCC_BIN_FOR_OCL!dlltool.exe" (
                pushd "%OPENCL_HEADERS_DIR%"
                "!_GCC_BIN_FOR_OCL!gendef.exe" "%SystemRoot%\System32\OpenCL.dll" >nul 2>&1
                "!_GCC_BIN_FOR_OCL!dlltool.exe" -d OpenCL.def -l libOpenCL.a >nul 2>&1
                del /f OpenCL.def 2>nul
                popd
                if exist "%OPENCL_HEADERS_DIR%\libOpenCL.a" (
                    echo [GPU Miner] libOpenCL.a generated successfully.
                ) else (
                    echo [GPU Miner] WARNING: libOpenCL.a generation failed. GPU compile may fail.
                )
            ) else (
                echo [GPU Miner] WARNING: gendef/dlltool not found in MinGW bin. GPU compile may fail.
            )
        ) else (
            echo [GPU Miner] WARNING: gcc not found in PATH for libOpenCL.a generation.
        )
    ) else (
        echo [GPU Miner] WARNING: OpenCL.dll not found in System32. Install GPU drivers first.
        echo         GPU compile will likely fail. Install drivers then re-run installer.
    )
)

REM ============================================================================
REM 3. Locate source files
REM ============================================================================
set "SRC_FILE=%~dp0dagtech_miner.c"
set "SHA256_FILE=%~dp0dagtech_sha256.h"
set "CL_FILE=%~dp0dagtech_gpu.cl"

if "%HAS_GCC%"=="1" if not exist "%SRC_FILE%" (
    echo [GPU Miner] ERROR: dagtech_miner.c not found in installer folder.
    echo         Expected: %SRC_FILE%
    pause & exit /b 1
)
if "%HAS_GCC%"=="1" if not exist "%CL_FILE%" (
    echo [GPU Miner] ERROR: dagtech_gpu.cl not found in installer folder.
    echo         Expected: %CL_FILE%
    pause & exit /b 1
)

REM ============================================================================
REM 4. Configuration
REM ============================================================================
echo.
echo   ---- Configuration ----
echo.

set "DEF_POOL=excalibur.dagtech.network"
set "DEF_PORT=3334"
set "DEF_WORKER=dagtech"
set "DEF_THREADS="
set "DEF_GPU_INT=80"
if exist "%CONFIG_FILE%" (
    for /f "tokens=1,* delims==" %%k in (%CONFIG_FILE%) do (
        if "%%k"=="WALLET"       set "DEF_WALLET=%%l"
        if "%%k"=="POOL_HOST"    set "DEF_POOL=%%l"
        if "%%k"=="POOL"         set "DEF_POOL=%%l"
        if "%%k"=="POOL_PORT"    set "DEF_PORT=%%l"
        if "%%k"=="PORT"         set "DEF_PORT=%%l"
        if "%%k"=="WORKER_NAME"  set "DEF_WORKER=%%l"
        if "%%k"=="WORKER"       set "DEF_WORKER=%%l"
        if "%%k"=="THREADS"      set "DEF_THREADS=%%l"
        if "%%k"=="POOL_PASSWORD" set "DEF_PASSWORD=%%l"
        if "%%k"=="GPU_INTENSITY" set "DEF_GPU_INT=%%l"
    )
    echo [GPU Miner] Loaded defaults from existing config.
)

:wallet_prompt
set "WALLET="
if defined DEF_WALLET (
    echo   Wallet (current: %DEF_WALLET%^):
    set /p "WALLET=  New wallet (leave blank to keep current): "
    if "!WALLET!"=="" set "WALLET=%DEF_WALLET%"
) else (
    set /p "WALLET=  Wallet address (0x...): "
)
if "!WALLET!"=="" ( echo   [WARN] Wallet is required. & goto :wallet_prompt )
for /f "tokens=*" %%v in ('powershell -NoProfile -Command "if ('!WALLET!' -match '^0x[0-9a-fA-F]{40}') { 'OK' } else { 'BAD' }" 2^>nul') do set "ADDR_CHECK=%%v"
if not "!ADDR_CHECK!"=="OK" (
    echo   [WARN] That does not look like a valid wallet address.
    echo          Expected format: 0x followed by 40 hex characters.
    goto :wallet_prompt
)

echo.
set /p "POOL_INPUT=  Pool address (default: %DEF_POOL%): "
if "%POOL_INPUT%"=="" (set "POOL=%DEF_POOL%") else (set "POOL=%POOL_INPUT%")

set /p "PORT_INPUT=  Pool port   (default: %DEF_PORT%): "
if "%PORT_INPUT%"=="" (set "PORT=%DEF_PORT%") else (set "PORT=%PORT_INPUT%")

echo.
set /p "WORKER_INPUT=  Worker name (default: %DEF_WORKER%): "
if "%WORKER_INPUT%"=="" (set "WORKER=%DEF_WORKER%") else (set "WORKER=%WORKER_INPUT%")

set /a "DEFAULT_THREADS=%CPU_CORES% / 2"
if %DEFAULT_THREADS% LSS 1 set "DEFAULT_THREADS=1"
if defined DEF_THREADS set "DEFAULT_THREADS=%DEF_THREADS%"
echo.
set /p "THREADS_INPUT=  CPU threads (1-%CPU_CORES%, default %DEFAULT_THREADS%): "
if "%THREADS_INPUT%"=="" (set "THREADS=%DEFAULT_THREADS%") else (set "THREADS=%THREADS_INPUT%")

echo.
set /p "GPU_INT_INPUT=  GPU intensity (0-100, default %DEF_GPU_INT%): "
if "!GPU_INT_INPUT!"=="" (set "GPU_INT=%DEF_GPU_INT%") else (set "GPU_INT=!GPU_INT_INPUT!")

echo.
set "DEF_PASSWORD_SHOW="
if defined DEF_PASSWORD set "DEF_PASSWORD_SHOW=!DEF_PASSWORD!"
set /p "PASSWORD_INPUT=  Pool password (default: blank): "
if "!PASSWORD_INPUT!"=="" (
    if defined DEF_PASSWORD (set "PASSWORD=!DEF_PASSWORD!") else (set "PASSWORD=")
) else (
    set "PASSWORD=!PASSWORD_INPUT!"
)

echo.
echo   Summary:
echo   Wallet      : %WALLET%
echo   Pool        : %POOL%:%PORT%
echo   Worker      : %WORKER%
echo   Password    : %PASSWORD%
echo   CPU Threads : %THREADS%
echo   GPU Intensity: %GPU_INT%
echo.

REM ============================================================================
REM 5. Create directories
REM ============================================================================
echo [GPU Miner] Creating directories...
if not exist "%INSTALL_DIR%"    mkdir "%INSTALL_DIR%"
if not exist "%BIN_DIR%"        mkdir "%BIN_DIR%"
if not exist "%DASHBOARD_DIR%"  mkdir "%DASHBOARD_DIR%"
if not exist "%LOG_DIR%"        mkdir "%LOG_DIR%"

REM ============================================================================
REM 6. Install binary
REM ============================================================================

REM -- Fast path: bundled pre-built binary --
if "%HAS_BUNDLED%"=="1" (
    copy /y "%~dp0dagtech-gpu-miner.exe" "%BIN_DIR%\dagtech-gpu-miner.exe" >nul
    echo [GPU Miner] Pre-built binary installed.
)

REM -- Bundled runtime DLL --
if exist "%~dp0libwinpthread-1.dll" (
    copy /y "%~dp0libwinpthread-1.dll" "%BIN_DIR%\libwinpthread-1.dll" >nul
    echo [GPU Miner] Runtime DLL installed.
)

REM -- Compile from source if compiler available --
if "%HAS_GCC%"=="1" if exist "%SRC_FILE%" (
    echo [GPU Miner] Compiling from source with GPU support...

    if exist "%SHA256_FILE%" (
        for %%f in ("%SRC_FILE%") do set "SRC_DIR=%%~dpf"
        copy /y "%SHA256_FILE%" "!SRC_DIR!" >nul 2>&1
    )

    REM Copy OpenCL kernel to bin dir so it can be found at runtime
    copy /y "%CL_FILE%" "%BIN_DIR%\dagtech_gpu.cl" >nul 2>&1
    echo [GPU Miner] OpenCL kernel installed.

    gcc -DDAGTECH_GPU -I"%OPENCL_HEADERS_DIR%" -L"%OPENCL_HEADERS_DIR%" -O2 -march=native -Wall -D_WIN32_WINNT=0x0600 ^
        -o "%BIN_DIR%\dagtech-gpu-miner.exe" ^
        "%SRC_FILE%" ^
        -lws2_32 -lm -lkernel32 -lOpenCL ^
        -static-libgcc -Wl,-Bstatic,-lpthread,-Bdynamic

    if errorlevel 1 (
        echo [GPU Miner] Compile failed - keeping bundled binary if available.
    ) else (
        echo [GPU Miner] Compiled successfully.
        REM Copy MinGW runtime DLLs
        for /f "tokens=*" %%g in ('where gcc 2^>nul') do if not defined _GCC_DIR set "_GCC_DIR=%%~dpg"
        if defined _GCC_DIR (
            for %%d in (libwinpthread-1.dll libgcc_s_seh-1.dll libgcc_s_dw2-1.dll) do (
                if exist "!_GCC_DIR!%%d" (
                    copy /y "!_GCC_DIR!%%d" "%BIN_DIR%\" >nul
                    echo [GPU Miner] Runtime DLL installed: %%d
                )
            )
        )
    )
) else (
    REM Still copy the kernel file even if not compiling
    if exist "%CL_FILE%" (
        copy /y "%CL_FILE%" "%BIN_DIR%\dagtech_gpu.cl" >nul 2>&1
        echo [GPU Miner] OpenCL kernel installed.
    )
)

if not exist "%BIN_DIR%\dagtech-gpu-miner.exe" (
    echo [GPU Miner] ERROR: No binary available. Cannot continue.
    echo         Place dagtech-gpu-miner.exe in the same folder as this installer and retry.
    pause & exit /b 1
)

REM ============================================================================
REM 7. Save configuration
REM ============================================================================
echo [GPU Miner] Saving config...
(
echo # DagTech GPU Miner Configuration
echo # Generated by DagTech GPU Installer v%VERSION%
echo INSTALLER_VERSION=%VERSION%
echo WALLET=!WALLET!
echo POOL_HOST=!POOL!
echo POOL_PORT=!PORT!
echo MINING_MODE=both
echo THREADS=!THREADS!
echo WORKER_NAME=!WORKER!
echo POOL_PASSWORD=!PASSWORD!
echo CPU_LIMIT=100
echo METRICS_PORT=8880
echo GPU_ENABLED=1
echo GPU_INTENSITY=!GPU_INT!
echo GPU_PLATFORM=0
echo GPU_DEVICE=0
) > "%CONFIG_FILE%"
echo [GPU Miner] Config saved.

REM ============================================================================
REM 8. Install dashboard
REM ============================================================================
if exist "%~dp0dashboard\index.html" (
    copy /y "%~dp0dashboard\index.html" "%DASHBOARD_DIR%\" >nul
    echo [GPU Miner] Dashboard installed.
) else if exist "%~dp0..\dashboard\index.html" (
    copy /y "%~dp0..\dashboard\index.html" "%DASHBOARD_DIR%\" >nul
    echo [GPU Miner] Dashboard installed.
)

REM ============================================================================
REM 8b. Install control server
REM ============================================================================
if exist "%~dp0dagtech-control.ps1" (
    copy /y "%~dp0dagtech-control.ps1" "%BIN_DIR%\" >nul
    echo [GPU Miner] Control server installed.
) else (
    echo [GPU Miner] WARNING: dagtech-control.ps1 not found in installer folder.
)

REM ============================================================================
REM 9. Install launcher scripts
REM ============================================================================
echo [GPU Miner] Installing launcher scripts...
for %%f in (dagtech-start.bat dagtech-stop.bat dagtech-status.bat) do (
    if exist "%~dp0%%f" (
        copy /y "%~dp0%%f" "%BIN_DIR%\%%f" >nul
    )
)
echo [GPU Miner] Launcher scripts installed.

REM ============================================================================
REM 10. Add bin folder to user PATH
REM ============================================================================
echo [GPU Miner] Adding to PATH...
powershell -nologo -command ^
    "$p=[Environment]::GetEnvironmentVariable('PATH','User'); if($p -notlike '*dagtech-gpu-miner\bin*'){[Environment]::SetEnvironmentVariable('PATH','%BIN_DIR%;'+$p,'User')}" >nul 2>&1

REM ============================================================================
REM 11. Desktop shortcuts
REM ============================================================================
echo [GPU Miner] Creating desktop shortcuts...

REM -- Start shortcut --
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$d=[Environment]::GetFolderPath('Desktop'); $lnk=Join-Path $d 'DagTech GPU Miner.lnk'; $s=(New-Object -COM WScript.Shell).CreateShortcut($lnk); $s.TargetPath='%BIN_DIR%\dagtech-start.bat'; $s.WorkingDirectory='%BIN_DIR%'; $s.Description='Start DagTech GPU Miner - dagtech.network'; $s.IconLocation='%BIN_DIR%\dagtech-gpu-miner.exe,0'; $s.Save()"
if not errorlevel 1 echo [GPU Miner] Desktop shortcut created: "DagTech GPU Miner"

REM -- Stop shortcut --
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$d=[Environment]::GetFolderPath('Desktop'); $lnk=Join-Path $d 'DagTech GPU Miner - Stop.lnk'; $s=(New-Object -COM WScript.Shell).CreateShortcut($lnk); $s.TargetPath='%BIN_DIR%\dagtech-stop.bat'; $s.WorkingDirectory='%BIN_DIR%'; $s.Description='Stop DagTech GPU Miner'; $s.Save()"
if not errorlevel 1 echo [GPU Miner] Desktop shortcut created: "DagTech GPU Miner - Stop"

REM ============================================================================
REM 12. Auto-start at Windows login (optional)
REM ============================================================================
echo.
set "AUTOSTART=Y"
set /p "AUTOSTART=  Start DagTech GPU Miner automatically at Windows login? (Y/n): "
if /i not "%AUTOSTART%"=="n" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$lnk=[IO.Path]::Combine($env:APPDATA,'Microsoft\Windows\Start Menu\Programs\Startup\DagTech GPU Miner.lnk'); $s=(New-Object -COM WScript.Shell).CreateShortcut($lnk); $s.TargetPath='%BIN_DIR%\dagtech-start.bat'; $s.WindowStyle=7; $s.WorkingDirectory='%BIN_DIR%'; $s.Description='DagTech GPU Miner auto-start'; $s.Save()"
    if not errorlevel 1 echo [GPU Miner] Auto-start at login enabled.
)

REM ============================================================================
REM Done
REM ============================================================================
echo.
echo   =====================================================
echo     DagTech GPU Miner Installation Complete!
echo   =====================================================
echo.
echo   Desktop shortcuts created:
echo     "DagTech GPU Miner"        - starts mining
echo     "DagTech GPU Miner - Stop" - stops mining
echo.
echo   Dashboard (while mining):
echo     http://127.0.0.1:8880
echo.
echo   Config:  %CONFIG_FILE%
echo   Logs:    %LOG_DIR%
echo.
echo   To update settings: edit %CONFIG_FILE% directly.
echo.
echo   DagTech GPU Mining Suite v%VERSION%
echo   By Dawie Nel / DagTech Ltd  -  dagtech.network
echo.
echo   You can close this window now.
pause >nul
