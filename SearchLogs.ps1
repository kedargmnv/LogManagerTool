function Search-LogsByKeyword {
    param (
        [string]$Path,
        [string]$Keyword,
        [nullable[datetime]]$StartDate,
        [nullable[datetime]]$EndDate
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Keyword)) {
            [System.Windows.MessageBox]::Show("Keyword is required for searching logs.", "Required Field", "OK", "Information") | Out-Null
            return
        }

        $resultsFound = $false
        $outputFile = [System.IO.Path]::GetTempFileName()
        $output = @()
        $output += "# Search Results for: '$Keyword' in $Path"
        $output += "# Date Range: $(if ($StartDate) { $StartDate.ToString('yyyy-MM-dd') } else { 'Any' }) to $(if ($EndDate) { $EndDate.ToString('yyyy-MM-dd') } else { 'Any' })"
        $output += "# $(Get-Date)`n"

        Get-ChildItem -Path $Path -Include *.log, *.txt, *.gz, *.zip, *.7z -Recurse -ErrorAction SilentlyContinue | Where-Object {
            $isDateMatch = $true
            
            # Apply date filtering based on filename pattern (Logs_YYYYMMDD) or last write time
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
                        # If filename date parsing fails, use LastWriteTime
                        $fileDate = $_.LastWriteTime.Date
                    }
                }
                else {
                    # No date in filename, use LastWriteTime
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
        } | ForEach-Object {
            try {
                $output += Search-ProcessFile -File $_.FullName -Keyword $Keyword -ResultsFound ([ref]$resultsFound)
            }
            catch {
                $output += "`n## Error processing file: $($_.FullName)"
                $output += "  $_"
            }
        }

        $output | Out-File -FilePath $outputFile -Encoding UTF8
        Start-Process notepad.exe $outputFile

        if (-not $resultsFound) {
            [System.Windows.MessageBox]::Show("No matches found for '$Keyword' in $Path in the selected date range.") | Out-Null
        }
    }
    catch {
        [System.Windows.MessageBox]::Show("Error searching logs: $_") | Out-Null
    }
}

function Search-ProcessFile {
    param (
        [string]$File,
        [string]$Keyword,
        [ref]$ResultsFound
    )

    $output = @()
    
    switch ([System.IO.Path]::GetExtension($File).ToLower()) {
        ".gz" {
            $output += Search-ProcessGzFile -File $File -Keyword $Keyword -ResultsFound $ResultsFound
        }
        ".7z" {
            $output += Search-Process7zFile -File $File -Keyword $Keyword -ResultsFound $ResultsFound
        }
        ".zip" {
            $output += Search-ProcessZipFile -File $File -Keyword $Keyword -ResultsFound $ResultsFound
        }
        default {
            $output += Search-ProcessNonCompressedFile -File $File -Keyword $Keyword -ResultsFound $ResultsFound
        }
    }

    return $output
}

function Search-ProcessGzFile {
    param (
        [string]$File,
        [string]$Keyword,
        [ref]$ResultsFound
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

        $beautifiedContent = Search-FormatLogContent -content $content
        Set-Content -Path $tempFile -Value $beautifiedContent

        try {
            $filteredMatches = Select-String -Path $tempFile -Pattern $Keyword -SimpleMatch -ErrorAction Stop
            if ($filteredMatches) {
                $ResultsFound.Value = $true
                $output += "`n## Matches found in: $(Split-Path -Leaf $File)"
                
                foreach ($match in $filteredMatches) {
                    $output += "Line $($match.LineNumber): $($match.Line)"
                }
            }
        }
        catch {
            if ($_.Exception.Message -like "*Cannot bind argument to parameter 'Pattern'*") {
                $output += "`n## Error with search pattern in file: $(Split-Path -Leaf $File)"
            }
            else {
                throw
            }
        }
    }
    catch {
        $output += "`n## Error processing .gz file: $File"
        $output += "  $_"
    }
    finally {
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }

    return $output
}

function Search-Process7zFile {
    param (
        [string]$File,
        [string]$Keyword,
        [ref]$ResultsFound
    )

    $output = @()
    $tempDir = Join-Path $env:TEMP "LogSearch7z_$(Get-Random)"
    
    try {
        $toolsDir = Join-Path $PSScriptRoot "tools"
        $sevenZipDir = Join-Path $toolsDir "7zip"
        $sevenZipExe = Join-Path $sevenZipDir "7za.exe"
        
        if (-not (Test-Path $sevenZipExe)) {
            $output += "`n## Warning: 7-Zip not found. Cannot extract .7z file: $File"
            return $output
        }

        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        & $sevenZipExe x $File "-o$tempDir" -y | Out-Null
        
        Get-ChildItem -Path $tempDir -Recurse | ForEach-Object {
            $content = Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrEmpty($content)) { return } # Skip empty files
            
            $beautifiedContent = Search-FormatLogContent -content $content
            
            try {
                $filteredMatches = $beautifiedContent | Select-String -Pattern $Keyword -SimpleMatch -ErrorAction Stop
                if ($filteredMatches) {
                    $ResultsFound.Value = $true
                    $output += "`n## Matches found in: $(Split-Path -Leaf $File)\$(Split-Path -Leaf $_.FullName)"
                    
                    foreach ($match in $filteredMatches) {
                        $output += "Line $($match.LineNumber): $($match.Line)"
                    }
                }
            }
            catch {
                if ($_.Exception.Message -like "*Cannot bind argument to parameter 'Pattern'*") {
                    $output += "`n## Error with search pattern in file: $(Split-Path -Leaf $File)\$(Split-Path -Leaf $_.FullName)"
                }
                else {
                    throw
                }
            }
        }
    }
    catch {
        $output += "`n## Error processing .7z file: $File"
        $output += "  $_"
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    return $output
}

function Search-ProcessZipFile {
    param (
        [string]$File,
        [string]$Keyword,
        [ref]$ResultsFound
    )

    $output = @()
    $tempDir = Join-Path $env:TEMP "LogSearchZip_$(Get-Random)"
    
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        Expand-Archive -Path $File -DestinationPath $tempDir -Force
        
        Get-ChildItem -Path $tempDir -Recurse | ForEach-Object {
            $content = Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrEmpty($content)) { return }
            
            $beautifiedContent = Search-FormatLogContent -content $content
            
            try {
                $filteredMatches = $beautifiedContent | Select-String -Pattern $Keyword -SimpleMatch -ErrorAction Stop
                if ($filteredMatches) {
                    $ResultsFound.Value = $true
                    $output += "`n## Matches found in: $(Split-Path -Leaf $File)\$(Split-Path -Leaf $_.FullName)"
                    
                    foreach ($match in $filteredMatches) {
                        $output += "Line $($match.LineNumber): $($match.Line)"
                    }
                }
            }
            catch {
                if ($_.Exception.Message -like "*Cannot bind argument to parameter 'Pattern'*") {
                    $output += "`n## Error with search pattern in file: $(Split-Path -Leaf $File)\$(Split-Path -Leaf $_.FullName)"
                }
                else {
                    throw
                }
            }
        }
    }
    catch {
        $output += "`n## Error processing .zip file: $File"
        $output += "  $_"
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    return $output
}

function Search-ProcessNonCompressedFile {
    param (
        [string]$File,
        [string]$Keyword,
        [ref]$ResultsFound
    )

    $output = @()

    try {
        $content = Get-Content -Path $File -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($content)) { return $output }
        
        $beautifiedContent = Search-FormatLogContent -content $content

        try {
            $filteredMatches = $beautifiedContent | Select-String -Pattern $Keyword -SimpleMatch -ErrorAction Stop
            if ($filteredMatches) {
                $ResultsFound.Value = $true
                $output += "`n## Matches found in: $(Split-Path -Leaf $File)"
                
                foreach ($match in $filteredMatches) {
                    $output += "Line $($match.LineNumber): $($match.Line)"
                }
            }
        }
        catch {
            if ($_.Exception.Message -like "*Cannot bind argument to parameter 'Pattern'*") {
                $output += "`n## Error with search pattern in file: $(Split-Path -Leaf $File)"
            }
            else {
                throw
            }
        }
    }
    catch {
        $output += "`n## Error processing file: $File"
        $output += "  $_"
    }

    return $output
}

function Search-FormatLogContent {
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
        
        return $content
    }
    catch {
        return $content
    }
}