function Get-MonitoringData {
    param (
        [string]$dataFilePath = (Join-Path $PSScriptRoot 'monitoring_data.json'),
        [int]$maxRetries = 5,
        [int]$retryDelayMs = 200
    )
    $data = $null
    for ($try = 1; $try -le $maxRetries; $try++) {
        try {
            $data = Get-Content $dataFilePath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            break
        } catch {
            if ($try -eq $maxRetries) {
                Write-Warning "Unable to read monitoring data after $maxRetries attempts."
                return $null
            }
            Start-Sleep -Milliseconds $retryDelayMs
        }
    }
    return $data
}

function Update-MonitorUI {
    # Read values from the datafile
    $DataFile = Join-Path $PSScriptRoot 'monitoring_data.json'
    if ($null -ne $json.DataFile) { $DataFile = $json.DataFile }
    if (Test-Path $DataFile) {
        try {
            $data = Get-MonitoringData -dataFilePath $DataFile
        } catch {
            $data = $null
        }
    } else {
        $data = $null
         # Data file missing: show alert icon and update tooltip
        $thresholdIconBox.Image = Get-ImageFromBase64 -Base64 $Global:Images['alert']
        $thresholdToolTip.SetToolTip($thresholdIconBox, "Data file not found!")
        $timestampLabel.Text = "Timestamp: -- (data file missing)"
        $timestampLabel.ForeColor = 'Red'
        $notifyIcon.Icon = Get-Icon -Name "alert"
        $notifyIcon.Text = "Data file not found!"
        return       
    }

    $timestampLabel.Text = "Timestamp:" + ($data.timestamp)
    # Set timestamp label color based on age
    $timestampLabel.ForeColor = 'Black'
    if ($data -and $data.timestamp) {
        $dataTime = [datetime]::Parse($data.timestamp)
        $now = Get-Date
        $maxAge = $Refresh * 5 / 1000  # $Refresh is in ms, convert to seconds
        if (($now - $dataTime).TotalSeconds -gt $maxAge) {
            $timestampLabel.ForeColor = 'Red'
        }
    }
    $issues = 0
    $issueList = @()
    if ($data) {
        $progressBars[0].Value = [int]$data.cpu
        $valueLabels[0].Text = "$($progressBars[0].Value) %"
        if ($progressBars[0].Value -lt $thresholds.CPU_Usage) {
            $valueLabels[0].ForeColor = 'Green'
        } else {
            $valueLabels[0].ForeColor = 'Red'
            $issues++
            $issueList += "CPU usage high"
        }
        $progressBars[1].Value = [int]$data.memory
        $valueLabels[1].Text = "$($progressBars[1].Value) %"
        if ($progressBars[1].Value -lt $thresholds.Memory_Usage) {
            $valueLabels[1].ForeColor = 'Green'
        } else {
            $valueLabels[1].ForeColor = 'Red'
            $issues++
            $issueList += "Memory usage high"
        }
        $progressBars[2].Value = [int]$data.hdd
        $valueLabels[2].Text = "$($progressBars[2].Value) %"
        if ($progressBars[2].Value -lt $thresholds.HDD_Usage) {
            $valueLabels[2].ForeColor = 'Green'
        } else {
            $valueLabels[2].ForeColor = 'Red'
            $issues++
            $issueList += "Disk usage high"
        }
        $progressBars[3].Value = [int]$data.wifi.Signal
        $valueLabels[3].Text = "$($progressBars[3].Value) %"
        if ($progressBars[3].Value -gt $thresholds.WiFi_Signal) {
            $valueLabels[3].ForeColor = 'Green'
        } else {
            $valueLabels[3].ForeColor = 'Red'
            $issues++
            $issueList += "WiFi signal low"
        }
        $battery = $data.battery
        $progressBars[4].Value = [int]$battery.Percent
        $valueLabels[4].Text = "$($progressBars[4].Value) %"
        if ($progressBars[4].Value -gt $thresholds.Battery) {
            $valueLabels[4].ForeColor = 'Green'
        } else {
            $valueLabels[4].ForeColor = 'Red'
            $issues++
            $issueList += "Battery low"
        }
        for ($i = 0; $i -lt $LatencyServers.Count; $i++) {
            $server = $LatencyServers[$i]
            $latencyData = $data.latency | Where-Object { $_.name -eq $server.Name }
            $lat = if ($latencyData) { [int]$latencyData.value } else { -1 }
            $latencyBars[$i].Value = ([Math]::Min([Math]::Max($lat, 0),100))
            $latencyValues[$i].Text = "$($lat) ms"
            if (($lat -eq -1) -or ($lat -gt $thresholds.Latency)) {
                $latencyValues[$i].ForeColor = 'Red'
                $issues++
                $issueList += ("Latency {0} high" -f $server.Name)
            } else {
                $latencyValues[$i].ForeColor = 'Green'
            }
        }
    }
    # Set notifyIcon icon based on issues
    if ($issues -eq 0) {
        $notifyIcon.Icon = Get-Icon -Name "monitor"
        $thresholdIconBox.Image = Get-ImageFromBase64 -Base64 $Global:Images['ok']
        $notifyIcon.Text = "System OK"
    } else {
        if ($issues -eq 1) {
            $notifyIcon.Icon = Get-Icon -Name "warning"
            $thresholdIconBox.Image = Get-ImageFromBase64 -Base64 $Global:Images['warning']
        } else {
            $notifyIcon.Icon = Get-Icon -Name "alert"
            $thresholdIconBox.Image = Get-ImageFromBase64 -Base64 $Global:Images['alert']
        }
        # Compose plain text issue summary for tooltip (max 63 chars)
        $notifyIcon.Text = ("Issues: " + ($issueList -join ", ")).Substring(0, [Math]::Min(63, ("Issues: " + ($issueList -join ", ")).Length))
    }
    # Update the threshold tooltip to match the notify icon text
    $thresholdToolTip.SetToolTip($thresholdIconBox, $notifyIcon.Text)
    # Update the tooltip for the battery icon
    if ($null -ne $battery.Status) {
        $tip = "Status: $($battery.Status)`nCharge: $($battery.Percent)%"
    } else {
        $tip = "No battery information."
    }
    $batteryToolTip.SetToolTip($batteryIconBox, $tip)
    # Update the tooltip for the network icon
    if ($data.wifi.WifiPresent) {
        $tipNet = "SSID: $($data.wifi.SSID)`nSignal: $($data.wifi.Signal)%`nState: $($data.wifi.State)`nBSSID: $($data.wifi.BSSID)"
    } else {
        $tipNet = $data.wifi.Message
    }
    $networkToolTip.SetToolTip($networkIconBox, $tipNet)
}