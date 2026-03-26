param(
    [string]$RootPath,
    [int]$ThresholdKbps,
    [int]$TargetKbps,
    [switch]$ResetTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "video-compass-common.ps1")

Assert-RequiredVideoTools -RequireFfprobe

$defaultThresholdKbps = 4500
$defaultTargetKbps = 3500
$defaultAudioBitrateKbps = 320
$defaultAudioSampleRate = 48000
$videoExtensions = @(".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".ts", ".mts", ".m2ts")

if (-not $PSBoundParameters.ContainsKey("RootPath")) {
    $RootPath = Read-RequiredInput -Prompt "扫描目录"
}

if (-not $PSBoundParameters.ContainsKey("ThresholdKbps")) {
    $ThresholdKbps = Read-IntOrDefault -Prompt "Scan threshold bitrate (kbps)" -DefaultValue $defaultThresholdKbps
}

if (-not $PSBoundParameters.ContainsKey("TargetKbps")) {
    $TargetKbps = Read-IntOrDefault -Prompt "Target encode bitrate (kbps)" -DefaultValue $defaultTargetKbps
}

$resolvedRootPath = (Resolve-Path -LiteralPath $RootPath).Path
$thresholdBps = $ThresholdKbps * 1000.0
$targetBps = $TargetKbps * 1000.0
$ffprobePath = Resolve-ToolPath -CommandName "ffprobe.exe" -LocalFileName "ffprobe.exe"
$taskFolder = Get-TaskFolderPath -SourceRoot $resolvedRootPath -ThresholdKbps $ThresholdKbps -TargetKbps $TargetKbps
Ensure-Directory -Path $taskFolder

$existingTaskPath = Join-Path -Path $taskFolder -ChildPath "task.json"
$existingItemsByPath = @{}
if ((-not $ResetTask) -and (Test-Path -LiteralPath $existingTaskPath)) {
    $existingTask = Read-TaskFile -TaskFolder $taskFolder
    foreach ($item in @($existingTask.items)) {
        $existingItemsByPath[$item.path] = $item
    }
}

$files = Get-ChildItem -LiteralPath $resolvedRootPath -File -Recurse |
    Where-Object { $videoExtensions -contains $_.Extension.ToLowerInvariant() }

if (-not $files) {
    throw "目标目录下没有找到支持的视频文件。"
}

$candidates = New-Object System.Collections.Generic.List[object]
$skippedScan = New-Object System.Collections.Generic.List[object]

for ($index = 0; $index -lt $files.Count; $index++) {
    $file = $files[$index]

    if ((($index + 1) % 25) -eq 0 -or $index -eq 0 -or ($index + 1) -eq $files.Count) {
        Write-Progress -Activity "Scanning video files" -Status "$($index + 1) / $($files.Count)" -PercentComplete ((($index + 1) / $files.Count) * 100)
    }

    try {
        $info = Get-VideoInfo -ProbePath $ffprobePath -FilePath $file.FullName
        if (-not $info) {
            $skippedScan.Add([pscustomobject]@{
                Path = $file.FullName
                Reason = "Missing usable bitrate or duration metadata"
            })
            continue
        }

        if ($info.VideoBitrateBps -le $thresholdBps) {
            continue
        }

        $estimatedSavedBytes = 0.0
        if ($info.VideoBitrateBps -gt $targetBps) {
            $estimatedSavedBytes = (($info.VideoBitrateBps - $targetBps) * $info.DurationSec) / 8.0
            if ($estimatedSavedBytes -gt $info.FileSizeBytes) {
                $estimatedSavedBytes = $info.FileSizeBytes
            }
        }

        $existingItem = $null
        if ($existingItemsByPath.ContainsKey($file.FullName)) {
            $existingItem = $existingItemsByPath[$file.FullName]
        }

        $status = "pending"
        $lastAttemptAt = $null
        $lastResult = $null
        $replacedOriginal = $false

        if ($existingItem) {
            if ($existingItem.PSObject.Properties.Match("status").Count -gt 0 -and $existingItem.status) {
                $status = [string]$existingItem.status
            }

            if ($existingItem.PSObject.Properties.Match("lastAttemptAt").Count -gt 0) {
                $lastAttemptAt = $existingItem.lastAttemptAt
            }

            if ($existingItem.PSObject.Properties.Match("lastResult").Count -gt 0) {
                $lastResult = $existingItem.lastResult
            }

            if ($existingItem.PSObject.Properties.Match("replacedOriginal").Count -gt 0) {
                $replacedOriginal = [bool]$existingItem.replacedOriginal
            }
        }

        $candidates.Add([pscustomobject]@{
            path = $file.FullName
            sortKey = [Math]::Round($estimatedSavedBytes, 2)
            videoBitrateKbps = [Math]::Round($info.VideoBitrateBps / 1000.0, 2)
            audioBitrateKbps = [Math]::Round($info.AudioBitrateBps / 1000.0, 2)
            sizeBytes = [Math]::Round($info.FileSizeBytes, 2)
            durationSec = [Math]::Round($info.DurationSec, 3)
            estimatedSavedBytes = [Math]::Round($estimatedSavedBytes, 2)
            bitrateSource = $info.BitrateSource
            status = $status
            lastAttemptAt = $lastAttemptAt
            lastResult = $lastResult
            replacedOriginal = $replacedOriginal
        })
    } catch {
        $skippedScan.Add([pscustomobject]@{
            Path = $file.FullName
            Reason = $_.Exception.Message
        })
    }
}

Write-Progress -Activity "Scanning video files" -Completed

$orderedItems = @($candidates | Sort-Object -Property sortKey, videoBitrateKbps -Descending)

$task = [pscustomobject]@{
    schemaVersion = 1
    taskName = Get-TaskFolderName -SourceRoot $resolvedRootPath -ThresholdKbps $ThresholdKbps -TargetKbps $TargetKbps
    sourceRoot = $resolvedRootPath
    thresholdKbps = $ThresholdKbps
    targetKbps = $TargetKbps
    audioBitrateKbps = $defaultAudioBitrateKbps
    audioSampleRate = $defaultAudioSampleRate
    createdAt = if ((-not $ResetTask) -and (Test-Path -LiteralPath $existingTaskPath)) {
        $existingTask.createdAt
    } else {
        [DateTime]::UtcNow.ToString("o")
    }
    updatedAt = [DateTime]::UtcNow.ToString("o")
    encoderPreference = if ((-not $ResetTask) -and (Test-Path -LiteralPath $existingTaskPath) -and $existingTask.encoderPreference) {
        [string]$existingTask.encoderPreference
    } else {
        "qsv"
    }
    items = $orderedItems
}

Save-TaskFile -TaskFolder $taskFolder -Task $task
Write-TaskSummary -TaskFolder $taskFolder -Task $task
Ensure-Directory -Path $taskFolder
$historyPath = Join-Path -Path $taskFolder -ChildPath "history.log"
if (-not (Test-Path -LiteralPath $historyPath)) {
    [System.IO.File]::WriteAllText($historyPath, "", [System.Text.Encoding]::UTF8)
}

$candidateCount = @($task.items).Count
$pendingCount = @($task.items | Where-Object { $_.status -eq "pending" }).Count
$estimatedSavedBytes = Get-SumOrZero -Items @($task.items) -PropertyName "estimatedSavedBytes"

Write-Host ""
Write-Host "源目录: $resolvedRootPath"
Write-Host "扫描阈值码率: $ThresholdKbps kbps"
Write-Host "目标压缩码率: $TargetKbps kbps"
Write-Host "扫描到的视频文件数: $($files.Count)"
Write-Host "候选文件数: $candidateCount"
Write-Host "待处理数量: $pendingCount"
Write-Host "扫描阶段跳过数量: $($skippedScan.Count)"
Write-Host "预计候选文件可节省空间: $(Format-Bytes -Bytes $estimatedSavedBytes)"
Write-Host "任务目录: $taskFolder"
Write-Host "任务文件: $(Join-Path -Path $taskFolder -ChildPath 'task.json')"
Write-Host "摘要文件: $(Join-Path -Path $taskFolder -ChildPath 'summary.txt')"
