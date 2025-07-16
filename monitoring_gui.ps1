# load the necessary assemblies for Windows Forms and Drawing
$debug = $true 
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Get the full path of the current script
$scriptPath = $MyInvocation.MyCommand.Path

# Get the directory of the current script
$scriptDirectory = Split-Path -Path $scriptPath

# Get the name of the script (without extension)
# $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($scriptPath)

# Get the extension of the script
# $scriptExtension = [System.IO.Path]::GetExtension($scriptPath)

# Get the version of the script
$scriptVersion = (Get-Item $scriptPath).VersionInfo.FileVersion

# Define the path to the config file
$configPath = $scriptDirectory + "\config.json"

# Load the IconManager module
# Ensure the script is run from the same directory as the module
. $scriptDirectory\IconManager.ps1  # Dot-source the module
# Load the function module
. $scriptDirectory\Function.ps1  # Dot-source the function module


# Load configuration from JSON file
$configPath = Join-Path $PSScriptRoot 'config.json'
$thresholds = @{
    CPU_Usage = 80
    Memory_Usage = 80
    HDD_Usage = 90
    WiFi_Signal = 30
    Latency = 50
    Battery = 20
}
$Refresh = 30000
$LatencyServers = @()
$showNotification = $true
if (Test-Path $configPath) {
    try {
        $json = Get-Content $configPath -Raw | ConvertFrom-Json
        $thresholds.CPU_Usage = $json.CPU_Usage
        $thresholds.Memory_Usage = $json.Memory_Usage
        $thresholds.HDD_Usage = $json.HDD_Usage
        $thresholds.WiFi_Signal = $json.WiFi_Signal
        $thresholds.Latency = $json.Latency
        $thresholds.Battery = $json.Battery
        if ($null -ne $json.show_notification) {
            $showNotification = [bool]$json.show_notification
        }
        if ($null -ne $json.LatencyServers) { $LatencyServers = $json.LatencyServers }
        if ($null -ne $json.Refresh) { $Refresh = $json.Refresh*1000 }

        if ($null -ne $json.BrowserCache) { $browserItem.Visible = [bool]$json.BrowserCache }
    } catch {}
}

# Create NotifyIcon (taskbar icon)
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = Get-Icon -Name "monitor"
$notifyIcon.Text = "System Monitor"
$notifyIcon.Visible = $true

# Create context menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = $menu.Items.Add("Show Monitor")
$settingItem = $menu.Items.Add("Settings")
# Only show the Settings menu if user is admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    $settingItem.Visible = $true
} else {
    $settingItem.Visible = $debug
}
$browserItem = $menu.Items.Add("Clear Browser Cache")
# Set menu item visibility based on config
if ($null -ne $json.BrowserCache) { $browserItem.Visible = [bool]$json.BrowserCache }
$cacheItem = $menu.Items.Add("Clear Darwin Cache")
# Set menu item visibility based on config
if ($null -ne $json.Darwin) { $cacheItem.Visible = [bool]$json.Darwin }
$exitItem = $menu.Items.Add("Exit")
$notifyIcon.ContextMenuStrip = $menu

# Create the main form
$form = New-Object System.Windows.Forms.Form
$form.Text = "System Monitor $scriptVersion"
$form.Size = New-Object System.Drawing.Size(400, 370)
$form.StartPosition = "CenterScreen"
$form.MinimizeBox = $false
$form.MaximizeBox = $false
$form.Icon = Get-Icon -Name "monitor"

# Timestamp label
$timestampLabel = New-Object System.Windows.Forms.Label
$timestampLabel.Text = "Timestamp: --"
$timestampLabel.Location = New-Object System.Drawing.Point(20, 10)
$timestampLabel.Size = New-Object System.Drawing.Size(350, 20)
$form.Controls.Add($timestampLabel)

# --- Add TabControl for main and latency tabs ---
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(10, 40)
$tabControl.Size = New-Object System.Drawing.Size(370, 230)

$mainTab = New-Object System.Windows.Forms.TabPage
$mainTab.Text = "Main"

$latencyTab = New-Object System.Windows.Forms.TabPage
$latencyTab.Text = "Latency"

$tabControl.TabPages.Add($mainTab)
$tabControl.TabPages.Add($latencyTab)
$form.Controls.Add($tabControl)

# --- Main tab progress bars (no latency) ---
$labels = @("CPU Usage", "Memory Usage", "HDD Usage", "WiFi Signal", "Battery")
$units = @("$($thresholds.CPU_Usage) %", "$($thresholds.Memory_Usage) %", "$($thresholds.HDD_Usage) %", "$($thresholds.WiFi_Signal) %", "$($thresholds.Battery) %")
$progressBars = @()
$progressLabels = @()
$valueLabels = @()

for ($i = 0; $i -lt $labels.Count; $i++) {
    $y = 10 + ($i * 40)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $labels[$i]
    $lbl.Location = New-Object System.Drawing.Point(10, $y)
    $lbl.Size = New-Object System.Drawing.Size(120, 20)
    $mainTab.Controls.Add($lbl)
    $progressLabels += $lbl

    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Location = New-Object System.Drawing.Point(140, $y)
    $pb.Size = New-Object System.Drawing.Size(160, 20)
    $pb.Minimum = 0
    $pb.Maximum = 100
    $mainTab.Controls.Add($pb)
    $progressBars += $pb

    $valLbl = New-Object System.Windows.Forms.Label
    $valLbl.Text = $units[$i]
    $valLbl.Location = New-Object System.Drawing.Point(310, $y)
    $valLbl.Size = New-Object System.Drawing.Size(60, 20)
    $valLbl.TextAlign = 'MiddleLeft'
    $mainTab.Controls.Add($valLbl)
    $valueLabels += $valLbl
}

# --- Latency progress bars in the Latency tab ---
$latencyBars = @()
$latencyLabels = @()
$latencyValues = @()

for ($i = 0; $i -lt $LatencyServers.Count; $i++) {
    $server = $LatencyServers[$i]
    if ($server.Address -eq "@gateway@") {
            $server.Address = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null }).IPv4DefaultGateway.NextHop
    }
    if ($server.Address -eq "@dns@") {
            $server.Address = (Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2 | Where-Object { $_.ServerAddresses.Count -gt 0 })[0].ServerAddresses[0]
    }
    $y = 10 + ($i * 40)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "$($server.Name)"
    $label.Location = New-Object System.Drawing.Point(10, $y)
    $label.Size = New-Object System.Drawing.Size(120, 20)
    $latencyTab.Controls.Add($label)
    $latencyLabels += $label
    # Create a ToolTip for the label
    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.SetToolTip($label, $server.Address)  # Show address in tooltip

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(140, $y)
    $bar.Size = New-Object System.Drawing.Size(160, 20)
    $bar.Minimum = 0
    $bar.Maximum = 100
    $latencyTab.Controls.Add($bar)
    $latencyBars += $bar

    $val = New-Object System.Windows.Forms.Label
    $val.Text = "$($thresholds.Latency) ms"
    $val.Location = New-Object System.Drawing.Point(310, $y)
    $val.Size = New-Object System.Drawing.Size(60, 20)
    $val.TextAlign = 'MiddleLeft'
    $latencyTab.Controls.Add($val)
    $latencyValues += $val
}

# Add a PictureBox for battery status icon
$batteryIconBox = New-Object System.Windows.Forms.PictureBox
$batteryIconBox.Location = New-Object System.Drawing.Point(60, 282)
$batteryIconBox.Size = New-Object System.Drawing.Size(32, 32)
$batteryIconBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
$form.Controls.Add($batteryIconBox)
# Create a ToolTip for the battery icon
$batteryToolTip = New-Object System.Windows.Forms.ToolTip
$batteryToolTip.SetToolTip($batteryIconBox, "Battery status loading...")

# Add a PictureBox for network status icon
$networkIconBox = New-Object System.Windows.Forms.PictureBox
$networkIconBox.Location = New-Object System.Drawing.Point(120, 282)
$networkIconBox.Size = New-Object System.Drawing.Size(32, 32)
$networkIconBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
$form.Controls.Add($networkIconBox)
# Create a ToolTip for the network icon
$networkToolTip = New-Object System.Windows.Forms.ToolTip
$networkToolTip.SetToolTip($networkIconBox, "WiFi status loading...")

# Add a PictureBox for threshold status icon
$thresholdIconBox = New-Object System.Windows.Forms.PictureBox
$thresholdIconBox.Location = New-Object System.Drawing.Point(300, 282)
$thresholdIconBox.Size = New-Object System.Drawing.Size(32, 32)
$thresholdIconBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
$form.Controls.Add($thresholdIconBox)
# Create a ToolTip for the threshold icon
$thresholdToolTip = New-Object System.Windows.Forms.ToolTip
$thresholdToolTip.SetToolTip($thresholdIconBox, "Evaluating...")

# Show the wifi icon by default
$networkIconBox.Image = Get-ImageFromBase64 -Base64 $Global:Images['wifi']

# Show the battery icon by default
$batteryIconBox.Image = Get-ImageFromBase64 -Base64 $Global:Images['battery']

# Show the checking icon by default
$thresholdIconBox.Image = Get-ImageFromBase64 -Base64 $Global:Images['checking']

# Show form handler: bring to front if already open
$showForm = {
    if ($form.Visible) {
        $form.WindowState = 'Normal'
        $form.Activate()
        $form.TopMost = $true
        $form.TopMost = $false
    } else {
        $form.ShowDialog() | Out-Null
    }
}
$showItem.Add_Click($showForm)

# Exit handler
$exitItem.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Are you sure you want to exit?",
        "Exit Confirmation",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
        if ($batteryIconBox.Image) { $batteryIconBox.Image.Dispose() }
        if ($networkIconBox.Image) { $networkIconBox.Image.Dispose() }
        if ($thresholdIconBox.Image) { $thresholdIconBox.Image.Dispose() }
        $form.Close()
        $form.Dispose()
        [System.Windows.Forms.Application]::Exit()
    }
})

# Settings handler
$settingItem.Add_Click({
# build form to change settings
    $settingsForm = New-Object System.Windows.Forms.Form
    $settingsForm.Text = "Settings"
    $settingsForm.Size = New-Object System.Drawing.Size(550, 400)
    $settingsForm.StartPosition = "CenterScreen"

    # Add controls for each setting
    $labels = @("CPU Usage Threshold", "Memory Usage Threshold", "HDD Usage Threshold", "WiFi Signal Threshold", "Latency Threshold", "Battery Threshold", "Refresh Interval (seconds)", "Show Notifications", "Show Darwin Cache", "Show Browser Cache")
    $textBoxes = @()
    $checkBoxes = @()
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $pos_y = 20 + ($i * 30)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labels[$i]
        $lbl.Location = New-Object System.Drawing.Point(10, $pos_y)
        $lbl.Size = New-Object System.Drawing.Size(200, 20)
        $settingsForm.Controls.Add($lbl)

        if ($i -lt 6) {
            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Text = $thresholds[$labels[$i].Replace(" ", "_")]
            $tb.Location = New-Object System.Drawing.Point(210, $pos_y)
            $tb.Size = New-Object System.Drawing.Size(60, 20)
            $settingsForm.Controls.Add($tb)
            $textBoxes += $tb
        } elseif ($i -eq 6) {
            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Text = ($Refresh / 1000).ToString()
            $tb.Location = New-Object System.Drawing.Point(210, $pos_y)
            $tb.Size = New-Object System.Drawing.Size(60, 20)
            $settingsForm.Controls.Add($tb)
            $textBoxes += $tb
        } elseif ($i -ge 7) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = ""
            switch ($i) {
                7 { $cb.Checked = $showNotification }
                8 { $cb.Checked = $json.Darwin }
                9 { $cb.Checked = $json.BrowserCache }
            }
            $cb.Location = New-Object System.Drawing.Point(210, $pos_y)
            $cb.Size = New-Object System.Drawing.Size(20, 20)
            $settingsForm.Controls.Add($cb)
            $checkBoxes += $cb
        }
    }

    $latencyLabel = New-Object System.Windows.Forms.Label
    $latencyLabel.Text = "Latency check:"
    $latencyLabel.Location = New-Object System.Drawing.Point(300, 20)
    $latencyLabel.Size = New-Object System.Drawing.Size(180, 20)
    $settingsForm.Controls.Add($latencyLabel)

    $latencyTextBox = New-Object System.Windows.Forms.TextBox
    $latencyTextBox.Multiline = $true
    $latencyTextBox.ScrollBars = 'Vertical'
    $latencyTextBox.Location = New-Object System.Drawing.Point(300, 40)
    $latencyTextBox.Size = New-Object System.Drawing.Size(230, 270)
    # Pre-fill with current value
    $latencyTextBox.Text = ($LatencyServers | ConvertTo-Json -Depth 5)
    $settingsForm.Controls.Add($latencyTextBox)

    $textBoxes[0].Text = $thresholds.CPU_Usage
    $textBoxes[1].Text = $thresholds.Memory_Usage
    $textBoxes[2].Text = $thresholds.HDD_Usage
    $textBoxes[3].Text = $thresholds.WiFi_Signal
    $textBoxes[4].Text = $thresholds.Latency
    $textBoxes[5].Text = $thresholds.Battery

    # Save button
    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = "Save"
    $saveButton.Location = New-Object System.Drawing.Point(10, 320)
    $saveButton.Size = New-Object System.Drawing.Size(75, 23)
    $saveButton.Add_Click({
        try {
            # Validate and save settings
            $thresholds.CPU_Usage = [int]$textBoxes[0].Text
            $thresholds.Memory_Usage = [int]$textBoxes[1].Text
            $thresholds.HDD_Usage = [int]$textBoxes[2].Text
            $thresholds.WiFi_Signal = [int]$textBoxes[3].Text
            $thresholds.Latency = [int]$textBoxes[4].Text
            $thresholds.Battery = [int]$textBoxes[5].Text
            $Refresh = ([math]::max([int]$textBoxes[6].Text,10)) * 1000
            $showNotification = $checkBoxes[0].Checked
            $darwinVisible = $checkBoxes[1].Checked
            $browserVisible = $checkBoxes[2].Checked
            $latencyServersInput = $latencyTextBox.Text
            $LatencyServers = @()
            if ($latencyServersInput.Trim()) {
                $LatencyServers = $latencyServersInput | ConvertFrom-Json
            }

            # Save to config file
            $config = @{
                CPU_Usage = $thresholds.CPU_Usage
                Memory_Usage = $thresholds.Memory_Usage
                HDD_Usage = $thresholds.HDD_Usage
                WiFi_Signal = $thresholds.WiFi_Signal
                Latency = $thresholds.Latency
                Battery = $thresholds.Battery
                Refresh = ($Refresh / 1000)
                show_notification = $showNotification
                Darwin = $darwinVisible
                BrowserCache = $browserVisible
                LatencyServers = $LatencyServers
            }
            $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8

            # Update menu item visibility immediately
            $cacheItem.Visible = $darwinVisible
            $browserItem.Visible = $browserVisible

            # Update UI with new settings
            Update-MonitorUI

            # Close settings form
            $settingsForm.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Invalid input. Please enter valid numbers.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })
    $settingsForm.Controls.Add($saveButton)
    # Cancel button
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(100, 320)
    $cancelButton.Size = New-Object System.Drawing.Size(75, 23)
    $cancelButton.Add_Click({
        $settingsForm.Close()
    })
    $settingsForm.Controls.Add($cancelButton)
    # Show the settings form
    $settingsForm.ShowDialog() | Out-Null
})

$browserItem.Add_Click({
    # Clear Browser cache
    # Write a command to clear the Browser cache to the backend script
    $result = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to clear the browser cache?", "Clear Browser Cache", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        # Write command file for frontend to execute
        $commandFile = Join-Path $PSScriptRoot 'command.json'
        $command = @{
            Command = "ClearBrowserCache"
        }
        $command | ConvertTo-Json -Depth 5 | Set-Content -Path $commandFile -Encoding UTF8
        # Notify the backend to clear the browser cache
    }
}) 

$cacheItem.Add_Click({
    # Clear Darwin cache
    # Write a command to clear the Darwin cache to the backend script
    $result = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to clear the Darwin cache?", "Clear Darwin Cache", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        # Write command file for frontend to execute
        $commandFile = Join-Path $PSScriptRoot 'command.json'
        $command = @{
            Command = "ClearDarwinCache"
        }
        $command | ConvertTo-Json -Depth 5 | Set-Content -Path $commandFile -Encoding UTF8
        # Notify the backend to clear the Darwin cache
    }
})  

$form.Add_FormClosing({
})
 
# Click event on the battery icon
$batteryIconBox.Add_Click({
    # Generate Battery Report
    # Write a command to generate the Battery report to the backend script
    $result = [System.Windows.Forms.MessageBox]::Show("Generate a battery report?", "Battery Report", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        # Write command file for frontend to execute
        $commandFile = Join-Path $PSScriptRoot 'command.json'
        $command = @{
            Command = "GenerateBatteryReport"
        }
        $command | ConvertTo-Json -Depth 5 | Set-Content -Path $commandFile -Encoding UTF8
        # Notify the backend to generate the battery report
    }
})

# Replace the click event on the network icon
$networkIconBox.Add_Click({
    # Generate Battery Report
    # Write a command to generate the Battery report to the backend script
    $result = [System.Windows.Forms.MessageBox]::Show("Generate a network report?", "Network Report", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        # Write command file for frontend to execute
        $commandFile = Join-Path $PSScriptRoot 'command.json'
        $command = @{
            Command = "GenerateWiFiReport"
        }
        $command | ConvertTo-Json -Depth 5 | Set-Content -Path $commandFile -Encoding UTF8
        # Notify the backend to generate the WiFi report
    }
})

if ($showNotification) {
    $notifyIcon.ShowBalloonTip(1000, "System Monitor", "Right-click for options.", [System.Windows.Forms.ToolTipIcon]::Info)
}

# Timer to update progress bars and network icon
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $refresh
$timer.Add_Tick({
    Update-MonitorUI
})
# Immediately update UI before starting timer
Update-MonitorUI

# Start the timer
$timer.Start()

[System.Windows.Forms.Application]::Run()
