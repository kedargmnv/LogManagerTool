. "$PSScriptRoot\CompressLogs.ps1"
. "$PSScriptRoot\ViewLogs.ps1"
. "$PSScriptRoot\SearchLogs.ps1"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

function Get-AvailableLogDates {
    param (
        [string]$Path
    )
    
    $availableDates = New-Object System.Collections.Generic.HashSet[datetime]
    
    try {
        Get-ChildItem -Path $Path -Include *.log, *.txt -Recurse | ForEach-Object {
            [void]$availableDates.Add($_.LastWriteTime.Date)
        }
        
        $archivePath = Join-Path -Path $Path -ChildPath "archive"
        if (Test-Path $archivePath) {
            $archiveFiles = Get-ChildItem -Path $archivePath -Include *.gz, *.7z, *.zip -Recurse
            
            foreach ($file in $archiveFiles) {
                if ($file.Name -match 'Logs_(\d{8})') {
                    $dateString = $Matches[1]
                    try {
                        $year = [int]($dateString.Substring(0, 4))
                        $month = [int]($dateString.Substring(4, 2))
                        $day = [int]($dateString.Substring(6, 2))
                        
                        $logDate = New-Object DateTime $year, $month, $day
                        [void]$availableDates.Add($logDate)
                    }
                    catch {
                        # Skip invalid date formats
                    }
                }
            }
        }
    }
    catch {
        [System.Windows.MessageBox]::Show("Error retrieving available log dates: $_") | Out-Null
    }
    
    return ($availableDates | Sort-Object)
}

function Update-DatePickerAvailableDates {
    param (
        [System.Windows.Controls.DatePicker]$DatePicker,
        [datetime[]]$AvailableDates,
        [bool]$IncludeToday = $true
    )
    
    $DatePicker.SelectedDate = $null
    $DatePicker.BlackoutDates.Clear()
    
    if ($AvailableDates.Count -eq 0) {
        $DatePicker.DisplayDateStart = (Get-Date).AddYears(-1)
        $DatePicker.DisplayDateEnd = (Get-Date)
        $DatePicker.SelectedDate = (Get-Date)
        return
    }
    
    $minDate = ($AvailableDates | Measure-Object -Minimum).Minimum
    $maxDate = if ($IncludeToday) { 
        [datetime]::Today 
    }
    else { 
        ($AvailableDates | Measure-Object -Maximum).Maximum
    }
    
    $DatePicker.DisplayDateStart = $minDate
    $DatePicker.DisplayDateEnd = $maxDate
    
    $current = $minDate
    while ($current -le $maxDate) {
        if (-not ($AvailableDates -contains $current) -and $current -ne [datetime]::Today) {
            $blackoutRange = New-Object System.Windows.Controls.CalendarDateRange $current, $current
            $DatePicker.BlackoutDates.Add($blackoutRange)
        }
        $current = $current.AddDays(1)
    }
    
    $recentDate = ($AvailableDates | Where-Object { $_ -le [datetime]::Today } | Sort-Object -Descending)[0]
    if ($recentDate) {
        $DatePicker.SelectedDate = $recentDate
    }
    else {
        $DatePicker.SelectedDate = [datetime]::Today
    }
}

[xml]$xaml = Get-Content "$PSScriptRoot\LogManagerGUI.xaml"
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$combo = $window.FindName("actionCombo")
$keywordBox = $window.FindName("keywordBox")
$folderPath = $window.FindName("folderPath")
$startDate = $window.FindName("startDate")
$endDate = $window.FindName("endDate")
$browseButton = $window.FindName("browseButton")
$runButton = $window.FindName("runButton")
$progressBar = $window.FindName("progressBar")
$exportButton = $window.FindName("exportButton")

$combo.Add_SelectionChanged({
        $action = $combo.SelectedItem.Content

        if ($action -eq "Compress Logs") {
            $keywordBox.IsEnabled = $false
            $keywordBox.Text = ""
            $startDate.IsEnabled = $false
            $endDate.IsEnabled = $false
        }
        elseif ($action -eq "View Logs") {
            $keywordBox.IsEnabled = $false
            $keywordBox.Text = ""
            $startDate.IsEnabled = $true
            $endDate.IsEnabled = $true
        
            if (-not [string]::IsNullOrWhiteSpace($folderPath.Text) -and (Test-Path $folderPath.Text)) {
                $progressBar.Value = 10
                $availableDates = Get-AvailableLogDates -Path $folderPath.Text
                Update-DatePickerAvailableDates -DatePicker $startDate -AvailableDates $availableDates
                Update-DatePickerAvailableDates -DatePicker $endDate -AvailableDates $availableDates
                $progressBar.Value = 0
            }
        }
        else {
            $keywordBox.IsEnabled = $true
            $startDate.IsEnabled = $true
            $endDate.IsEnabled = $true
        
            if (-not [string]::IsNullOrWhiteSpace($folderPath.Text) -and (Test-Path $folderPath.Text)) {
                $progressBar.Value = 10
                $availableDates = Get-AvailableLogDates -Path $folderPath.Text
                Update-DatePickerAvailableDates -DatePicker $startDate -AvailableDates $availableDates
                Update-DatePickerAvailableDates -DatePicker $endDate -AvailableDates $availableDates
                $progressBar.Value = 0
            } 
            else {
                $startDate.DisplayDateStart = (Get-Date).AddYears(-1)
                $startDate.DisplayDateEnd = (Get-Date)
                $startDate.SelectedDate = (Get-Date).AddDays(-7)
            
                $endDate.DisplayDateStart = (Get-Date).AddYears(-1)
                $endDate.DisplayDateEnd = (Get-Date)
                $endDate.SelectedDate = (Get-Date)
            }
        }
    })

$browseButton.Add_Click({
        try {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = "Select Logs Folder"
            $dialog.ShowNewFolderButton = $true
        
            if ($dialog.ShowDialog() -eq "OK") {
                $folderPath.Text = $dialog.SelectedPath
            
                $action = $combo.SelectedItem.Content
                if ($action -eq "View Logs" -or $action -eq "Search Logs") {
                    $progressBar.Value = 10
                    $availableDates = Get-AvailableLogDates -Path $dialog.SelectedPath
                    Update-DatePickerAvailableDates -DatePicker $startDate -AvailableDates $availableDates
                    Update-DatePickerAvailableDates -DatePicker $endDate -AvailableDates $availableDates
                    $progressBar.Value = 0
                }
            }
        }
        catch {
            [System.Windows.MessageBox]::Show("Error selecting folder: $_") | Out-Null
        }
    })

$exportButton.Add_Click({
        try {
            $exportDialog = New-Object System.Windows.Forms.SaveFileDialog
            $exportDialog.Filter = "Zip Files (*.zip)|*.zip"
            if ($exportDialog.ShowDialog() -eq "OK") {
                $destination = $exportDialog.FileName
                $exportLogs = Get-ChildItem -Path $folderPath.Text -Include *.log, *.txt -Recurse | Where-Object {
                    $_.LastWriteTime.Date -ge $startDate.SelectedDate -and 
                    $_.LastWriteTime.Date -le $endDate.SelectedDate -and 
                ($_ | Select-String -Pattern $keywordBox.Text -Quiet)
                }
                if ($exportLogs.Count -gt 0) {
                    Compress-Archive -Path $exportLogs.FullName -DestinationPath $destination -Force
                    [System.Windows.MessageBox]::Show("Filtered logs exported to $destination") | Out-Null
                }
                else {
                    [System.Windows.MessageBox]::Show("No logs matched for export.") | Out-Null
                }
            }
        }
        catch {
            [System.Windows.MessageBox]::Show("Error exporting logs: $_") | Out-Null
        }
    })


$runButton.Add_Click({
        try {
            $action = $combo.SelectedItem.Content
            $folder = $folderPath.Text.Trim()
            $start = $startDate.SelectedDate
            $end = $endDate.SelectedDate

            if ([string]::IsNullOrWhiteSpace($folder)) {
                [System.Windows.MessageBox]::Show("Please enter a folder path.", "Missing Path", "OK", "Warning") | Out-Null
                $folderPath.Focus()
                return
            }

            if (-not (Test-Path $folder)) {
                [System.Windows.MessageBox]::Show("The specified folder path does not exist. Please select a valid folder.", "Invalid Path", "OK", "Warning") | Out-Null
                $folderPath.Focus()
                return
            }

            $progressBar.Value = 10
            $statusText.Text = "Running $action..."

            switch ($action) {
                "Compress Logs" {
                    $progressBar.Value = 10
                    $statusText.Text = "Starting log compression..."
                
                    $job = Start-Job -ScriptBlock {
                        param($ScriptRoot, $Folder)
                        . "$ScriptRoot\CompressLogs.ps1"
                    
                        Compress-OldLogs -Path $Folder -Days 3 -EnableRotation -BatchSize 50
                    } -ArgumentList $PSScriptRoot, $folder
                
                    $timer = New-Object System.Windows.Forms.Timer
                    $timer.Interval = 500
                    $timer.Add_Tick({
                            if ($job.State -eq "Completed") {
                                $timer.Stop()
                        
                                Receive-Job -Job $job | Out-Null
                        
                                $progressBar.Value = 100
                                $statusText.Text = "Compression completed successfully."
                        
                                Remove-Job -Job $job
                        
                                $availableDates = Get-AvailableLogDates -Path $folder
                                Update-DatePickerAvailableDates -DatePicker $startDate -AvailableDates $availableDates
                                Update-DatePickerAvailableDates -DatePicker $endDate -AvailableDates $availableDates
                        
                                Start-Sleep -Seconds 2
                                $progressBar.Value = 0
                            }
                            elseif ($job.State -eq "Failed") {
                                $timer.Stop()
                        
                                $jobErrors = Receive-Job -Job $job -ErrorAction SilentlyContinue
                                [System.Windows.MessageBox]::Show("Error compressing logs: $jobErrors") | Out-Null
                        
                                Remove-Job -Job $job
                                $progressBar.Value = 0
                                $statusText.Text = "Error: Compression failed."
                            }
                            else {
                                if ($progressBar.Value -lt 80) {
                                    $progressBar.Value += 1
                                }
                                $statusText.Text = "Compressing logs... (Job Running)"
                            }
                        })
                
                    $timer.Start()
                    return
                }
            
                "View Logs" {
                    $progressBar.Value = 30
                    $statusText.Text = "Opening log viewer..."
                    Get-LogContent -Path $folder -StartDate $start -EndDate $end
                    $progressBar.Value = 90
                    $statusText.Text = "Log viewer opened successfully."
                }
            
                "Search Logs" {
                    $keyword = $keywordBox.Text.Trim()
                
                    if ([string]::IsNullOrWhiteSpace($keyword)) {
                        [System.Windows.MessageBox]::Show("Keyword is required for searching logs.", "Required Field", "OK", "Information") | Out-Null
                        $keywordBox.Focus()
                        $progressBar.Value = 0
                        $statusText.Text = "Search requires a keyword."
                        return
                    }
                
                    $progressBar.Value = 30
                    $statusText.Text = "Searching logs for '$keyword'..."
                    Search-LogsByKeyword -Path $folder -Keyword $keyword -StartDate $start -EndDate $end
                    $progressBar.Value = 90
                    $statusText.Text = "Search completed successfully."
                }
            
                default {
                    [System.Windows.MessageBox]::Show("Please select a valid action.") | Out-Null
                }
            }

            $progressBar.Value = 100
        }
        catch {
            [System.Windows.MessageBox]::Show("Error running action: $_") | Out-Null
            $progressBar.Value = 0
            $statusText.Text = "Error: $_"
        }
        finally {
            if ($action -ne "Compress Logs") {
                Start-Sleep -Seconds 2
                $progressBar.Value = 0
            }
        }
    })

$combo.SelectedIndex = 0
$progressBar.Value = 0

$startDate.SelectedDate = (Get-Date).AddDays(-7)
$endDate.SelectedDate = (Get-Date)

$window.ShowDialog() | Out-Null