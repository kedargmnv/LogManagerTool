function Get-LogContent {
    param (
        [string]$Path,
        [nullable[datetime]]$StartDate,
        [nullable[datetime]]$EndDate
    )

    try {
        $archivePath = Join-Path -Path $Path -ChildPath "archive"
        
        $hasMainLogs = (Get-ChildItem -Path $Path -Include *.log, *.txt -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        $hasArchiveLogs = (Test-Path $archivePath) -and ((Get-ChildItem -Path $archivePath -Include *.log, *.txt, *.gz, *.zip, *.7z -Recurse -ErrorAction SilentlyContinue).Count -gt 0)
        
        if (-not ($hasMainLogs -or $hasArchiveLogs)) {
            [System.Windows.MessageBox]::Show("❌ No log files found in $Path") | Out-Null
            return
        }

        $logFiles = @()
        
        if ($hasMainLogs) {
            $mainLogs = Get-ChildItem -Path $Path -Include *.log, *.txt -Recurse | Where-Object {
                (-not $StartDate -or $_.LastWriteTime.Date -ge $StartDate) -and
                (-not $EndDate -or $_.LastWriteTime.Date -le $EndDate)
            }
            $logFiles += $mainLogs
        }
        
        if (Test-Path $archivePath) {
            $archiveLogs = Get-ChildItem -Path $archivePath -Include *.log, *.txt, *.gz, *.zip, *.7z -Recurse | Where-Object {
                $isDateMatch = $true
                
                if ($StartDate -or $EndDate) {
                    $fileDate = $null
                    
                    if ($_.Name -match 'Logs_(\d{8})') {
                        $dateString = $Matches[1]
                        try {
                            $year = [int]($dateString.Substring(0, 4))
                            $month = [int]($dateString.Substring(4, 2))
                            $day = [int]($dateString.Substring(6, 2))
                            $fileDate = New-Object DateTime $year, $month, $day
                        }
                        catch {
                            $fileDate = $_.LastWriteTime.Date
                        }
                    }
                    else {
                        $fileDate = $_.LastWriteTime.Date
                    }
                    
                    if ($StartDate -and $fileDate -lt $StartDate) {
                        $isDateMatch = $false
                    }
                    if ($EndDate -and $fileDate -gt $EndDate) {
                        $isDateMatch = $false
                    }
                }
                
                return $isDateMatch
            }
            $logFiles += $archiveLogs
        }
        
        if ($logFiles.Count -eq 0) {
            [System.Windows.MessageBox]::Show("No logs found matching the selected date range in $Path") | Out-Null
            return
        }
        
        $outputFile = [System.IO.Path]::GetTempFileName()
        $output = @()
        
        $output += "# Log Viewer Results"
        $output += "# Path: $Path"
        $output += "# Date Range: $(if ($StartDate) { $StartDate.ToString('yyyy-MM-dd') } else { 'Any' }) to $(if ($EndDate) { $EndDate.ToString('yyyy-MM-dd') } else { 'Any' })"
        $output += "# Generated: $(Get-Date)`n"

        foreach ($file in $logFiles) {
            try {
                if ($file.Extension -eq ".gz") {
                    $output += Show-ProcessGzFile -File $file.FullName
                }
                elseif ($file.Extension -eq ".7z") {
                    $output += Show-Process7zFile -File $file.FullName
                }
                elseif ($file.Extension -eq ".zip") {
                    $output += Show-ProcessZipFile -File $file.FullName
                }
                else {
                    $output += Show-ProcessNonCompressedFile -File $file.FullName
                }
            }
            catch {
                $output += "`n----- Error processing file: $($file.FullName) -----"
                $output += "  $_"
            }
        }

        $output | Out-File -FilePath $outputFile -Encoding UTF8
        Start-Process notepad.exe $outputFile
    }
    catch {
        [System.Windows.MessageBox]::Show("Error processing logs: $_") | Out-Null
    }
}

function Show-ProcessGzFile {
    param (
        [string]$File
    )

    $tempFile = "$File.tmp"
    $output = @()

    try {
        $fs = [System.IO.File]::OpenRead($File)
        $gzip = New-Object System.IO.Compression.GzipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
        $reader = New-Object System.IO.StreamReader($gzip)
        $content = $reader.ReadToEnd()
        $reader.Close()
        $gzip.Close()
        $fs.Close()

        $beautifiedContent = Format-LogContent -content $content
        Set-Content -Path $tempFile -Value $beautifiedContent

        $output += "`n----- $(Split-Path -Leaf $File) -----"
        $output += Get-Content $tempFile
    }
    catch {
        $output += "`n----- Error processing .gz file: $File -----"
        $output += "  $_"
    }
    finally {
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }

    return $output
}

function Show-Process7zFile {
    param (
        [string]$File
    )

    $output = @()
    $tempDir = Join-Path $env:TEMP "LogViewer7z_$(Get-Random)"
    
    try {
        $toolsDir = Join-Path $PSScriptRoot "tools"
        $sevenZipDir = Join-Path $toolsDir "7zip"
        $sevenZipExe = Join-Path $sevenZipDir "7za.exe"
        
        if (-not (Test-Path $sevenZipExe)) {
            $output += "`n----- 7-Zip not found. Cannot extract .7z file: $File -----"
            return $output
        }

        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        & $sevenZipExe x $File "-o$tempDir" -y | Out-Null
        
        Get-ChildItem -Path $tempDir -Recurse | ForEach-Object {
            $content = Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrEmpty($content)) { return }
            
            $beautifiedContent = Format-LogContent -content $content
            
            $output += "`n----- $(Split-Path -Leaf $File)\$(Split-Path -Leaf $_.FullName) -----"
            $output += $beautifiedContent
        }
    }
    catch {
        $output += "`n----- Error processing .7z file: $File -----"
        $output += "  $_"
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    return $output
}

function Show-ProcessZipFile {
    param (
        [string]$File
    )

    $output = @()
    $tempDir = Join-Path $env:TEMP "LogViewerZip_$(Get-Random)"
    
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        Expand-Archive -Path $File -DestinationPath $tempDir -Force
        
        Get-ChildItem -Path $tempDir -Recurse | ForEach-Object {
            $content = Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrEmpty($content)) { return }
            
            $beautifiedContent = Format-LogContent -content $content
            
            $output += "`n----- $(Split-Path -Leaf $File)\$(Split-Path -Leaf $_.FullName) -----"
            $output += $beautifiedContent
        }
    }
    catch {
        $output += "`n----- Error processing .zip file: $File -----"
        $output += "  $_"
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    return $output
}

function Show-ProcessNonCompressedFile {
    param (
        [string]$File
    )

    $output = @()

    try {
        $content = Get-Content -Path $File -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($content)) { return $output } 
        
        $beautifiedContent = Format-LogContent -content $content

        $output += "`n----- $(Split-Path -Leaf $File) -----"
        $output += $beautifiedContent
    }
    catch {
        $output += "`n----- Error processing file: $File -----"
        $output += "  $_"
    }

    return $output
}

function Format-LogContent {
    param([string]$content)
    
    if ([string]::IsNullOrEmpty($content)) {
        return ""
    }
    
    try {
        $content = $content -replace "\[I\]", "[INFO]"
        $content = $content -replace "\[E\]", "[ERROR]"
        $content = $content -replace "\[D\]", "[DEBUG]"
        $content = $content -replace "\[W\]", "[WARNING]"
        
        $content = $content -replace "\b(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\b", {
            $year = "20" + $_.Groups[1].Value
            $month = $_.Groups[2].Value
            $day = $_.Groups[3].Value
            $hour = $_.Groups[4].Value
            $min = $_.Groups[5].Value
            $sec = $_.Groups[6].Value
            "${year}-${month}-${day} ${hour}:${min}:${sec}"
        }
        
        $content = $content -replace "\s+\[RPT:(\d+)\]\s+Previous message repeated", {
            $count = $_.Groups[1].Value
            "`n--- Previous message repeated $count times ---"
        }
        
        $lines = $content -split "`n"
        $formattedLines = @()
        
        foreach ($line in $lines) {
            if ($line -match "^\[" -or $line -match "^---") {
                $formattedLines += $line
            }
            else {
                $formattedLines += "    $line"
            }
        }
        
        $content = $formattedLines -join "`n"
        
        return $content
    }
    catch {
        return $content
    }
}