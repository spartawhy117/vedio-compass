[CmdletBinding()]
param(
    [string]$RootPath,
    [switch]$KeepBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Initialize-ConsoleEncoding {
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [Console]::InputEncoding = $utf8NoBom
        [Console]::OutputEncoding = $utf8NoBom
        $global:OutputEncoding = $utf8NoBom

        $chcpPath = Join-Path -Path $env:SystemRoot -ChildPath "System32\chcp.com"
        if (Test-Path -LiteralPath $chcpPath) {
            & $chcpPath 65001 > $null
        }
    } catch {
    }
}

Initialize-ConsoleEncoding

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

    throw "找不到 $CommandName。请先运行 .\check-video-compass-env.ps1，或安装 FFmpeg，并把 $LocalFileName 放到 PATH 或脚本同目录。"
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
            throw "ffmpeg 重新封装失败，退出码 $LASTEXITCODE。"
        }

        Move-Item -LiteralPath $FilePath -Destination $backupPath
        Move-Item -LiteralPath $tempPath -Destination $FilePath

        Start-Sleep -Milliseconds 300
        $newBitrate = Get-WindowsTotalBitrate -FilePath $FilePath
        if ($newBitrate -le 0) {
            Move-Item -LiteralPath $FilePath -Destination $tempPath
            Move-Item -LiteralPath $backupPath -Destination $FilePath
            Remove-Item -LiteralPath $tempPath -Force
            throw "重新封装后，Windows 资源管理器仍然显示码率为 0。"
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

if (-not $PSBoundParameters.ContainsKey("RootPath")) {
    while ($true) {
        $inputPath = Read-Host "扫描目录"
        if (-not [string]::IsNullOrWhiteSpace($inputPath)) {
            $RootPath = $inputPath.Trim()
            break
        }

        Write-Host "此项不能为空，请重新输入。" -ForegroundColor Yellow
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
    throw "目标目录下没有找到支持的视频文件。"
}

$fixed = New-Object System.Collections.Generic.List[object]
$unsupported = New-Object System.Collections.Generic.List[object]
$failed = New-Object System.Collections.Generic.List[object]
$alreadyOk = 0

for ($index = 0; $index -lt $files.Count; $index++) {
    $file = $files[$index]

    if ((($index + 1) % 20) -eq 0 -or $index -eq 0 -or ($index + 1) -eq $files.Count) {
        Write-Progress -Activity "检查资源管理器码率元数据" -Status "$($index + 1) / $($files.Count)" -PercentComplete ((($index + 1) / $files.Count) * 100)
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
                Reason = "ffprobe 未能读取到可用码率。"
            })
            continue
        }

        $extension = $file.Extension.ToLowerInvariant()
        if ($repairableExtensions -notcontains $extension) {
            $unsupported.Add([pscustomobject]@{
                Path = $file.FullName
                Reason = "当前容器或编码组合不适合通过 Windows 的 TotalBitrate 元数据回填。"
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

Write-Progress -Activity "检查资源管理器码率元数据" -Completed

Write-Host ""
Write-Host "扫描目录: $resolvedRootPath"
Write-Host "已检查文件数: $($files.Count)"
Write-Host "原本正常: $alreadyOk"
Write-Host "已修复: $($fixed.Count)"
Write-Host "Windows 元数据处理器不支持: $($unsupported.Count)"
Write-Host "失败: $($failed.Count)"

if ($fixed.Count -gt 0) {
    Write-Host ""
    Write-Host "已修复文件:"
    $fixed | Select-Object -First 10 | ForEach-Object {
        Write-Host ("- {0} -> {1}" -f $_.Path, (Format-Kbps -BitsPerSecond $_.NewBitrate))
    }
}

if ($unsupported.Count -gt 0) {
    Write-Host ""
    Write-Host "不支持回填的样本:"
    $unsupported | Select-Object -First 10 | ForEach-Object {
        Write-Host ("- {0}" -f $_.Path)
        Write-Host ("  实际码率: {0}, 视频编码: {1}, 音频编码: {2}" -f (Format-Kbps -BitsPerSecond $_.ActualBitrate), $_.VideoCodec, $_.AudioCodec)
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "失败文件:"
    $failed | Select-Object -First 10 | ForEach-Object {
        Write-Host ("- {0}" -f $_.Path)
        Write-Host ("  原因: {0}" -f $_.Reason)
    }
}
