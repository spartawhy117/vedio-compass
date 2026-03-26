[CmdletBinding()]
param(
    [string]$RootPath,
    [switch]$KeepBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Get-WindowsTotalBitrate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.Namespace([System.IO.Path]::GetDirectoryName($FilePath))
    if (-not $folder) {
        return 0L
    }

    $item = $folder.ParseName([System.IO.Path]::GetFileName($FilePath))
    if (-not $item) {
        return 0L
    }

    $value = $item.ExtendedProperty("System.Video.TotalBitrate")
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        return 0L
    }

    return [int64]$value
}

function Get-ProbeInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProbePath,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $probeArgs = @(
        "-v", "error"
        "-show_entries", "format=duration,size,bit_rate:stream=index,codec_type,codec_name"
        "-of", "json"
        $FilePath
    )

    $json = & $ProbePath @probeArgs
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    $probe = $json | ConvertFrom-Json
    $format = $probe.format
    $streams = @($probe.streams)

    $durationSec = 0.0
    if ($format.PSObject.Properties.Match("duration").Count -gt 0 -and $format.duration) {
        $durationSec = [double]$format.duration
    }

    $sizeBytes = 0.0
    if ($format.PSObject.Properties.Match("size").Count -gt 0 -and $format.size) {
        $sizeBytes = [double]$format.size
    }

    $bitrateBps = 0.0
    if ($format.PSObject.Properties.Match("bit_rate").Count -gt 0 -and $format.bit_rate) {
        $bitrateBps = [double]$format.bit_rate
    } elseif ($durationSec -gt 0 -and $sizeBytes -gt 0) {
        $bitrateBps = ($sizeBytes * 8.0) / $durationSec
    }

    $videoStream = $streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $audioStream = $streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    [pscustomobject]@{
        DurationSec = $durationSec
        SizeBytes   = $sizeBytes
        BitrateBps  = $bitrateBps
        VideoCodec  = if ($videoStream) { [string]$videoStream.codec_name } else { "" }
        AudioCodec  = if ($audioStream) { [string]$audioStream.codec_name } else { "" }
    }
}

function New-TempPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $directory = [System.IO.Path]::GetDirectoryName($SourcePath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $extension = [System.IO.Path]::GetExtension($SourcePath)
    $token = [System.Guid]::NewGuid().ToString("N")
    return (Join-Path -Path $directory -ChildPath ("{0}.codex-fix-{1}{2}" -f $baseName, $token, $extension))
}

function Get-BackupPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return ("{0}.codex-backup-{1}" -f $SourcePath, $stamp)
}

function Repair-ContainerMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FfmpegPath,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [switch]$KeepBackupFile
    )

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $tempPath = New-TempPath -SourcePath $FilePath
    $backupPath = Get-BackupPath -SourcePath $FilePath

    $arguments = @(
        "-hide_banner"
        "-y"
        "-i", $FilePath
        "-map", "0"
        "-c", "copy"
    )

    if ($extension -in @(".mp4", ".mov", ".m4v")) {
        $arguments += @("-movflags", "+faststart+use_metadata_tags")
    }

    $arguments += $tempPath

    try {
        & $FfmpegPath @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "ffmpeg remux failed with exit code $LASTEXITCODE."
        }

        Move-Item -LiteralPath $FilePath -Destination $backupPath
        Move-Item -LiteralPath $tempPath -Destination $FilePath

        Start-Sleep -Milliseconds 300
        $newBitrate = Get-WindowsTotalBitrate -FilePath $FilePath
        if ($newBitrate -le 0) {
            Move-Item -LiteralPath $FilePath -Destination $tempPath
            Move-Item -LiteralPath $backupPath -Destination $FilePath
            Remove-Item -LiteralPath $tempPath -Force
            throw "Windows Explorer still reports 0 after remux."
        }

        if (-not $KeepBackupFile) {
            Remove-Item -LiteralPath $backupPath -Force
        }

        return $newBitrate
    } catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }

        if ((-not (Test-Path -LiteralPath $FilePath)) -and (Test-Path -LiteralPath $backupPath)) {
            Move-Item -LiteralPath $backupPath -Destination $FilePath
        }

        throw
    }
}

function Format-Kbps {
    param(
        [Parameter(Mandatory = $true)]
        [double]$BitsPerSecond
    )

    return ("{0:N0} kbps" -f ($BitsPerSecond / 1000.0))
}

$defaultRoot = "E:\entertament\hx\fc2"

if (-not $PSBoundParameters.ContainsKey("RootPath")) {
    $inputPath = Read-Host "Scan folder (press Enter for default: $defaultRoot)"
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        $RootPath = $defaultRoot
    } else {
        $RootPath = $inputPath.Trim()
    }
}

$resolvedRootPath = (Resolve-Path -LiteralPath $RootPath).Path
$ffprobePath = Resolve-ToolPath -CommandName "ffprobe.exe" -LocalFileName "ffprobe.exe"
$ffmpegPath = Resolve-ToolPath -CommandName "ffmpeg.exe" -LocalFileName "ffmpeg.exe"

$videoExtensions = @(".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi", ".wmv")
$repairableExtensions = @(".mp4", ".mov", ".m4v")

$files = Get-ChildItem -LiteralPath $resolvedRootPath -File -Recurse |
    Where-Object { $videoExtensions -contains $_.Extension.ToLowerInvariant() }

if (-not $files) {
    throw "No supported video files were found under the target directory."
}

$fixed = New-Object System.Collections.Generic.List[object]
$unsupported = New-Object System.Collections.Generic.List[object]
$failed = New-Object System.Collections.Generic.List[object]
$alreadyOk = 0

for ($index = 0; $index -lt $files.Count; $index++) {
    $file = $files[$index]

    if ((($index + 1) % 20) -eq 0 -or $index -eq 0 -or ($index + 1) -eq $files.Count) {
        Write-Progress -Activity "Checking Explorer bitrate metadata" -Status "$($index + 1) / $($files.Count)" -PercentComplete ((($index + 1) / $files.Count) * 100)
    }

    try {
        $shellBitrate = Get-WindowsTotalBitrate -FilePath $file.FullName
        if ($shellBitrate -gt 0) {
            $alreadyOk++
            continue
        }

        $probeInfo = Get-ProbeInfo -ProbePath $ffprobePath -FilePath $file.FullName
        if (-not $probeInfo -or $probeInfo.BitrateBps -le 0) {
            $failed.Add([pscustomobject]@{
                Path = $file.FullName
                Reason = "No usable bitrate found with ffprobe."
            })
            continue
        }

        $extension = $file.Extension.ToLowerInvariant()
        if ($repairableExtensions -notcontains $extension) {
            $unsupported.Add([pscustomobject]@{
                Path = $file.FullName
                Reason = "Windows does not reliably expose writable TotalBitrate for this container/codec combination."
                ActualBitrate = [Math]::Round($probeInfo.BitrateBps)
                VideoCodec = $probeInfo.VideoCodec
                AudioCodec = $probeInfo.AudioCodec
            })
            continue
        }

        $newBitrate = Repair-ContainerMetadata -FfmpegPath $ffmpegPath -FilePath $file.FullName -KeepBackupFile:$KeepBackup
        $fixed.Add([pscustomobject]@{
            Path = $file.FullName
            OldBitrate = 0
            NewBitrate = $newBitrate
        })
    } catch {
        $failed.Add([pscustomobject]@{
            Path = $file.FullName
            Reason = $_.Exception.Message
        })
    }
}

Write-Progress -Activity "Checking Explorer bitrate metadata" -Completed

Write-Host ""
Write-Host "Scan path: $resolvedRootPath"
Write-Host "Checked: $($files.Count) files"
Write-Host "Already OK: $alreadyOk"
Write-Host "Fixed: $($fixed.Count)"
Write-Host "Unsupported by Windows metadata handler: $($unsupported.Count)"
Write-Host "Failed: $($failed.Count)"

if ($fixed.Count -gt 0) {
    Write-Host ""
    Write-Host "Fixed files:"
    $fixed | Select-Object -First 10 | ForEach-Object {
        Write-Host ("- {0} -> {1}" -f $_.Path, (Format-Kbps -BitsPerSecond $_.NewBitrate))
    }
}

if ($unsupported.Count -gt 0) {
    Write-Host ""
    Write-Host "Unsupported samples:"
    $unsupported | Select-Object -First 10 | ForEach-Object {
        Write-Host ("- {0}" -f $_.Path)
        Write-Host ("  actual: {0}, video: {1}, audio: {2}" -f (Format-Kbps -BitsPerSecond $_.ActualBitrate), $_.VideoCodec, $_.AudioCodec)
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed files:"
    $failed | Select-Object -First 10 | ForEach-Object {
        Write-Host ("- {0}" -f $_.Path)
        Write-Host ("  reason: {0}" -f $_.Reason)
    }
}
