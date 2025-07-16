# BACKEND - System Monitor Data Collector
# Collects system stats and writes to monitoring_data.json every minute

# Load config for latency servers and other settings
$configPath = Join-Path $PSScriptRoot 'config.json'
$DataFile = Join-Path $PSScriptRoot 'monitoring_data.json'
if (Test-Path $configPath) {
    try {
        $json = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($null -ne $json.DataFile) { $DataFile = $json.DataFile }
    } catch {
        $DataFile = Join-Path $PSScriptRoot 'monitoring_data.json'
    }
} else {
    $DataFile = Join-Path $PSScriptRoot 'monitoring_data.json'
}

function Generate_BatteryReport {
    $tempPath = [System.IO.Path]::GetTempPath()
    $reportPath = Join-Path $tempPath 'battery-report.html'
    Start-Process -FilePath 'powercfg' -ArgumentList "/batteryreport /output `"$reportPath`"" -Wait -WindowStyle Hidden
    # Wait for the file to exist (max 5 seconds)
    $timeout = 0
    while (-not (Test-Path $reportPath) -and $timeout -lt 50) {
        Start-Sleep -Milliseconds 100
        $timeout++
    }
    if (Test-Path $reportPath) {
        Start-Process $reportPath
    } 
}

function Generate_WiFiReport {
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-Command', 'netsh wlan show wlanreport' -Wait -NoNewWindow -PassThru
    $reportPath = 'C:\ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html'
    if (Test-Path $reportPath) {
        Start-Process $reportPath
    }
}
Function Get-PerformanceCounterLocalName
{
  param
  (
    [UInt32]
    $ID,
    $ComputerName = $env:COMPUTERNAME
  )

  $code = '[DllImport("pdh.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern UInt32 PdhLookupPerfNameByIndex(string szMachineName, uint dwNameIndex, System.Text.StringBuilder szNameBuffer, ref uint pcchNameBufferSize);'

  $Buffer = New-Object System.Text.StringBuilder(1024)
  [UInt32]$BufferSize = $Buffer.Capacity

  $t = Add-Type -MemberDefinition $code -PassThru -Name PerfCounter -Namespace Utility
  $rv = $t::PdhLookupPerfNameByIndex($ComputerName, $id, $Buffer, [Ref]$BufferSize)

  if ($rv -eq 0)
  {
    $Buffer.ToString().Substring(0, $BufferSize-1)
  }
  else
  {
    Throw 'Get-PerformanceCounterLocalName : Unable to retrieve localized name. Check computer name and performance counter ID.'
  }
}

function Get-CPUUsage {
    $processor = Get-PerformanceCounterLocalName 238
    $percentProcessorTime = Get-PerformanceCounterLocalName 6
    try {
        $cpuLoad = (Get-Counter "\$processor(_total)\$percentProcessorTime" -SampleInterval 1).CounterSamples.CookedValue
    } catch {
        $cpuLoad = $null
    }
    if ($null -ne $cpuLoad) {
        return [math]::Round([double]$cpuLoad, 2)
    } else {
        return 0
    }
}

function Get-MemoryUsage {
    $os = Get-CimInstance Win32_OperatingSystem
    $total = $os.TotalVisibleMemorySize
    $free = $os.FreePhysicalMemory
    $usedPercent = [math]::Round((($total - $free) / $total) * 100, 2)
    return $usedPercent
}

function Get-HDDFree {
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $total = $drive.Size
    $free = $drive.FreeSpace
    $usedPercent = if ($total -ne 0) { [math]::Round((($total - $free) / $total) * 100, 2) } else { 0 }
    return $usedPercent
}

function Get-WifiStatus {
    <#
    .SYNOPSIS
        Returns an object with current Wi-Fi SSID, signal strength, and connection state (language-independent).
    .EXAMPLE
        $wifi = Get-WifiStatus
        $wifi | Format-List
    #>
    $wifiAdapter = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq 9 } | Select-Object -First 1
    if (-not $wifiAdapter) {
        return [PSCustomObject]@{
            WifiPresent = $false
            Message = "No Wi-Fi adapter found or not connected."
        }
    }
    $wifiprofile = Get-NetConnectionProfile -InterfaceAlias $wifiAdapter.Name -ErrorAction SilentlyContinue
    $ssid = $wifiprofile.Name
    $state = $wifiAdapter.Status
    # Try to get signal quality using netsh (language-independent parsing)
    $netsh = netsh wlan show interfaces | Out-String
    $signal = ($netsh -split "\r?\n") | Where-Object { $_ -match 'Signal' } | ForEach-Object { ($_ -split ':')[1].Trim() } | Select-Object -First 1
    # Convert signal to integer (remove % if present)
    # Fix: handle French/other languages and whitespace, and robust percent extraction
    if ($signal -match '([0-9]+)%') {
        $signal = [int]$Matches[1]
    } elseif ($signal -match '^[0-9]+$') {
        $signal = [int]$signal
    } else {
        $signal = $null
    }
    $bssid = ($netsh -split "\r?\n") | Where-Object { $_ -match '([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})' } | Where-object { $_ -match "SSID" } | ForEach-Object { ($_ -split ': ')[1].Trim() }
    
    return [PSCustomObject]@{
        WifiPresent = $true
        SSID = $ssid
        BSSID = $bssid
        Signal = $signal
        State = $state
    }
}

function Get-BatteryStatus {
    $battery = Get-CimInstance Win32_Battery
    if ($battery) {
        $percent = $battery.EstimatedChargeRemaining
        $status = switch ($battery.BatteryStatus) {
            1 { "Discharging" }
            2 { "AC Power" }
            3 { "Fully Charged" }
            4 { "Low" }
            5 { "Critical" }
            6 { "Charging" }
            7 { "Charging and High" }
            8 { "Charging and Low" }
            9 { "Charging and Critical" }
            10 { "Undefined" }
            11 { "Partially Charged" }
            default { "Unknown" }
        }
        return @{ Percent = $percent; Status = $status }
    } else {
        return @{ Percent = 0; Status = "No Battery" }
    }
}

function Get-Latency {
    param(
        [string]$Server = $Server,
        [int]$Port = $Port
    )
    
    $timeoutMs = 2000  # 2 seconds timeout
    if ($Port) {
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $tcp = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $tcp.BeginConnect($Server, $Port, $null, $null)
            $waitHandle = $asyncResult.AsyncWaitHandle
            if ($waitHandle.WaitOne($timeoutMs, $false)) {
                $tcp.EndConnect($asyncResult)
                $sw.Stop()
                $tcp.Close()
                return [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            } else {
                $tcp.Close()
                return -1  # Timed out
            }
        } catch {
            return -1
        }
    } else {
        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $reply = $ping.Send($Server, $timeoutMs)
            if ($reply.Status -eq 'Success') {
                return [math]::Round($reply.RoundtripTime, 2)
            } else {
                return -1  # Ping failed
            }
        } catch {
            return -1  # Exception occurred
        }
    }
}

$LatencyServers = @()
if (Test-Path $configPath) {
    try {
        $json = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($null -ne $json.LatencyServers) { $LatencyServers = $json.LatencyServers }
    } catch {}
}
# Command file path (sent by frontend)
$commandFile = Join-Path $PSScriptRoot 'command.json'
$expectedSecret = "MY_SUPER_SECRET" # Optionally, use a shared secret for validation

while ($true) {
    if (Test-Path $commandFile) {
        try {
            $cmd = Get-Content $commandFile -Raw | ConvertFrom-Json
            # Optional: check for a secret to validate the command
            if (($null -eq $cmd.secret) -or ($cmd.secret -eq $expectedSecret)) {
                switch ($cmd.Command) {
                    "ClearBrowserCache" {
                    # Place your browser cache clearing logic here
                    Write-Host "Clearing browser cache (backend action)"
                    # Example: Remove-Item -Path "C:\Path\To\Browser\Cache\*" -Recurse -Force
                    }
                    "ClearDarwinCache" {
                    # Place your Darwin cache clearing logic here
                    Write-Host "Clearing Darwin cache (backend action)"
                    # Example: Remove-Item -Path "C:\Path\To\Darwin\Cache\*" -Recurse -Force
                    }
                    "GenerateBatteryReport" {
                    Generate_BatteryReport
                    }
                    "GenerateWifiReport" {
                    Generate_WiFiReport
                    }
                    default {
                    Write-Host "Unknown command received from frontend: $($cmd.Command)"
                    }
                }   
            }
        } catch {
            Write-Host "Failed to process frontend command: $_"
        }
        Remove-Item $commandFile -Force 
    }
        $data = @{
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        cpu = Get-CPUUsage
        memory = Get-MemoryUsage
        hdd = Get-HDDFree
        wifi = Get-WifiStatus
        battery = Get-BatteryStatus
        latency = @()
    }
    foreach ($server in $LatencyServers) {
        if ($server.Address -eq "@gateway@") {
            $server.Address = (Get-NetIPConfiguration | Where-Object { $null -ne $_.IPv4DefaultGateway }).IPv4DefaultGateway.NextHop
        }
        if ($server.Address -eq "@dns@") {
            $server.Address = (Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2 | Where-Object { $_.ServerAddresses.Count -gt 0 })[0].ServerAddresses[0]
        }
        $lat = if ($server.Port) { Get-Latency -Server $server.Address -Port $server.Port } else { Get-Latency -Server $server.Address }
        $data.latency += @{ name = $server.Name; value = $lat }
    }
    $data.TimeStamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')

    # Retry logic for file write
    $maxRetries = 5
    $retryDelay = 1 # seconds
    for ($try = 1; $try -le $maxRetries; $try++) {
        try {
            $data | ConvertTo-Json -Depth 5 | Set-Content -Path $DataFile -Encoding UTF8 -ErrorAction SilentlyContinue
            break
        } catch {
            Start-Sleep -Seconds $retryDelay
        }
    }
}
