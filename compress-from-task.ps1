param(
    [string]$TaskFolder,
    [int]$Count,
    [ValidateRange(1, 2)]
    [int]$ParallelCount,
    [ValidateSet("qsv", "nvenc", "amf", "cpu")]
    [string]$Encoder,
    [ValidateSet("aac", "libfdk_aac")]
    [string]$AudioCodec,
    [ValidateSet("yes", "no")]
    [string]$ReplaceOriginalMode,
    [ValidateSet("yes", "no")]
    [string]$KeepBackupMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "video-compass-common.ps1")

$global:VideoCompassShutdownRequested = $false
$global:VideoCompassShutdownReason = ""
Clear-VideoCompassActiveTaskContext
Clear-VideoCompassActiveEncodeContext

function Save-TaskArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolderPath,

        [Parameter(Mandatory = $true)]
        [object]$TaskObject
    )

    $TaskObject.updatedAt = [DateTime]::UtcNow.ToString("o")
    Save-TaskFile -TaskFolder $TaskFolderPath -Task $TaskObject
    Write-TaskSummary -TaskFolder $TaskFolderPath -Task $TaskObject
}

function New-EncodeScriptArgs {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TaskItem,

        [Parameter(Mandatory = $true)]
        [object]$TaskObject,

        [Parameter(Mandatory = $true)]
        [string]$SelectedAudioCodec,

        [Parameter(Mandatory = $true)]
        [bool]$ReplaceOriginalValue,

        [Parameter(Mandatory = $true)]
        [bool]$KeepBackupValue
    )

    $scriptArgs = @{
        InputPath = $TaskItem.path
        VideoBitrateKbps = [int]$TaskObject.targetKbps
        AudioBitrateKbps = [int]$TaskObject.audioBitrateKbps
        AudioSampleRate = [int]$TaskObject.audioSampleRate
        AudioCodec = $SelectedAudioCodec
        DurationToleranceSec = 2.0
    }

    if ($ReplaceOriginalValue) {
        $scriptArgs.ReplaceOriginal = $true
    }

    if ($KeepBackupValue) {
        $scriptArgs.KeepBackup = $true
    }

    return $scriptArgs
}

function Update-ParallelBatchProgress {
    param(
        [Parameter(Mandatory = $true)]
        [int]$BatchTotalCount,

        [Parameter(Mandatory = $true)]
        [int]$CompletedCount,

        [Parameter(Mandatory = $true)]
        [int]$RunningCount,

        [Parameter(Mandatory = $true)]
        [DateTime]$BatchStartedAtUtc
    )

    if ($BatchTotalCount -le 0) {
        return
    }

    $percent = [Math]::Min((($CompletedCount / $BatchTotalCount) * 100.0), 100.0)
    $elapsedSec = [Math]::Max(([DateTime]::UtcNow - $BatchStartedAtUtc).TotalSeconds, 0.001)
    $etaSec = 0.0
    if ($CompletedCount -gt 0) {
        $avgSecPerItem = $elapsedSec / $CompletedCount
        $etaSec = [Math]::Max(($BatchTotalCount - $CompletedCount) * $avgSecPerItem, 0.0)
    }

    $status = if ($CompletedCount -gt 0) {
        "已完成 $CompletedCount/$BatchTotalCount | 运行中 $RunningCount | 预计剩余 $(Format-DurationClock -TotalSeconds $etaSec)"
    } else {
        "已完成 0/$BatchTotalCount | 运行中 $RunningCount | 预计剩余计算中..."
    }

    Write-Progress -Id 2 -Activity "批量压缩任务" -Status $status -PercentComplete $percent
}

function Start-EncodeJobWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$ScriptArgs,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    return (Start-Job -ScriptBlock {
        param($EncoderScriptPath, $EncoderScriptArgs, $Workdir)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"
        $ProgressPreference = "SilentlyContinue"
        Set-Location -LiteralPath $Workdir

        try {
            & $EncoderScriptPath @EncoderScriptArgs | Out-Null
            [pscustomobject]@{
                Success = $true
                Message = "已完成"
            }
        } catch {
            [pscustomobject]@{
                Success = $false
                Message = $_.Exception.Message
            }
        }
    } -ArgumentList $ScriptPath, $ScriptArgs, $WorkingDirectory)
}

function Complete-TaskItemSuccess {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TaskItem,

        [Parameter(Mandatory = $true)]
        [object]$TaskObject,

        [Parameter(Mandatory = $true)]
        [string]$TaskFolderPath,

        [Parameter(Mandatory = $true)]
        [string]$SelectedEncoder,

        [Parameter(Mandatory = $true)]
        [bool]$ReplaceOriginalValue,

        [Parameter(Mandatory = $true)]
        [bool]$KeepBackupValue
    )

    $TaskItem.status = "done"
    $TaskItem.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
    $TaskItem.lastResult = "已使用 $SelectedEncoder 完成处理。"
    $TaskItem.replacedOriginal = $ReplaceOriginalValue
    Save-TaskArtifacts -TaskFolderPath $TaskFolderPath -TaskObject $TaskObject
    Append-HistoryLine -TaskFolder $TaskFolderPath -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $TaskItem.path, $SelectedEncoder, $TaskObject.targetKbps, "done", $ReplaceOriginalValue, $KeepBackupValue, "已完成")
}

function Complete-TaskItemFailure {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TaskItem,

        [Parameter(Mandatory = $true)]
        [object]$TaskObject,

        [Parameter(Mandatory = $true)]
        [string]$TaskFolderPath,

        [Parameter(Mandatory = $true)]
        [string]$SelectedEncoder,

        [Parameter(Mandatory = $true)]
        [bool]$ReplaceOriginalValue,

        [Parameter(Mandatory = $true)]
        [bool]$KeepBackupValue,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $TaskItem.status = "failed"
    $TaskItem.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
    $TaskItem.lastResult = $FailureMessage
    $TaskItem.replacedOriginal = $false
    Save-TaskArtifacts -TaskFolderPath $TaskFolderPath -TaskObject $TaskObject
    Append-HistoryLine -TaskFolder $TaskFolderPath -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $TaskItem.path, $SelectedEncoder, $TaskObject.targetKbps, "failed", $ReplaceOriginalValue, $KeepBackupValue, $FailureMessage)
}

function Reset-TaskItemToPending {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TaskItem,

        [Parameter(Mandatory = $true)]
        [object]$TaskObject,

        [Parameter(Mandatory = $true)]
        [string]$TaskFolderPath,

        [Parameter(Mandatory = $true)]
        [string]$SelectedEncoder,

        [Parameter(Mandatory = $true)]
        [bool]$ReplaceOriginalValue,

        [Parameter(Mandatory = $true)]
        [bool]$KeepBackupValue,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    $TaskItem.status = "pending"
    $TaskItem.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
    $TaskItem.lastResult = $Reason
    $TaskItem.replacedOriginal = $false
    Save-TaskArtifacts -TaskFolderPath $TaskFolderPath -TaskObject $TaskObject
    Append-HistoryLine -TaskFolder $TaskFolderPath -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $TaskItem.path, $SelectedEncoder, $TaskObject.targetKbps, "interrupted", $ReplaceOriginalValue, $KeepBackupValue, $Reason)
}

$taskRoot = Get-TaskRootPath
Ensure-Directory -Path $taskRoot

if (-not $PSBoundParameters.ContainsKey("TaskFolder")) {
    $TaskFolder = Read-RequiredInput -Prompt "任务目录"
}

$resolvedTaskFolder = (Resolve-Path -LiteralPath $TaskFolder).Path

Assert-RequiredVideoTools -RequireFfmpeg -RequireFfprobe
$ffmpegPath = Resolve-ToolPath -CommandName "ffmpeg.exe" -LocalFileName "ffmpeg.exe"

$task = Read-TaskFile -TaskFolder $resolvedTaskFolder
$task.updatedAt = [DateTime]::UtcNow.ToString("o")

$replaceOriginal = $false
$keepBackup = $false
$encoderForRecoveryLog = if ($Encoder) { $Encoder } else { "-" }

$resetProcessingCount = 0
$removedTempFileCount = 0
$staleTempFilesByPath = @{}
foreach ($item in @($task.items | Where-Object { $_.status -ne "done" -and -not [string]::IsNullOrWhiteSpace($_.path) })) {
    foreach ($tempFile in @(Get-TemporaryOutputFilesForInput -InputPath $item.path)) {
        $tempKey = $tempFile.FullName.ToLowerInvariant()
        if (-not $staleTempFilesByPath.ContainsKey($tempKey)) {
            $staleTempFilesByPath[$tempKey] = $tempFile
        }
    }
}

foreach ($tempFile in $staleTempFilesByPath.Values) {
    try {
        Remove-Item -LiteralPath $tempFile.FullName -Force
        $removedTempFileCount++
    } catch {
        Write-Host ("警告: 无法删除临时文件 {0}" -f $tempFile.FullName) -ForegroundColor Yellow
    }
}

foreach ($item in @($task.items | Where-Object { $_.status -eq "processing" })) {
    $item.status = "pending"
    $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
    $item.lastResult = "检测到上次执行中断，已在本次启动前重置为待处理。"
    $item.replacedOriginal = $false
    $resetProcessingCount++
}

if ($resetProcessingCount -gt 0 -or $removedTempFileCount -gt 0) {
    Save-TaskArtifacts -TaskFolderPath $resolvedTaskFolder -TaskObject $task
    Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), "-", $encoderForRecoveryLog, $task.targetKbps, "reset_processing", $replaceOriginal, $keepBackup, ("恢复了 {0} 个中断项目，删除了 {1} 个临时文件" -f $resetProcessingCount, $removedTempFileCount))
    if ($resetProcessingCount -gt 0) {
        Write-Host ("检测到 {0} 个上次中断的处理中项目，已重置为待处理。" -f $resetProcessingCount) -ForegroundColor Yellow
    }
    if ($removedTempFileCount -gt 0) {
        Write-Host ("已清理遗留临时文件 {0} 个。" -f $removedTempFileCount) -ForegroundColor Yellow
    }
}

$pendingAvailableCount = @($task.items | Where-Object { $_.status -eq "pending" }).Count
if ($pendingAvailableCount -eq 0) {
    Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
    Write-Host "没有可处理的待压缩项目。" -ForegroundColor Yellow
    exit 0
}

if (-not $PSBoundParameters.ContainsKey("Count")) {
    $Count = Read-IntOrDefault -Prompt "本次要处理多少个文件" -DefaultValue $pendingAvailableCount
}

if ($Count -gt $pendingAvailableCount) {
    Write-Host ("输入数量大于待处理总数，已自动按剩余待处理数量 {0} 执行。" -f $pendingAvailableCount) -ForegroundColor Yellow
    $Count = $pendingAvailableCount
}

if (-not $PSBoundParameters.ContainsKey("ParallelCount")) {
    $ParallelCount = Read-IntOrDefault -Prompt "并行任务数（当前支持 1 或 2）" -DefaultValue 1
}

if ($ParallelCount -notin @(1, 2)) {
    throw "并行任务数当前只支持 1 或 2。"
}

if (-not $PSBoundParameters.ContainsKey("Encoder")) {
    $Encoder = Read-ChoiceOrDefault -Prompt "编码器" -Choices @("qsv", "nvenc", "amf", "cpu") -DefaultValue "qsv"
}

if (-not $PSBoundParameters.ContainsKey("AudioCodec")) {
    $AudioCodec = Read-ChoiceOrDefault -Prompt "音频编码器" -Choices @("aac", "libfdk_aac") -DefaultValue "aac"
}

Assert-AudioCodecSupported -FfmpegPath $ffmpegPath -AudioCodec $AudioCodec

if (-not $PSBoundParameters.ContainsKey("ReplaceOriginalMode")) {
    $ReplaceOriginalMode = if (Read-YesNoOrDefault -Prompt "压缩成功后是否替换原文件" -DefaultValue $true) { "yes" } else { "no" }
}

if (-not $PSBoundParameters.ContainsKey("KeepBackupMode")) {
    $KeepBackupMode = if (Read-YesNoOrDefault -Prompt "替换原文件时是否保留备份" -DefaultValue $false) { "yes" } else { "no" }
}

$replaceOriginal = ($ReplaceOriginalMode -eq "yes")
$keepBackup = ($KeepBackupMode -eq "yes")
$task.encoderPreference = $Encoder

$pendingItems = @($task.items | Where-Object { $_.status -eq "pending" } | Select-Object -First $Count)
if (-not $pendingItems -or $pendingItems.Count -eq 0) {
    Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
    Write-Host "没有可处理的待压缩项目。" -ForegroundColor Yellow
    exit 0
}

$encoderScriptByName = @{
    qsv = Join-Path -Path $PSScriptRoot -ChildPath "encode-hevc-qsv-ffmpeg.ps1"
    nvenc = Join-Path -Path $PSScriptRoot -ChildPath "encode-hevc-nvenc-ffmpeg.ps1"
    amf = Join-Path -Path $PSScriptRoot -ChildPath "encode-hevc-amf-ffmpeg.ps1"
    cpu = Join-Path -Path $PSScriptRoot -ChildPath "encode-hevc-cpu-ffmpeg.ps1"
}

$encoderScriptPath = $encoderScriptByName[$Encoder]
if (-not (Test-Path -LiteralPath $encoderScriptPath)) {
    throw "找不到编码脚本: $encoderScriptPath"
}

$batchTotalCount = $pendingItems.Count
$batchTotalMediaSec = Get-SumOrZero -Items $pendingItems -PropertyName "durationSec"
$batchCompletedMediaSec = 0.0
$batchStartedAtUtc = [DateTime]::UtcNow
$processed = 0
$failedCount = 0
$skippedCount = 0
$workingDirectory = $PSScriptRoot

if ($ParallelCount -eq 1) {
    $batchIndex = 0
    foreach ($item in $pendingItems) {
        $batchIndex++

        Write-Host ""
        Write-Host ("当前项目 {0}/{1}" -f $batchIndex, $batchTotalCount) -ForegroundColor Cyan
        Write-Host ("源文件: {0}" -f $item.path) -ForegroundColor DarkGray

        $env:VIDEO_COMPASS_BATCH_TOTAL_COUNT = [string]$batchTotalCount
        $env:VIDEO_COMPASS_BATCH_CURRENT_INDEX = [string]$batchIndex
        $env:VIDEO_COMPASS_BATCH_TOTAL_MEDIA_SEC = $batchTotalMediaSec.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $env:VIDEO_COMPASS_BATCH_COMPLETED_MEDIA_SEC = $batchCompletedMediaSec.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $env:VIDEO_COMPASS_BATCH_STARTED_AT_UTC = $batchStartedAtUtc.ToString("o")

        if (-not (Test-Path -LiteralPath $item.path)) {
            $item.status = "skipped"
            $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
            $item.lastResult = "源文件已不存在。"
            Save-TaskArtifacts -TaskFolderPath $resolvedTaskFolder -TaskObject $task
            Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $item.path, $Encoder, $task.targetKbps, "skipped", $replaceOriginal, $keepBackup, "源文件不存在")
            $skippedCount++
            $batchCompletedMediaSec += [double]$item.durationSec
            continue
        }

        $item.status = "processing"
        $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
        $item.lastResult = "正在使用 $Encoder 处理。"
        Save-TaskArtifacts -TaskFolderPath $resolvedTaskFolder -TaskObject $task
        Set-VideoCompassActiveTaskContext -TaskFolder $resolvedTaskFolder -Task $task -Item $item -Encoder $Encoder -ReplaceOriginal:$replaceOriginal -KeepBackup:$keepBackup

        try {
            $scriptArgs = New-EncodeScriptArgs -TaskItem $item -TaskObject $task -SelectedAudioCodec $AudioCodec -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup
            & $encoderScriptPath @scriptArgs

            if ($global:VideoCompassShutdownRequested) {
                throw ($global:VideoCompassShutdownReason)
            }

            Complete-TaskItemSuccess -TaskItem $item -TaskObject $task -TaskFolderPath $resolvedTaskFolder -SelectedEncoder $Encoder -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup
            $processed++
        } catch {
            if ($global:VideoCompassShutdownRequested) {
                Write-Host ("检测到脚本中断，当前项目已重置为待处理: {0}" -f $item.path) -ForegroundColor Yellow
                break
            }

            Complete-TaskItemFailure -TaskItem $item -TaskObject $task -TaskFolderPath $resolvedTaskFolder -SelectedEncoder $Encoder -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup -FailureMessage $_.Exception.Message
            $failedCount++
            Write-Host "处理失败: $($item.path)" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        } finally {
            Clear-VideoCompassActiveTaskContext
            $batchCompletedMediaSec += [double]$item.durationSec
        }
    }
} else {
    $jobQueue = [System.Collections.Queue]::new()
    foreach ($item in $pendingItems) {
        $jobQueue.Enqueue($item)
    }

    $activeWorkers = New-Object System.Collections.Generic.List[object]
    $launchIndex = 0

    while ($jobQueue.Count -gt 0 -or $activeWorkers.Count -gt 0) {
        while (($activeWorkers.Count -lt $ParallelCount) -and ($jobQueue.Count -gt 0)) {
            $item = $jobQueue.Dequeue()
            $launchIndex++

            if (-not (Test-Path -LiteralPath $item.path)) {
                $item.status = "skipped"
                $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
                $item.lastResult = "源文件已不存在。"
                Save-TaskArtifacts -TaskFolderPath $resolvedTaskFolder -TaskObject $task
                Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $item.path, $Encoder, $task.targetKbps, "skipped", $replaceOriginal, $keepBackup, "源文件不存在")
                $skippedCount++
                continue
            }

            Write-Host ""
            Write-Host ("启动并行任务 {0}/{1}" -f $launchIndex, $batchTotalCount) -ForegroundColor Cyan
            Write-Host ("源文件: {0}" -f $item.path) -ForegroundColor DarkGray

            $item.status = "processing"
            $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
            $item.lastResult = "正在使用 $Encoder 并行处理。"
            Save-TaskArtifacts -TaskFolderPath $resolvedTaskFolder -TaskObject $task

            $scriptArgs = New-EncodeScriptArgs -TaskItem $item -TaskObject $task -SelectedAudioCodec $AudioCodec -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup
            $job = Start-EncodeJobWorker -ScriptPath $encoderScriptPath -ScriptArgs $scriptArgs -WorkingDirectory $workingDirectory
            $activeWorkers.Add([pscustomobject]@{
                Job = $job
                Item = $item
            })
        }

        $completedCount = $processed + $failedCount + $skippedCount
        Update-ParallelBatchProgress -BatchTotalCount $batchTotalCount -CompletedCount $completedCount -RunningCount $activeWorkers.Count -BatchStartedAtUtc $batchStartedAtUtc

        if ($global:VideoCompassShutdownRequested) {
            foreach ($worker in $activeWorkers.ToArray()) {
                try {
                    Stop-Job -Job $worker.Job -ErrorAction SilentlyContinue | Out-Null
                } catch {
                }

                Reset-TaskItemToPending -TaskItem $worker.Item -TaskObject $task -TaskFolderPath $resolvedTaskFolder -SelectedEncoder $Encoder -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup -Reason "父任务中断，已重置为待处理。"
                try {
                    Remove-Job -Job $worker.Job -Force -ErrorAction SilentlyContinue
                } catch {
                }
            }

            $activeWorkers.Clear()
            break
        }

        $completedWorkers = @()
        foreach ($worker in $activeWorkers.ToArray()) {
            if ($worker.Job.State -in @("Completed", "Failed", "Stopped")) {
                $completedWorkers += $worker
            }
        }

        if ($completedWorkers.Count -eq 0) {
            Start-Sleep -Milliseconds 500
            continue
        }

        foreach ($worker in $completedWorkers) {
            $receivedItems = @()
            try {
                $receivedItems = @(Receive-Job -Job $worker.Job -Keep -ErrorAction SilentlyContinue)
            } catch {
            }

            $resultObject = $receivedItems | Where-Object { $_.PSObject.Properties.Match("Success").Count -gt 0 } | Select-Object -Last 1
            if ($resultObject -and $resultObject.Success) {
                Complete-TaskItemSuccess -TaskItem $worker.Item -TaskObject $task -TaskFolderPath $resolvedTaskFolder -SelectedEncoder $Encoder -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup
                $processed++
                $batchCompletedMediaSec += [double]$worker.Item.durationSec
            } else {
                $message = "编码任务失败。"
                if ($resultObject -and $resultObject.Message) {
                    $message = [string]$resultObject.Message
                } elseif ($worker.Job.JobStateInfo.Reason) {
                    $message = $worker.Job.JobStateInfo.Reason.Message
                }

                Complete-TaskItemFailure -TaskItem $worker.Item -TaskObject $task -TaskFolderPath $resolvedTaskFolder -SelectedEncoder $Encoder -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup -FailureMessage $message
                $failedCount++
                $batchCompletedMediaSec += [double]$worker.Item.durationSec
                Write-Host "处理失败: $($worker.Item.path)" -ForegroundColor Red
                Write-Host $message -ForegroundColor Yellow
            }

            try {
                Remove-Job -Job $worker.Job -Force -ErrorAction SilentlyContinue
            } catch {
            }

            [void]$activeWorkers.Remove($worker)
        }
    }
}

Write-Progress -Id 1 -Activity "正在压缩当前文件" -Completed
Write-Progress -Id 2 -Activity "批量压缩任务" -Completed

Remove-Item Env:VIDEO_COMPASS_BATCH_TOTAL_COUNT -ErrorAction SilentlyContinue
Remove-Item Env:VIDEO_COMPASS_BATCH_CURRENT_INDEX -ErrorAction SilentlyContinue
Remove-Item Env:VIDEO_COMPASS_BATCH_TOTAL_MEDIA_SEC -ErrorAction SilentlyContinue
Remove-Item Env:VIDEO_COMPASS_BATCH_COMPLETED_MEDIA_SEC -ErrorAction SilentlyContinue
Remove-Item Env:VIDEO_COMPASS_BATCH_STARTED_AT_UTC -ErrorAction SilentlyContinue

$remainingPending = @($task.items | Where-Object { $_.status -eq "pending" }).Count

Write-Host ""
Write-Host "本次完成数量: $processed"
Write-Host "本次失败数量: $failedCount"
Write-Host "本次跳过数量: $skippedCount"
Write-Host "剩余待处理数量: $remainingPending"
Write-Host "任务目录: $resolvedTaskFolder"
