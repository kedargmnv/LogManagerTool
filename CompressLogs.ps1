function Compress-LogContent {
    param(
        [string]$content,
        [switch]$PreserveTimestamps = $false
    )
    
    if ([string]::IsNullOrEmpty($content)) {
        return ""
    }
    
    try {
        $content = $content -replace "\[INFO\]|\[INFORMATION\]", "[I]"
        $content = $content -replace "\[ERROR\]|\[ERR\]", "[E]"
        $content = $content -replace "\[DEBUG\]", "[D]"
        $content = $content -replace "\[WARNING\]|\[WARN\]", "[W]"
        
        $content = $content -replace "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z", {
            $dt = [datetime]::Parse($_.Value)
            return $dt.ToString("yyMMddHHmmss")
        }
        
        $lines = $content -split "`n"
        $uniqueLines = @()
        $prevLine = $null
        $dupeCount = 0
        
        foreach ($line in $lines) {
            $lineForComparison = if ($PreserveTimestamps) {
                $line -replace "^\[\d{2}\d{2}\d{2}\d{2}\d{2}\d{2}\]|^\[\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\]", ""
            }
            else {
                $line
            }
            
            $prevLineForComparison = if ($PreserveTimestamps -and $prevLine) {
                $prevLine -replace "^\[\d{2}\d{2}\d{2}\d{2}\d{2}\d{2}\]|^\[\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\]", ""
            }
            else {
                $prevLine
            }
            
            if ($lineForComparison -ne $prevLineForComparison) {
                # If we had duplicates, add a count message
                if ($dupeCount -gt 0) {
                    $uniqueLines += "    [RPT:$dupeCount] Previous message repeated"
                    $dupeCount = 0
                }
                $uniqueLines += $line
                $prevLine = $line
            }
            else {
                $dupeCount++
            }
        }
        
        # Handle final duplicate count
        if ($dupeCount -gt 0) {
            $uniqueLines += "    [RPT:$dupeCount] Previous message repeated"
        }
        
        $content = $uniqueLines -join "`n"
        
        # Remove excess whitespace
        $content = $content -replace "\s{2,}", " "
        
        return $content.Trim()
    }
    catch {
        return $content
    }
}

function Initialize-BundledTools {
    param(
        [switch]$Force
    )
    
    try {
        $toolsDir = Join-Path $PSScriptRoot "tools"
        $sevenZipDir = Join-Path $toolsDir "7zip"
        $sevenZipExe = Join-Path $sevenZipDir "7za.exe"
        
        if (-not (Test-Path $toolsDir)) {
            New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
        }
        
        # Check for 7-Zip portable, download if not present or forced
        if ($Force -or -not (Test-Path $sevenZipExe)) {
            try {
                $tempFile = Join-Path $env:TEMP "7za920.zip"
                $client = New-Object System.Net.WebClient
                
                Write-Host "Downloading portable 7-Zip..." -ForegroundColor Cyan

                $client.DownloadFile("https://www.7-zip.org/a/7za920.zip", $tempFile)
                
                if (-not (Test-Path $sevenZipDir)) {
                    New-Item -ItemType Directory -Path $sevenZipDir -Force | Out-Null
                }
                
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($tempFile, $sevenZipDir)
                
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                
                if (Test-Path $sevenZipExe) {
                    Write-Host "7-Zip portable installed successfully." -ForegroundColor Green
                    return $true
                }
                else {
                    Write-Host "Failed to locate 7za.exe after extraction." -ForegroundColor Red
                    return $false
                }

            }
            catch {
                Write-Host "Failed to download or extract 7-Zip: $_" -ForegroundColor Red
                return $false
            }
            finally {
                if ($client) { $client.Dispose() }
            }
        }
        else {
            return $true
        }
    }
    catch {
        Write-Host "Error initializing tools: $_" -ForegroundColor Red
        return $false
    }
}

function Compress-OldLogs {
    param (
        [string]$Path,
        [int]$Days = 3,
        [ValidateSet("7Zip", "GZip", "Auto")]
        [string]$Method = "Auto",
        [bool]$BatchByDate = $true,
        [switch]$EnableRotation,
        [int]$RotationArchiveDays = 30,
        [int]$RotationDeleteDays = 90,
        [int]$BatchSize = 50 
    )

    try {
        $archivePath = Join-Path -Path $Path -ChildPath "archive"
        if (-not (Test-Path $archivePath)) {
            New-Item -ItemType Directory -Path $archivePath | Out-Null
        }
        
        $existingArchives = Get-ChildItem -Path $archivePath -Include *.gz, *.7z, *.zip -Recurse
        
        $toolsDir = Join-Path $PSScriptRoot "tools"
        $sevenZipDir = Join-Path $toolsDir "7zip"
        $sevenZipExe = Join-Path $sevenZipDir "7za.exe"
        
        $use7Zip = $false
        if ($Method -eq "7Zip" -or $Method -eq "Auto") {
            if (Test-Path $sevenZipExe) {
                $use7Zip = $true
            }
            elseif ($Method -eq "7Zip") {
                $use7Zip = Initialize-BundledTools
                if (-not $use7Zip) {
                    Write-Host "7-Zip requested but unavailable. Falling back to GZip." -ForegroundColor Yellow
                }
            }
        }
        
        # Log rotation - delete very old archives if enabled
        $deletedArchives = New-Object System.Collections.ArrayList
        if ($EnableRotation) {
            $oldArchives = Get-ChildItem -Path $archivePath -Include *.gz, *.7z, *.zip -Recurse | Where-Object {
                $_.LastWriteTime -lt (Get-Date).AddDays(-$RotationDeleteDays)
            } 
            
            $totalToDelete = $oldArchives.Count
            if ($totalToDelete -gt 0) {
                Write-Host "Cleaning up $totalToDelete old archives..." -ForegroundColor Cyan
                $counter = 0
                foreach ($archive in $oldArchives) {
                    [void]$deletedArchives.Add($archive)
                    Remove-Item $archive.FullName -Force
                    
                    $counter++
                    if ($counter % 20 -eq 0) {
                        # Update progress every 20 files
                        Write-Progress -Activity "Deleting old archives" -Status "Processed: $counter of $totalToDelete" -PercentComplete (($counter / $totalToDelete) * 100)
                    }
                }
                Write-Progress -Activity "Deleting old archives" -Completed
            }
            
            if ($deletedArchives.Count -gt 0) {
                $deletedSize = ($deletedArchives | Measure-Object -Property Length -Sum).Sum
                $deletedSizeMB = [math]::Round($deletedSize / 1MB, 2)
                Write-Host "Deleted $($deletedArchives.Count) old archives ($deletedSizeMB MB)" -ForegroundColor Green
            }
        }
        
        $logsToCompress = Get-ChildItem -Path $Path -Include *.log, *.txt -Recurse | Where-Object {
            $_.LastWriteTime -lt (Get-Date).AddDays(-$Days) -and
            $_.Extension -ne ".gz" -and $_.Extension -ne ".7z" -and
            -not (Test-Path (Join-Path $archivePath "$($_.BaseName).7z")) -and
            -not (Test-Path (Join-Path $archivePath "$($_.Name).gz"))
        }

        if ($logsToCompress.Count -eq 0) {
            Write-Host "No new logs to compress." -ForegroundColor Yellow
            return
        }

        $initialSize = ($logsToCompress | Measure-Object -Property Length -Sum).Sum
        $initialSizeMB = [math]::Round($initialSize / 1MB, 2)
        Write-Host "Found $($logsToCompress.Count) files to compress ($initialSizeMB MB)" -ForegroundColor Cyan
        
        $createdArchives = New-Object System.Collections.ArrayList
        $totalProcessed = 0
        
        if ($BatchByDate -and $logsToCompress.Count -gt 1) {
            $logGroups = $logsToCompress | Group-Object { $_.LastWriteTime.ToString("yyyyMMdd") }
            $totalGroups = $logGroups.Count
            $groupCounter = 0
            
            foreach ($group in $logGroups) {
                $groupCounter++
                $dateStr = $group.Name
                Write-Progress -Activity "Compressing logs by date" -Status "Group $groupCounter of $totalGroups ($dateStr)" -PercentComplete (($groupCounter / $totalGroups) * 100)
                
                if ($group.Count -gt $BatchSize) {
                    Write-Host "Processing large group from $dateStr ($($group.Count) files) in smaller batches..." -ForegroundColor Yellow
                    $subBatches = [Math]::Ceiling($group.Count / $BatchSize)
                    
                    for ($i = 0; $i -lt $subBatches; $i++) {
                        $batchStart = $i * $BatchSize
                        $batchEnd = [Math]::Min(($i + 1) * $BatchSize, $group.Count) - 1
                        $batchFiles = $group.Group[$batchStart..$batchEnd]
                        
                        Write-Host "  Processing sub-batch $($i+1) of $subBatches ($($batchFiles.Count) files)" -ForegroundColor Cyan
                        
                        $archiveFile = Join-Path $archivePath "Logs_${dateStr}_batch$($i+1)of$subBatches"
                        if ($use7Zip) {
                            $archiveFile += ".7z"
                        }
                        else {
                            $archiveFile += ".zip"
                        }
                        
                        $newArchive = Invoke-BatchFiles -Files $batchFiles -ArchiveFile $archiveFile -Use7Zip:$use7Zip -SevenZipExe $sevenZipExe
                        if ($newArchive) {
                            [void]$createdArchives.Add($newArchive)
                            $totalProcessed += $batchFiles.Count
                        }
                    }
                }
                elseif ($group.Count -gt 1) {
                    if ($use7Zip) {
                        $archiveFile = Join-Path $archivePath "Logs_${dateStr}.7z"
                    }
                    else {
                        $archiveFile = Join-Path $archivePath "Logs_${dateStr}.zip"
                    }
                    
                    $archiveCounter = 1
                    while (Test-Path $archiveFile) {
                        if ($use7Zip) {
                            $archiveFile = Join-Path $archivePath "Logs_${dateStr}_batch$archiveCounter.7z"
                        }
                        else {
                            $archiveFile = Join-Path $archivePath "Logs_${dateStr}_batch$archiveCounter.zip"
                        }
                        $archiveCounter++
                    }
                    
                    $newArchive = Invoke-BatchFiles -Files $group.Group -ArchiveFile $archiveFile -Use7Zip:$use7Zip -SevenZipExe $sevenZipExe
                    if ($newArchive) {
                        [void]$createdArchives.Add($newArchive)
                        $totalProcessed += $group.Count
                    }
                }
                else {
                    $file = $group.Group[0]
                    $newArchive = Compress-SingleLogFile -File $file -ArchivePath $archivePath -Use7Zip:$use7Zip -SevenZipExe $sevenZipExe -ExistingArchives $existingArchives -Silent
                    if ($newArchive) {
                        [void]$createdArchives.Add($newArchive)
                        $totalProcessed++
                    }
                }
            }
            
            Write-Progress -Activity "Compressing logs by date" -Completed
        }
        else {
            $totalFiles = $logsToCompress.Count
            $counter = 0
            
            foreach ($file in $logsToCompress) {
                $counter++
                if ($counter % 10 -eq 0 -or $counter -eq 1 -or $counter -eq $totalFiles) {
                    Write-Progress -Activity "Compressing individual log files" -Status "Processing file $counter of $totalFiles" -PercentComplete (($counter / $totalFiles) * 100)
                }
                
                $newArchive = Compress-SingleLogFile -File $file -ArchivePath $archivePath -Use7Zip:$use7Zip -SevenZipExe $sevenZipExe -ExistingArchives $existingArchives -Silent
                if ($newArchive) {
                    [void]$createdArchives.Add($newArchive)
                    $totalProcessed++
                }
            }
            
            Write-Progress -Activity "Compressing individual log files" -Completed
        }

        $finalSize = ($createdArchives | Measure-Object -Property Length -Sum).Sum
        $finalSizeMB = [math]::Round($finalSize / 1MB, 2)
        
        $savedSize = $initialSize - $finalSize
        $savedSizeMB = [math]::Round($savedSize / 1MB, 2)
        $percentageSaved = if ($initialSize -gt 0) { 
            [math]::Round(($savedSize / $initialSize) * 100, 1)
        }
        else {
            0
        }
        
        $allCurrentArchives = Get-ChildItem -Path $archivePath -Include *.gz, *.7z, *.zip -Recurse
        $totalArchiveSize = ($allCurrentArchives | Measure-Object -Property Length -Sum).Sum
        $totalArchiveSizeMB = [math]::Round($totalArchiveSize / 1MB, 2)
        
        $summary = "✅ Compression Complete`n`n" +
        "This session:`n" +
        "  Original Size: $initialSizeMB MB`n" +
        "  Compressed Size: $finalSizeMB MB`n" +
        "  Space Saved: $savedSizeMB MB ($percentageSaved%)`n" +
        "  Files Compressed: $totalProcessed`n" +
        "  Archives Created: $($createdArchives.Count)`n`n" +
        "Archive Status:`n" +
        "  Total Archives: $($allCurrentArchives.Count)`n" +
        "  Total Size: $totalArchiveSizeMB MB"
        
        Write-Host $summary -ForegroundColor Green
        [System.Windows.MessageBox]::Show($summary) | Out-Null
    }
    catch {
        Write-Host "Error compressing logs: $_" -ForegroundColor Red
        [System.Windows.MessageBox]::Show("Error compressing logs: $_") | Out-Null
    }
}

function Invoke-BatchFiles {
    param (
        [System.IO.FileInfo[]]$Files,
        [string]$ArchiveFile,
        [bool]$Use7Zip = $false,
        [string]$SevenZipExe = $null
    )
    
    try {
        $tempDir = Join-Path $env:TEMP "LogsTempCompress_$(Get-Random)"
        
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        $totalFiles = $Files.Count
        $processedFiles = 0
        
        Write-Host "Processing $totalFiles files for batch compression to $ArchiveFile" -ForegroundColor Cyan
        
        foreach ($file in $Files) {
            $processedFiles++
            if ($processedFiles % 20 -eq 0 -or $processedFiles -eq 1 -or $processedFiles -eq $totalFiles) {
                Write-Progress -Activity "Preprocessing files for batch compression" -Status "File $processedFiles of $totalFiles" -PercentComplete (($processedFiles / $totalFiles) * 100)
            }
            
            $content = Get-Content -Path $file.FullName -Raw
            $minifiedContent = Compress-LogContent -content $content
            $tempFile = Join-Path $tempDir $file.Name
            Set-Content -Path $tempFile -Value $minifiedContent -Force
        }
        
        Write-Progress -Activity "Preprocessing files" -Completed
        
        if ($Use7Zip -and (Test-Path $SevenZipExe)) {
            Write-Host "Compressing batch with 7-Zip..." -ForegroundColor Cyan
            & $SevenZipExe a -t7z -mx=9 $ArchiveFile "$tempDir\*" | Out-Null
        }
        else {
            Write-Host "Compressing batch with ZIP..." -ForegroundColor Cyan
            Compress-Archive -Path "$tempDir\*" -DestinationPath $ArchiveFile -Force
        }
        
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        
        foreach ($file in $Files) {
            Remove-Item $file.FullName -Force
        }
        
        Write-Host "Successfully created archive: $ArchiveFile" -ForegroundColor Green
        return Get-Item $ArchiveFile
    }
    catch {
        Write-Host "Error in batch compression: $_" -ForegroundColor Red
        return $null
    }
}

function Compress-SingleLogFile {
    param (
        [System.IO.FileInfo]$File,
        [string]$ArchivePath,
        [bool]$Use7Zip = $false,
        [string]$SevenZipExe = $null,
        [System.IO.FileInfo[]]$ExistingArchives = @(),
        [switch]$Silent = $false
    )
    
    try {
        $originalFile = $File.FullName
        
        $baseNameMatch = $ExistingArchives | Where-Object { $_.BaseName -eq $File.BaseName }
        $fullNameMatch = $ExistingArchives | Where-Object { $_.BaseName -eq $File.Name }
        
        if ($baseNameMatch -or $fullNameMatch) {
            return $null
        }
        
        $logDate = $File.LastWriteTime.ToString("yyyyMMdd")
        
        $content = Get-Content -Path $originalFile -Raw
        $minifiedContent = Compress-LogContent -content $content
        $tempFile = "$originalFile.tmp"
        Set-Content -Path $tempFile -Value $minifiedContent -Force
        
        if ($Use7Zip -and (Test-Path $SevenZipExe)) {
            $compressedFile = Join-Path $ArchivePath "Logs_${logDate}_$($File.BaseName).7z"
            
            $counter = 1
            while (Test-Path $compressedFile) {
                $compressedFile = Join-Path $ArchivePath "Logs_${logDate}_$($File.BaseName)_$counter.7z"
                $counter++
            }
            
            & $SevenZipExe a -t7z -mx=9 $compressedFile $tempFile | Out-Null
            
            Remove-Item $tempFile -Force
            Remove-Item $originalFile -Force
            
            if (-not $Silent) {
                Write-Host "✅ Compressed with 7-Zip: $($File.Name) -> $(Split-Path -Leaf $compressedFile)" -ForegroundColor Green
            }
            
            return Get-Item $compressedFile
        }
        else {
            $compressedFile = Join-Path $ArchivePath "Logs_${logDate}_$($File.BaseName).gz"
            
            $counter = 1
            while (Test-Path $compressedFile) {
                $compressedFile = Join-Path $ArchivePath "Logs_${logDate}_$($File.BaseName)_$counter.gz"
                $counter++
            }
            
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($minifiedContent)
            
            $targetStream = [System.IO.File]::Create($compressedFile)
            $gzipStream = New-Object System.IO.Compression.GzipStream($targetStream, [System.IO.Compression.CompressionMode]::Compress)
            
            $gzipStream.Write($bytes, 0, $bytes.Length)
            
            $gzipStream.Close()
            $targetStream.Close()
            
            Remove-Item $tempFile -Force
            Remove-Item $originalFile -Force
            
            if (-not $Silent) {
                Write-Host "✅ Compressed with GZip: $($File.Name) -> $(Split-Path -Leaf $compressedFile)" -ForegroundColor Green
            }
            
            return Get-Item $compressedFile
        }
    }
    catch {
        Write-Host "Error compressing file $($File.Name): $_" -ForegroundColor Red
        if (-not $Silent) {
            [System.Windows.MessageBox]::Show("Error compressing file $($File.FullName): $_") | Out-Null
        }
        return $null
    }
}

Initialize-BundledTools | Out-Null