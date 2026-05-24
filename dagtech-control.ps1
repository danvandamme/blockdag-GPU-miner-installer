# DagTech GPU Miner Control Server
# Serves the dashboard and manages the GPU miner process lifecycle.
# Runs on port 8883 so the dashboard stays accessible when the miner is down.
param([string]$BaseDir = (Split-Path (Split-Path $MyInvocation.MyCommand.Path) -Parent))

$script:BASE      = $BaseDir
$script:BIN       = Join-Path $BaseDir "bin\dagtech-gpu-miner.exe"
$script:CONFIG    = Join-Path $BaseDir "config.env"
$script:LOGDIR    = Join-Path $BaseDir "logs"
$script:DASHBOARD = Join-Path $BaseDir "dashboard\index.html"
$script:STOPFILE   = Join-Path $BaseDir "logs\.stop"
$script:MINERPIDF  = Join-Path $BaseDir "logs\miner.pid"
$PIDFILE           = Join-Path $BaseDir "logs\control.pid"
$script:TASK_NAME  = "DagTech GPU Miner"

if (-not (Test-Path $script:LOGDIR)) { New-Item -ItemType Directory -Path $script:LOGDIR | Out-Null }
[System.IO.File]::WriteAllText($PIDFILE, "$PID")

$script:StartMode = "service"
if (Test-Path $script:CONFIG) {
    Get-Content $script:CONFIG | ForEach-Object {
        if ($_ -match '^START_MODE=(.+)$') { $script:StartMode = $Matches[1].Trim() }
    }
}

try { $host.UI.RawUI.WindowTitle = "DagTech GPU Miner Control Server" } catch {}

function Write-Log([string]$msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Write-Host $line
    try {
        $logPath = Join-Path $script:LOGDIR "miner_$(Get-Date -Format 'yyyy-MM-dd').log"
        $fs = New-Object System.IO.FileStream($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
        $sw.WriteLine($line)
        $sw.Close()
        $fs.Close()
    } catch {}
}

function Read-Config {
    $cfg = @{}
    Get-Content $script:CONFIG | ForEach-Object {
        if ($_ -match '^([A-Z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
    }
    return $cfg
}

function Get-MinerProcess {
    # Try saved PID first — reliable even if the name lookup fails
    if (Test-Path $script:MINERPIDF) {
        try {
            $savedPid = [int]((Get-Content $script:MINERPIDF -Raw -ErrorAction Stop).Trim())
            $p = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($p -and $p.Name -match 'dagtech') { return $p }
        } catch {}
    }
    # Fall back to name search
    return Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Build-MinerArgList([hashtable]$cfg) {
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.AddRange([string[]]@(
        "--wallet",       $(if ($cfg["WALLET"])      { $cfg["WALLET"] }      else { "" }),
        "--pool",         $(if ($cfg["POOL_HOST"])   { $cfg["POOL_HOST"] }   else { "" }),
        "--port",         $(if ($cfg["POOL_PORT"])   { $cfg["POOL_PORT"] }   else { "3334" }),
        "--threads",      $(if ($cfg["THREADS"])     { $cfg["THREADS"] }     else { "1" }),
        "--worker",       $(if ($cfg["WORKER_NAME"]) { $cfg["WORKER_NAME"] } else { "dagtech" }),
        "--cpu-limit",    $(if ($cfg["CPU_LIMIT"])   { $cfg["CPU_LIMIT"] }   else { "100" }),
        "--metrics-port", $(if ($cfg["METRICS_PORT"]){ $cfg["METRICS_PORT"]} else { "8882" }),
        "--dashboard-dir",(Join-Path $script:BASE "dashboard")
    ))
    if ($cfg["POOL_PASSWORD"]) { $argList.Add("--password"); $argList.Add($cfg["POOL_PASSWORD"]) }

    # GPU flags
    $gpuEnabled = $cfg["GPU_ENABLED"]
    if ($gpuEnabled -eq "1") {
        $argList.Add("--gpu")
        if ($cfg["GPU_INTENSITY"]) { $argList.Add("--gpu-intensity"); $argList.Add($cfg["GPU_INTENSITY"]) }
        if ($cfg["GPU_PLATFORM"])  { $argList.Add("--gpu-platform");  $argList.Add($cfg["GPU_PLATFORM"]) }
        if ($cfg["GPU_DEVICE"])    { $argList.Add("--gpu-device");    $argList.Add($cfg["GPU_DEVICE"]) }
    } elseif ($gpuEnabled -eq "0") {
        $argList.Add("--no-gpu")
    }
    Write-Output -NoEnumerate $argList
}

function Start-MinerProcess {
    if (Get-MinerProcess) { return }
    $cfg = Read-Config
    $logFile = Join-Path $script:LOGDIR "miner_$(Get-Date -Format 'yyyy-MM-dd').log"
    $argList = Build-MinerArgList $cfg
    Write-Log "Starting GPU miner..."
    $proc = Start-Process -FilePath $script:BIN -ArgumentList $argList.ToArray() `
        -RedirectStandardOutput $logFile -RedirectStandardError $logFile.Replace('.log','.err.log') `
        -NoNewWindow -PassThru
    if ($proc) {
        try { "$($proc.Id)" | Out-File $script:MINERPIDF -Encoding ASCII -Force } catch {}
        Write-Log "GPU miner started (PID $($proc.Id))"
    }
}

function Stop-MinerProcess {
    "" | Out-File $script:STOPFILE -Force -Encoding ASCII
    # Kill by tracked PID first (most reliable)
    $killedPid = $null
    if (Test-Path $script:MINERPIDF) {
        try {
            $savedPid = [int]((Get-Content $script:MINERPIDF -Raw -ErrorAction Stop).Trim())
            $p = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($p) { $p | Stop-Process -Force -ErrorAction SilentlyContinue; $killedPid = $savedPid }
        } catch {}
        Remove-Item $script:MINERPIDF -Force -ErrorAction SilentlyContinue
    }
    # Also sweep by name to catch any instance not tracked by PID
    Get-Process -Name 'dagtech-gpu-miner' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Log "Miner stopped (pid=$killedPid)."
}

function Send-Response {
    param($ctx, [string]$body, [int]$status = 200, [string]$contentType = "application/json")
    try {
        $res = $ctx.Response
        $res.StatusCode = $status
        $res.ContentType = $contentType
        $res.Headers["Access-Control-Allow-Origin"]  = "*"
        $res.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        $res.Headers["Access-Control-Allow-Headers"] = "Content-Type"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Flush()
        $res.Close()
    } catch { }
}

# Watchdog — checked inline on the main thread after each request (no threading issues)
$script:LastWatchdog = [datetime]::UtcNow

# Start listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:8883/")
try {
    $listener.Start()
} catch {
    Write-Host "ERROR: Could not bind port 8883 - is another instance already running?"
    exit 1
}

Write-Log "Control server listening on http://127.0.0.1:8883/"

# Clear any leftover stop file and start the miner
if (Test-Path $script:STOPFILE) { Remove-Item $script:STOPFILE -Force }
Start-MinerProcess

# Synchronous request loop
while ($listener.IsListening) {
    try {
        $ctx    = $listener.GetContext()
        $method = $ctx.Request.HttpMethod
        $path   = $ctx.Request.Url.AbsolutePath

        if ($method -eq "OPTIONS") { Send-Response $ctx "" 204; continue }

        switch -exact ($path) {
            "/" {
                $html = [System.IO.File]::ReadAllText($script:DASHBOARD, [System.Text.Encoding]::UTF8)
                Send-Response $ctx $html 200 "text/html; charset=utf-8"
                break
            }
            "/status" {
                $running = ($null -ne (Get-MinerProcess)).ToString().ToLower()
                $stopped = (Test-Path $script:STOPFILE).ToString().ToLower()
                Send-Response $ctx ('{"running":' + $running + ',"stopped":' + $stopped + ',"start_mode":"' + $script:StartMode + '"}')
                break
            }
            "/start" {
                if (Test-Path $script:STOPFILE) { Remove-Item $script:STOPFILE -Force }
                Start-MinerProcess
                Write-Log "Start command received via dashboard."
                Send-Response $ctx '{"ok":true}'
                break
            }
            "/stop" {
                Stop-MinerProcess
                Write-Log "Stop command received via dashboard."
                Send-Response $ctx '{"ok":true}'
                break
            }
            "/restart" {
                Write-Log "Restart command received via dashboard."
                $proc = Get-MinerProcess
                if ($proc) { $proc | Stop-Process -Force }
                if (Test-Path $script:STOPFILE) { Remove-Item $script:STOPFILE -Force }
                Start-Sleep -Milliseconds 1500
                Start-MinerProcess
                Send-Response $ctx '{"ok":true}'
                break
            }
            "/config" {
                if ($method -eq "POST") {
                    $rawBody = ""
                    try {
                        $ms = New-Object System.IO.MemoryStream
                        $ctx.Request.InputStream.CopyTo($ms)
                        $rawBody = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).Trim()
                    } catch {}

                    if ($rawBody) {
                        try {
                            $newCfg    = ConvertFrom-Json -InputObject $rawBody
                            $propNames = $newCfg.PSObject.Properties.Name
                            $lines     = @(Get-Content $script:CONFIG)
                            $updatedKeys = @()
                            $newLines  = @(foreach ($line in $lines) {
                                if ($line -match '^([A-Z_]+)=(.*)$') {
                                    $k = $Matches[1]
                                    if ($propNames -contains $k) {
                                        $updatedKeys += $k
                                        "$k=$($newCfg.$k)"
                                    } else { $line }
                                } else { $line }
                            })
                            # Append any keys from the dashboard that weren't already in the file
                            foreach ($k in $propNames) {
                                if ($updatedKeys -notcontains $k) {
                                    $newLines += "$k=$($newCfg.$k)"
                                }
                            }
                            [System.IO.File]::WriteAllLines($script:CONFIG, $newLines, (New-Object System.Text.UTF8Encoding $false))
                            Write-Log "Config updated via dashboard."

                            $wasRunning = $null -ne (Get-MinerProcess)
                            if ($wasRunning) {
                                $proc = Get-MinerProcess
                                if ($proc) { $proc | Stop-Process -Force }
                                Start-Sleep -Milliseconds 1200
                                if (Test-Path $script:STOPFILE) { Remove-Item $script:STOPFILE -Force }
                                Start-MinerProcess
                                Write-Log "Miner restarted after config change."
                                Send-Response $ctx '{"ok":true,"restarted":true}'
                            } else {
                                Send-Response $ctx '{"ok":true,"restarted":false}'
                            }
                        } catch {
                            $msg = $_.Exception.Message -replace '"',"'" -replace '\r?\n',' '
                            Write-Log "Config POST error: $msg | body: $rawBody"
                            Send-Response $ctx ('{"error":"' + $msg + '"}') 400
                        }
                    } else {
                        Send-Response $ctx '{"error":"empty body"}' 400
                    }
                } else {
                    $cfg = Read-Config
                    $kvs = @()
                    foreach ($k in $cfg.Keys) {
                        $kvs += ('"' + $k + '":"' + ($cfg[$k].Replace('\','\\').Replace('"','\"')) + '"')
                    }
                    Send-Response $ctx ('{' + ($kvs -join ',') + '}')
                }
                break
            }
            "/gpu-stats" {
                $cfg = Read-Config
                $gpuEnabled  = if ($cfg["GPU_ENABLED"])   { $cfg["GPU_ENABLED"] -eq "1" } else { $false }
                $gpuIntensity= if ($cfg["GPU_INTENSITY"]) { [int]$cfg["GPU_INTENSITY"] }  else { 80 }
                $gpuPlatform = if ($cfg["GPU_PLATFORM"])  { [int]$cfg["GPU_PLATFORM"] }   else { 0 }
                $gpuDevice   = if ($cfg["GPU_DEVICE"])    { [int]$cfg["GPU_DEVICE"] }     else { 0 }
                $enabledStr  = if ($gpuEnabled) { "true" } else { "false" }
                Send-Response $ctx ('{"gpu_enabled":' + $enabledStr + ',"gpu_intensity":' + $gpuIntensity + ',"gpu_platform":' + $gpuPlatform + ',"gpu_device":' + $gpuDevice + '}')
                break
            }
            "/open-logs" {
                if ($script:StartMode -ne "login") {
                    Send-Response $ctx '{"ok":false,"terminal":false}'
                    break
                }
                $logFile = Join-Path $script:LOGDIR "miner_$(Get-Date -Format 'yyyy-MM-dd').log"
                $cmd = @"
`$Host.UI.RawUI.WindowTitle = 'DagTech GPU Miner - Live Log'
`$Host.UI.RawUI.BackgroundColor = 'Black'
Clear-Host
Write-Host '  DagTech GPU Miner - Live Log' -ForegroundColor Cyan
Write-Host '  ─────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''
`$log = '$($logFile -replace "'","''")'
while (-not (Test-Path `$log)) { Write-Host 'Waiting for log file...' -ForegroundColor DarkGray; Start-Sleep 2 }
Get-Content -Wait -Tail 50 `$log | ForEach-Object {
    if (`$_ -match 'SHARE FOUND') {
        Write-Host `$_ -ForegroundColor Green
    } elseif (`$_ -match 'ERROR|error|failed|FAILED') {
        Write-Host `$_ -ForegroundColor Red
    } elseif (`$_ -match 'WARN|warn') {
        Write-Host `$_ -ForegroundColor Yellow
    } else {
        Write-Host `$_ -ForegroundColor Gray
    }
}
"@
                Start-Process powershell -ArgumentList "-NoProfile", "-NoExit", "-Command", $cmd
                Send-Response $ctx '{"ok":true,"terminal":true}'
                break
            }
            "/switch-mode" {
                if ($method -ne "POST") { Send-Response $ctx '{"error":"POST required"}' 405; break }
                $rawBody = ""
                try {
                    $ms = New-Object System.IO.MemoryStream
                    $ctx.Request.InputStream.CopyTo($ms)
                    $rawBody = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).Trim()
                } catch {}
                $newMode = $null
                try {
                    $body = ConvertFrom-Json -InputObject $rawBody
                    if ($body.mode -eq "login" -or $body.mode -eq "service") { $newMode = $body.mode }
                } catch {}
                if (-not $newMode) { Send-Response $ctx '{"error":"invalid mode"}' 400; break }

                # Update START_MODE in config file
                try {
                    $lines = @(Get-Content $script:CONFIG)
                    $found = $false
                    $newLines = @(foreach ($line in $lines) {
                        if ($line -match '^START_MODE=') { "START_MODE=$newMode"; $found = $true }
                        else { $line }
                    })
                    if (-not $found) { $newLines += "START_MODE=$newMode" }
                    [System.IO.File]::WriteAllLines($script:CONFIG, $newLines, (New-Object System.Text.UTF8Encoding $false))
                    $script:StartMode = $newMode
                    Write-Log "Start mode updated to '$newMode' in config."
                } catch {
                    $msg = $_.Exception.Message -replace '"',"'"
                    Send-Response $ctx ('{"error":"Config update failed: ' + $msg + '"}') 500
                    break
                }

                # Re-register the scheduled task with the new trigger/principal
                $requiresLogoff = $false
                $binDir = Split-Path $script:BIN
                $psArg  = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $binDir 'dagtech-control.ps1') + '"'
                try {
                    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArg
                    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
                    if ($newMode -eq "login") {
                        $interactiveUser = (Get-CimInstance Win32_ComputerSystem).UserName
                        if (-not $interactiveUser) { throw "Could not determine logged-in user" }
                        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $interactiveUser
                        $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Highest
                        $requiresLogoff = $true
                    } else {
                        $trigger   = New-ScheduledTaskTrigger -AtStartup
                        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
                    }
                    Unregister-ScheduledTask -TaskName $script:TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
                    $null = Register-ScheduledTask -TaskName $script:TASK_NAME -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop
                    Write-Log "Task '$($script:TASK_NAME)' re-registered as '$newMode' mode."
                } catch {
                    $msg = $_.Exception.Message -replace '"',"'"
                    # Config saved — report partial success with warning
                    $logoffStr = $requiresLogoff.ToString().ToLower()
                    Send-Response $ctx ('{"ok":true,"mode":"' + $newMode + '","requires_logoff":' + $logoffStr + ',"warn":"Task re-registration failed: ' + $msg + '"}')
                    break
                }
                $logoffStr = $requiresLogoff.ToString().ToLower()
                Send-Response $ctx ('{"ok":true,"mode":"' + $newMode + '","requires_logoff":' + $logoffStr + '}')
                break
            }
            "/logs" {
                $tail = 200
                try {
                    $qs = $ctx.Request.Url.Query
                    if ($qs -match '[?&]tail=(\d+)') { $tail = [int]$Matches[1] }
                } catch {}
                $logFile = Join-Path $script:LOGDIR "miner_$(Get-Date -Format 'yyyy-MM-dd').log"
                $lines = @()
                if (Test-Path $logFile) {
                    try {
                        $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                        $content = $reader.ReadToEnd()
                        $reader.Close(); $fs.Close()
                        $all = ($content -split "`r?`n") | Where-Object { $_ -ne '' }
                        $lines = if ($all.Count -gt $tail) { $all[($all.Count - $tail)..($all.Count - 1)] } else { $all }
                    } catch { $lines = @("Error reading log: $($_.Exception.Message)") }
                } else {
                    $lines = @("No log file for today yet.")
                }
                $escaped = $lines | ForEach-Object { '"' + ($_ -replace '\\','\\' -replace '"','\"') + '"' }
                Send-Response $ctx ('[' + ($escaped -join ',') + ']')
                break
            }
            "/sysinfo" {
                $out = @{}

                # CPU usage
                try {
                    $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
                    $out["cpu_usage"] = [math]::Round([double]$load, 1)
                } catch {}

                # Memory
                try {
                    $os = Get-CimInstance Win32_OperatingSystem
                    $out["mem_used_mb"]  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)
                    $out["mem_total_mb"] = [math]::Round($os.TotalVisibleMemorySize / 1024)
                } catch {}

                # Temperatures via LibreHardwareMonitor WMI
                try {
                    $lhmSensors = Get-CimInstance -Namespace root/OpenHardwareMonitor -ClassName Sensor -ErrorAction Stop |
                                  Where-Object { $_.SensorType -eq "Temperature" }
                    if ($lhmSensors) {
                        $cpuPkg = $lhmSensors | Where-Object { $_.Name -match "CPU Package|CPU Tdie|Tdie|Package" } | Select-Object -First 1
                        if (-not $cpuPkg) { $cpuPkg = $lhmSensors | Where-Object { $_.Identifier -match "/cpu/" } | Select-Object -First 1 }
                        if ($cpuPkg) { $out["cpu_temp"] = [math]::Round([double]$cpuPkg.Value, 1) }

                        $gpuTemp = $lhmSensors | Where-Object { $_.Identifier -match "/gpu" -and $_.Name -match "GPU Core|GPU Temperature|Temperature" } | Select-Object -First 1
                        if ($gpuTemp) { $out["gpu_temp"] = [math]::Round([double]$gpuTemp.Value, 1) }
                    }
                } catch {}

                # CPU temperature fallback
                if (-not $out.ContainsKey("cpu_temp")) {
                    try {
                        $zones = Get-CimInstance -Namespace root/WMI -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
                        $temps = @($zones | ForEach-Object { ($_.CurrentTemperature - 2732) / 10.0 })
                        if ($temps.Count -gt 0) {
                            $out["cpu_temp"] = [math]::Round(($temps | Measure-Object -Maximum).Maximum, 1)
                        }
                    } catch {}
                }

                # NVIDIA GPU
                if (-not $out.ContainsKey("gpu_temp")) { try {
                    $nvPaths = @(
                        "nvidia-smi",
                        "C:\Windows\System32\nvidia-smi.exe",
                        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                        (Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe")
                    )
                    $nvExe = $nvPaths | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
                    if (-not $nvExe) {
                        $nvExe = Get-ChildItem "$env:SystemRoot\System32\nvidia-smi.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
                    }
                    if ($nvExe) {
                        $nv = & $nvExe --query-gpu=temperature.gpu,utilization.gpu,name --format=csv,noheader,nounits 2>$null
                        if ($nv) {
                            $p = ($nv | Select-Object -First 1).Trim() -split ',\s*'
                            if ($p.Count -ge 3) {
                                $out["gpu_temp"]   = [double]$p[0].Trim()
                                $out["gpu_usage"]  = [double]$p[1].Trim()
                                $out["gpu_name"]   = $p[2].Trim()
                                $out["gpu_vendor"] = "nvidia"
                            }
                        }
                    }
                } catch {} }

                # GPU name + vendor via WMI
                if (-not $out.ContainsKey("gpu_name")) {
                    try {
                        $gpu = Get-WmiObject Win32_VideoController | Select-Object -First 1
                        if ($gpu) {
                            $out["gpu_name"] = $gpu.Name
                            if ($gpu.Name -match "NVIDIA") { $out["gpu_vendor"] = "nvidia" }
                            elseif ($gpu.Name -match "AMD|Radeon") { $out["gpu_vendor"] = "amd" }
                            else { $out["gpu_vendor"] = "unknown" }
                        }
                    } catch {}
                }

                # GPU usage fallback
                if (-not $out.ContainsKey("gpu_usage")) {
                    try {
                        $sample = Get-Counter '\GPU Engine(*engtype_3D*)\Utilization Percentage' -ErrorAction Stop
                        $usage = ($sample.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum
                        $out["gpu_usage"] = [math]::Round([double]$usage, 1)
                    } catch {}
                }

                $kvs = @()
                foreach ($k in $out.Keys) {
                    $v = $out[$k]
                    if ($v -is [string]) { $kvs += ('"' + $k + '":"' + ($v.Replace('\','\\').Replace('"','\"')) + '"') }
                    else                 { $kvs += ('"' + $k + '":' + $v) }
                }
                Send-Response $ctx ('{' + ($kvs -join ',') + '}')
                break
            }
            "/metrics" {
                $cfg = Read-Config
                $minerRunning = $null -ne (Get-MinerProcess)
                $runningStr   = if ($minerRunning) { "true" } else { "false" }
                # Derive mining_mode from config
                $miningMode = if     ($cfg["MINING_MODE"])        { $cfg["MINING_MODE"] }
                              elseif ($cfg["GPU_ENABLED"] -eq "1") { "both" }
                              else                                  { "cpu" }

                $out = @{
                    wallet        = if ($cfg["WALLET"])             { $cfg["WALLET"] }                                   else { "" }
                    worker        = if ($cfg["WORKER_NAME"])        { $cfg["WORKER_NAME"] }                              else { "" }
                    pool          = if ($cfg["POOL_HOST"])          { $cfg["POOL_HOST"] + ":" + $cfg["POOL_PORT"] }      else { "" }
                    threads       = if ($cfg["THREADS"])            { [int]$cfg["THREADS"] }                             else { 0 }
                    version       = if ($cfg["INSTALLER_VERSION"])  { $cfg["INSTALLER_VERSION"] }                        else { "" }
                    gpu_intensity = if ($cfg["GPU_INTENSITY"])      { [int]$cfg["GPU_INTENSITY"] }                       else { 80 }
                    mining_mode   = $miningMode
                    job_id           = ""
                    hashrate         = 0.0
                    accepted         = 0
                    submitted        = 0
                    rejected         = 0
                    uptime           = 0
                    total_hashes     = 0
                    difficulty       = 0.0
                    cpu_shares_found = 0
                    gpu_shares_found = 0
                }
                $logFile = Join-Path $script:LOGDIR "miner_$(Get-Date -Format 'yyyy-MM-dd').log"
                if (Test-Path $logFile) {
                    try {
                        $fs     = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                        $content = $reader.ReadToEnd()
                        $reader.Close(); $fs.Close()
                        $lines = $content -split "`r?`n"
                        # Full-scan share counts — CPU and GPU have different log prefixes
                        $out["cpu_shares_found"] = ($lines | Where-Object { $_ -match '\[DagTech\] \*\* SHARE FOUND \*\*' }).Count
                        $out["gpu_shares_found"] = ($lines | Where-Object { $_ -match '\[DagTech GPU\] \*\* SHARE FOUND \*\*' }).Count
                        $foundStats = $false
                        $foundDiff  = $false
                        $foundJob   = $false
                        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                            if ($foundStats -and $foundDiff -and $foundJob) { break }
                            $line = $lines[$i]
                            # Match GPU stats line: X.XX H/s | CPU: Y H/s | GPU: Z H/s | Shares: ...
                            if (-not $foundStats -and $line -match '\[DagTech\]\s+([\d.]+)\s+H/s\s+\|\s+CPU:\s+([\d.]+)\s+H/s\s+\|\s+GPU:\s+([\d.]+)\s+H/s\s+\|\s+Shares:\s+(\d+)/(\d+)/(\d+).*Uptime:\s+(\d+)h(\d+)m') {
                                $out["hashrate"]     = [double]$Matches[1]
                                $out["cpu_hashrate"] = [double]$Matches[2]
                                $out["gpu_hashrate"] = [double]$Matches[3]
                                $out["submitted"]    = [int]$Matches[4]
                                $out["accepted"]     = [int]$Matches[5]
                                $out["rejected"]     = [int]$Matches[6]
                                $uptimeSec           = [int]$Matches[7] * 3600 + [int]$Matches[8] * 60
                                $out["uptime"]       = $uptimeSec
                                $out["total_hashes"] = [long]($out["hashrate"] * $uptimeSec)
                                $foundStats = $true
                            }
                            # Also match CPU-only stats line
                            if (-not $foundStats -and $line -match '\[DagTech\]\s+([\d.]+)\s+H/s\s+\|\s+Shares:\s+(\d+)/(\d+)/(\d+).*Uptime:\s+(\d+)h(\d+)m') {
                                $out["hashrate"]     = [double]$Matches[1]
                                $out["submitted"]    = [int]$Matches[2]
                                $out["accepted"]     = [int]$Matches[3]
                                $out["rejected"]     = [int]$Matches[4]
                                $uptimeSec           = [int]$Matches[5] * 3600 + [int]$Matches[6] * 60
                                $out["uptime"]       = $uptimeSec
                                $out["total_hashes"] = [long]($out["hashrate"] * $uptimeSec)
                                $foundStats = $true
                            }
                            if (-not $foundDiff -and $line -match '\[DagTech\]\s+Difficulty:\s+([\d.]+)') {
                                $out["difficulty"] = [double]$Matches[1]
                                $foundDiff = $true
                            }
                            if (-not $foundJob -and $line -match '\[DagTech\]\s+New job:\s+(\S+)') {
                                $out["job_id"] = $Matches[1]
                                $foundJob = $true
                            }
                        }
                    } catch {}
                }
                $kvs = @('"running":' + $runningStr)
                foreach ($k in $out.Keys) {
                    $v = $out[$k]
                    if ($v -is [string]) { $kvs += ('"' + $k + '":"' + ($v.Replace('\','\\').Replace('"','\"')) + '"') }
                    else { $kvs += ('"' + $k + '":' + ($v.ToString([System.Globalization.CultureInfo]::InvariantCulture))) }
                }
                Send-Response $ctx ('{' + ($kvs -join ',') + '}')
                break
            }
            default {
                Send-Response $ctx '{"error":"not found"}' 404
                break
            }
        }
    } catch [System.Net.HttpListenerException] {
        break
    } catch {
        Write-Log "Request error: $_"
    }

    # Inline watchdog: runs on the main thread every 30 s — no threading issues
    $now = [datetime]::UtcNow
    if (($now - $script:LastWatchdog).TotalSeconds -ge 30) {
        $script:LastWatchdog = $now
        if (-not (Test-Path $script:STOPFILE) -and -not (Get-MinerProcess)) {
            Write-Log "Watchdog: miner not running, restarting..."
            Start-MinerProcess
        }
    }
}

Write-Log "Control server stopped."
