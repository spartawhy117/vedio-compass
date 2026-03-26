Set-StrictMode -Version Latest

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$LocalFileName
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $localPath = Join-Path -Path $PSScriptRoot -ChildPath $LocalFileName
    if (Test-Path -LiteralPath $localPath) {
        return $localPath
    }

    throw "Cannot find $CommandName. Add it to PATH or put $LocalFileName next to this script."
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Path $Path)
    }
}

function Format-Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Bytes
    )

    $units = @("B", "KB", "MB", "GB", "TB")
    $size = [double]$Bytes
    $unitIndex = 0

    while ($size -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $size /= 1024
        $unitIndex++
    }

    return ("{0:N2} {1}" -f $size, $units[$unitIndex])
}

function Get-SumOrZero {
    param(
        [AllowEmptyCollection()]
        [object[]]$Items = @(),

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    $measure = $Items | Measure-Object -Property $PropertyName -Sum
    if ($measure -and $measure.PSObject.Properties.Match("Sum").Count -gt 0 -and $null -ne $measure.Sum) {
        return [double]$measure.Sum
    }

    return 0.0
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $escapedArguments = $Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '(\\*)"', '$1$1\"') + '"'
        } else {
            $_
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($escapedArguments -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Get-VideoProbeData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProbePath,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $probeArgs = @(
        "-v", "error"
        "-show_entries", "stream=index,codec_type,codec_name,bit_rate:format=duration,size,bit_rate"
        "-of", "json"
        $FilePath
    )

    $probeResult = Invoke-ProcessCapture -FilePath $ProbePath -Arguments $probeArgs
    if ($probeResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($probeResult.StdOut)) {
        return $null
    }

    return ($probeResult.StdOut | ConvertFrom-Json)
}

function Get-VideoInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProbePath,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $probe = Get-VideoProbeData -ProbePath $ProbePath -FilePath $FilePath
    if (-not $probe) {
        return $null
    }

    $streams = @($probe.streams)
    $format = $probe.format
    $videoStream = $streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    if (-not $videoStream) {
        return $null
    }

    $audioStream = $streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    $durationSec = 0.0
    if ($format.PSObject.Properties.Match("duration").Count -gt 0 -and $format.duration) {
        $durationSec = [double]$format.duration
    }

    $fileSizeBytes = 0.0
    if ($format.PSObject.Properties.Match("size").Count -gt 0 -and $format.size) {
        $fileSizeBytes = [double]$format.size
    }

    $audioMeasure = $streams |
        Where-Object {
            $_.codec_type -eq "audio" -and
            $_.PSObject.Properties.Match("bit_rate").Count -gt 0 -and
            $_.bit_rate
        } |
        Measure-Object -Property bit_rate -Sum

    $audioBitrateBps = 0.0
    if ($audioMeasure -and $audioMeasure.PSObject.Properties.Match("Sum").Count -gt 0 -and $audioMeasure.Sum) {
        $audioBitrateBps = [double]$audioMeasure.Sum
    }

    $totalBitrateBps = 0.0
    if ($format.PSObject.Properties.Match("bit_rate").Count -gt 0 -and $format.bit_rate) {
        $totalBitrateBps = [double]$format.bit_rate
    } elseif ($durationSec -gt 0 -and $fileSizeBytes -gt 0) {
        $totalBitrateBps = ($fileSizeBytes * 8.0) / $durationSec
    }

    $videoBitrateBps = 0.0
    $bitrateSource = "stream"

    if ($videoStream.PSObject.Properties.Match("bit_rate").Count -gt 0 -and $videoStream.bit_rate) {
        $videoBitrateBps = [double]$videoStream.bit_rate
    } elseif ($totalBitrateBps -gt 0) {
        $videoBitrateBps = [Math]::Max($totalBitrateBps - $audioBitrateBps, 0.0)
        $bitrateSource = "estimated_from_total"
    }

    if ($videoBitrateBps -le 0 -or $durationSec -le 0 -or $fileSizeBytes -le 0) {
        return $null
    }

    [pscustomobject]@{
        DurationSec     = $durationSec
        FileSizeBytes   = $fileSizeBytes
        TotalBitrateBps = $totalBitrateBps
        VideoBitrateBps = $videoBitrateBps
        AudioBitrateBps = [double]$audioBitrateBps
        BitrateSource   = $bitrateSource
        VideoCodec      = if ($videoStream) { [string]$videoStream.codec_name } else { "" }
        AudioCodec      = if ($audioStream) { [string]$audioStream.codec_name } else { "" }
    }
}

function Get-TaskRootPath {
    return (Join-Path -Path $PSScriptRoot -ChildPath "tasks")
}

function Get-SafeLeafName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $trimmed = $Path.TrimEnd('\', '/')
    $leafName = Split-Path -Path $trimmed -Leaf
    if ([string]::IsNullOrWhiteSpace($leafName)) {
        $leafName = "task"
    }

    return ($leafName -replace '[<>:"/\\|?*]', '_')
}

function Get-TaskFolderName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [int]$ThresholdKbps,

        [Parameter(Mandatory = $true)]
        [int]$TargetKbps
    )

    $leafName = Get-SafeLeafName -Path $SourceRoot
    return ("{0}__scan-{1}__target-{2}" -f $leafName, $ThresholdKbps, $TargetKbps)
}

function Get-TaskFolderPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [int]$ThresholdKbps,

        [Parameter(Mandatory = $true)]
        [int]$TargetKbps
    )

    $taskRoot = Get-TaskRootPath
    Ensure-Directory -Path $taskRoot
    return (Join-Path -Path $taskRoot -ChildPath (Get-TaskFolderName -SourceRoot $SourceRoot -ThresholdKbps $ThresholdKbps -TargetKbps $TargetKbps))
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Data
    )

    $json = $Data | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function Read-TaskFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder
    )

    $taskPath = Join-Path -Path $TaskFolder -ChildPath "task.json"
    if (-not (Test-Path -LiteralPath $taskPath)) {
        throw "Task file not found: $taskPath"
    }

    return ((Get-Content -LiteralPath $taskPath -Raw) | ConvertFrom-Json)
}

function Save-TaskFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder,

        [Parameter(Mandatory = $true)]
        [object]$Task
    )

    Ensure-Directory -Path $TaskFolder
    $taskPath = Join-Path -Path $TaskFolder -ChildPath "task.json"
    Save-JsonFile -Path $taskPath -Data $Task
}

function Write-TaskSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder,

        [Parameter(Mandatory = $true)]
        [object]$Task
    )

    $items = @($Task.items)
    $pending = @($items | Where-Object { $_.status -eq "pending" })
    $done = @($items | Where-Object { $_.status -eq "done" })
    $failed = @($items | Where-Object { $_.status -eq "failed" })
    $skipped = @($items | Where-Object { $_.status -eq "skipped" })
    $processing = @($items | Where-Object { $_.status -eq "processing" })

    $remainingSizeBytes = Get-SumOrZero -Items $pending -PropertyName "sizeBytes"
    $remainingSavedBytes = Get-SumOrZero -Items $pending -PropertyName "estimatedSavedBytes"

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Task: $($Task.taskName)")
    $lines.Add("Source path: $($Task.sourceRoot)")
    $lines.Add("Threshold bitrate: $($Task.thresholdKbps) kbps")
    $lines.Add("Target bitrate: $($Task.targetKbps) kbps")
    $lines.Add("Candidates: $($items.Count)")
    $lines.Add("Pending: $($pending.Count)")
    $lines.Add("Processing: $($processing.Count)")
    $lines.Add("Done: $($done.Count)")
    $lines.Add("Failed: $($failed.Count)")
    $lines.Add("Skipped: $($skipped.Count)")
    $lines.Add("Pending size: $(Format-Bytes -Bytes $remainingSizeBytes)")
    $lines.Add("Estimated remaining savings: $(Format-Bytes -Bytes $remainingSavedBytes)")
    $lines.Add("Last updated: $($Task.updatedAt)")

    if ($failed.Count -gt 0) {
        $lines.Add("")
        $lines.Add("Failed items:")
        $failed | Select-Object -First 10 | ForEach-Object {
            $reason = ""
            if ($_.PSObject.Properties.Match("lastResult").Count -gt 0 -and $_.lastResult) {
                $reason = " :: $($_.lastResult)"
            }

            $lines.Add(("- {0}{1}" -f $_.path, $reason))
        }
    }

    $summaryPath = Join-Path -Path $TaskFolder -ChildPath "summary.txt"
    [System.IO.File]::WriteAllLines($summaryPath, $lines, [System.Text.Encoding]::UTF8)
}

function Append-HistoryLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder,

        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $historyPath = Join-Path -Path $TaskFolder -ChildPath "history.log"
    Add-Content -LiteralPath $historyPath -Value $Line -Encoding UTF8
}

function Read-InputOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [string]$DefaultValue
    )

    $response = Read-Host "$Prompt (press Enter for default: $DefaultValue)"
    if ([string]::IsNullOrWhiteSpace($response)) {
        return $DefaultValue
    }

    return $response.Trim()
}

function Read-IntOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [int]$DefaultValue
    )

    while ($true) {
        $value = Read-InputOrDefault -Prompt $Prompt -DefaultValue ([string]$DefaultValue)
        $parsed = 0
        if ([int]::TryParse($value, [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }

        Write-Host "Please enter a positive integer." -ForegroundColor Yellow
    }
}

function Read-ChoiceOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [string[]]$Choices,

        [Parameter(Mandatory = $true)]
        [string]$DefaultValue
    )

    $normalizedChoices = $Choices | ForEach-Object { $_.ToLowerInvariant() }
    while ($true) {
        $value = Read-InputOrDefault -Prompt "$Prompt [$($Choices -join '/')] " -DefaultValue $DefaultValue
        $normalized = $value.ToLowerInvariant()
        if ($normalizedChoices -contains $normalized) {
            return $normalized
        }

        Write-Host "Please choose one of: $($Choices -join ', ')." -ForegroundColor Yellow
    }
}

function Read-YesNoOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [bool]$DefaultValue
    )

    $defaultText = if ($DefaultValue) { "Y" } else { "N" }
    while ($true) {
        $value = Read-InputOrDefault -Prompt "$Prompt [Y/N]" -DefaultValue $defaultText
        switch ($value.ToLowerInvariant()) {
            "y" { return $true }
            "yes" { return $true }
            "n" { return $false }
            "no" { return $false }
        }

        Write-Host "Please answer Y or N." -ForegroundColor Yellow
    }
}

function Get-OutputExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $extension = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()
    if ($extension -in @(".mp4", ".m4v", ".mov", ".mkv")) {
        return $extension
    }

    return ".mp4"
}

function Test-ReplaceOriginalSupported {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $extension = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()
    return ($extension -in @(".mp4", ".m4v", ".mov", ".mkv"))
}

function Get-DefaultOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    $directory = Split-Path -Path $InputPath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $extension = Get-OutputExtension -InputPath $InputPath
    return (Join-Path -Path $directory -ChildPath ("{0}_{1}{2}" -f $baseName, $Suffix, $extension))
}

function New-TemporaryOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $directory = Split-Path -Path $InputPath -Parent
    $extension = Get-OutputExtension -InputPath $InputPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $token = [System.Guid]::NewGuid().ToString("N")
    return (Join-Path -Path $directory -ChildPath ("{0}.codex-temp-{1}{2}" -f $baseName, $token, $extension))
}

function New-BackupPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return ("{0}.codex-backup-{1}" -f $InputPath, $stamp)
}

function Test-OutputForReplacement {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProbePath,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [double]$DurationToleranceSec = 2.0
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "Encoded output was not created."
    }

    $outputInfo = Get-VideoInfo -ProbePath $ProbePath -FilePath $OutputPath
    if (-not $outputInfo) {
        throw "Encoded output failed ffprobe validation."
    }

    if ($outputInfo.FileSizeBytes -le 0) {
        throw "Encoded output is empty."
    }

    $sourceInfo = Get-VideoInfo -ProbePath $ProbePath -FilePath $SourcePath
    if (-not $sourceInfo) {
        throw "Source file could not be validated before replacement."
    }

    if ([Math]::Abs($sourceInfo.DurationSec - $outputInfo.DurationSec) -gt $DurationToleranceSec) {
        throw "Duration delta exceeds tolerance."
    }

    return $outputInfo
}

function Replace-OriginalFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [switch]$KeepBackup
    )

    $backupPath = New-BackupPath -InputPath $SourcePath
    Move-Item -LiteralPath $SourcePath -Destination $backupPath

    try {
        Move-Item -LiteralPath $OutputPath -Destination $SourcePath
        if (-not $KeepBackup) {
            Remove-Item -LiteralPath $backupPath -Force
            return $null
        }

        return $backupPath
    } catch {
        if (Test-Path -LiteralPath $OutputPath) {
            Remove-Item -LiteralPath $OutputPath -Force
        }

        if (-not (Test-Path -LiteralPath $SourcePath) -and (Test-Path -LiteralPath $backupPath)) {
            Move-Item -LiteralPath $backupPath -Destination $SourcePath
        }

        throw
    }
}

function Invoke-EncodeWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FfmpegPath,

        [Parameter(Mandatory = $true)]
        [string]$ProbePath,

        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string[]]$VideoArguments,

        [Parameter(Mandatory = $true)]
        [string]$DefaultSuffix,

        [int]$AudioBitrateKbps = 320,
        [int]$AudioSampleRate = 48000,
        [switch]$ReplaceOriginal,
        [switch]$KeepBackup,
        [double]$DurationToleranceSec = 2.0
    )

    $resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path
    if ($ReplaceOriginal -and (-not (Test-ReplaceOriginalSupported -InputPath $resolvedInputPath))) {
        throw "ReplaceOriginal is only supported for mp4, m4v, mov, and mkv input files."
    }

    $resolvedOutputPath = $null
    $temporaryOutputPath = $null

    if ($ReplaceOriginal) {
        $temporaryOutputPath = New-TemporaryOutputPath -InputPath $resolvedInputPath
        $resolvedOutputPath = $temporaryOutputPath
    } elseif ($OutputPath) {
        $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    } else {
        $resolvedOutputPath = Get-DefaultOutputPath -InputPath $resolvedInputPath -Suffix $DefaultSuffix
    }

    $extension = [System.IO.Path]::GetExtension($resolvedOutputPath).ToLowerInvariant()
    $arguments = @(
        "-hide_banner"
        "-y"
        "-i", $resolvedInputPath
        "-af", "aresample=$AudioSampleRate`:resampler=soxr"
    )

    if ($extension -in @(".mp4", ".m4v")) {
        $arguments += @("-movflags", "+faststart+use_metadata_tags")
    }

    $arguments += $VideoArguments
    $arguments += @(
        "-fps_mode", "cfr"
        "-c:a", "aac"
        "-b:a", ("{0}k" -f $AudioBitrateKbps)
        "-sn"
        $resolvedOutputPath
    )

    Write-Host "Running:" -ForegroundColor Cyan
    Write-Host ('"{0}" {1}' -f $FfmpegPath, ($arguments -join " ")) -ForegroundColor DarkGray

    & $FfmpegPath @arguments
    if ($LASTEXITCODE -ne 0) {
        if ($temporaryOutputPath -and (Test-Path -LiteralPath $temporaryOutputPath)) {
            Remove-Item -LiteralPath $temporaryOutputPath -Force
        }

        throw "ffmpeg failed with exit code $LASTEXITCODE."
    }

    $validatedOutput = Test-OutputForReplacement -ProbePath $ProbePath -SourcePath $resolvedInputPath -OutputPath $resolvedOutputPath -DurationToleranceSec $DurationToleranceSec

    $backupPath = $null
    if ($ReplaceOriginal) {
        $backupPath = Replace-OriginalFile -SourcePath $resolvedInputPath -OutputPath $resolvedOutputPath -KeepBackup:$KeepBackup
        $resolvedOutputPath = $resolvedInputPath
    }

    [pscustomobject]@{
        OutputPath = $resolvedOutputPath
        BackupPath = $backupPath
        DurationSec = $validatedOutput.DurationSec
        SizeBytes = $validatedOutput.FileSizeBytes
        VideoBitrateBps = $validatedOutput.VideoBitrateBps
        ReplacedOriginal = [bool]$ReplaceOriginal
    }
}
