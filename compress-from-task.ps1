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

function Resolve-WorkerPowerShellPath {
    $candidates = @(
        (Join-Path -Path $PSHOME -ChildPath "powershell.exe"),
        (Join-Path -Path $PSHOME -ChildPath "pwsh.exe")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "找不到可用的 PowerShell 可执行文件。"
}

function New-ParallelWorkerFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolderPath,

        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [int]$SlotId
    )

    $token = [System.Guid]::NewGuid().ToString("N")
    return (Join-Path -Path $TaskFolderPath -ChildPath (".{0}-slot{1}-{2}.json" -f $Prefix, $SlotId, $token))
}

function Read-ParallelWorkerPayload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $null
    }

    try {
        return ((Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Wait-ForParallelWorkerPayload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [int]$RetryCount = 20,

        [int]$DelayMilliseconds = 100
    )

    for ($attempt = 0; $attempt -lt $RetryCount; $attempt++) {
        $payload = Read-ParallelWorkerPayload -FilePath $FilePath
        if ($payload) {
            return $payload
        }

        Start-Sleep -Milliseconds $DelayMilliseconds
    }

    return $null
}

function Clear-ParallelWorkerArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Worker
    )

    foreach ($path in @($Worker.ProgressFilePath, $Worker.ResultFilePath)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Update-ParallelWorkerProgressDisplays {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$ActiveWorkers,

        [Parameter(Mandatory = $true)]
        [int]$ParallelTotal
    )

    $activeBySlot = @{}
    foreach ($worker in $ActiveWorkers) {
        $activeBySlot[[string]$worker.SlotId] = $worker
    }

    for ($slotId = 1; $slotId -le $ParallelTotal; $slotId++) {
        $progressId = 20 + $slotId
        $slotKey = [string]$slotId
        if (-not $activeBySlot.ContainsKey($slotKey)) {
            Write-Progress -Id $progressId -Activity ("并行任务槽位 {0}" -f $slotId) -Completed
            continue
        }

        $worker = $activeBySlot[$slotKey]
        $payload = Read-ParallelWorkerPayload -FilePath $worker.ProgressFilePath
        if ($payload) {
            $statusParts = New-Object System.Collections.Generic.List[string]
            if ($payload.label) {
                $statusParts.Add([string]$payload.label)
            }
            if ($payload.status) {
                $statusParts.Add([string]$payload.status)
            }

            Write-Progress -Id $progressId -Activity ("并行任务槽位 {0}" -f $slotId) -Status ($statusParts -join " | ") -PercentComplete ([double]$payload.percent)
        } else {
            Write-Progress -Id $progressId -Activity ("并行任务槽位 {0}" -f $slotId) -Status "等待进度上报..." -PercentComplete 0
        }
    }
}

function Start-EncodeJobWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$ScriptArgs,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$TaskFolderPath,

        [Parameter(Mandatory = $true)]
        [int]$SlotId,

        [Parameter(Mandatory = $true)]
        [IntPtr]$HostJobHandle
    )

    $workerPowerShellPath = Resolve-WorkerPowerShellPath
    $workerScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "invoke-encode-worker.ps1"
    $progressFilePath = New-ParallelWorkerFilePath -TaskFolderPath $TaskFolderPath -Prefix "parallel-progress" -SlotId $SlotId
    $resultFilePath = New-ParallelWorkerFilePath -TaskFolderPath $TaskFolderPath -Prefix "parallel-result" -SlotId $SlotId
    $progressLabel = [System.IO.Path]::GetFileName($ScriptArgs.InputPath)

    $argumentList = New-Object System.Collections.Generic.List[string]
    $argumentList.Add("-NoProfile")
    $argumentList.Add("-ExecutionPolicy")
    $argumentList.Add("Bypass")
    $argumentList.Add("-File")
    $argumentList.Add($workerScriptPath)
    $argumentList.Add("-EncoderScriptPath")
    $argumentList.Add($ScriptPath)
    $argumentList.Add("-InputPath")
    $argumentList.Add([string]$ScriptArgs.InputPath)
    $argumentList.Add("-VideoBitrateKbps")
    $argumentList.Add([string]$ScriptArgs.VideoBitrateKbps)
    $argumentList.Add("-AudioBitrateKbps")
    $argumentList.Add([string]$ScriptArgs.AudioBitrateKbps)
    $argumentList.Add("-AudioSampleRate")
    $argumentList.Add([string]$ScriptArgs.AudioSampleRate)
    $argumentList.Add("-AudioCodec")
    $argumentList.Add([string]$ScriptArgs.AudioCodec)
    $argumentList.Add("-DurationToleranceSec")
    $argumentList.Add(([double]$ScriptArgs.DurationToleranceSec).ToString([System.Globalization.CultureInfo]::InvariantCulture))
    $argumentList.Add("-ProgressFilePath")
    $argumentList.Add($progressFilePath)
    $argumentList.Add("-ResultFilePath")
    $argumentList.Add($resultFilePath)
    $argumentList.Add("-ProgressLabel")
    $argumentList.Add($progressLabel)
    $argumentList.Add("-SupervisorPid")
    $argumentList.Add([string]$PID)
    if ($ScriptArgs.ContainsKey("ReplaceOriginal") -and $ScriptArgs.ReplaceOriginal) {
        $argumentList.Add("-ReplaceOriginal")
    }
    if ($ScriptArgs.ContainsKey("KeepBackup") -and $ScriptArgs.KeepBackup) {
        $argumentList.Add("-KeepBackup")
    }

    $process = Start-Process -FilePath $workerPowerShellPath -ArgumentList $argumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
    Add-VideoCompassProcessToJob -JobHandle $HostJobHandle -Process $process

    return [pscustomobject]@{
        Process = $process
        ProgressFilePath = $progressFilePath
        ResultFilePath = $resultFilePath
        SlotId = $SlotId
    }
}

function Update-TaskItemWithEncodeResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TaskItem,

        [AllowNull()]
        [object]$EncodeResult
    )

    if (-not $EncodeResult) {
        return
    }

    $shouldUpdatePath = $false
    if ($EncodeResult.PSObject.Properties.Match("ReplacedOriginal").Count -gt 0) {
        $shouldUpdatePath = [bool]$EncodeResult.ReplacedOriginal
    }

    if ($shouldUpdatePath -and $EncodeResult.PSObject.Properties.Match("OutputPath").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($EncodeResult.OutputPath)) {
        $TaskItem.path = [string]$EncodeResult.OutputPath
    }
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
        [bool]$KeepBackupValue,

        [AllowNull()]
        [object]$EncodeResult
    )

    Update-TaskItemWithEncodeResult -TaskItem $TaskItem -EncodeResult $EncodeResult
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

function Stop-OrphanedEncodeProcessesForTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolderPath,

        [Parameter(Mandatory = $true)]
        [object]$TaskObject
    )

    $matchedProcessIds = New-Object System.Collections.Generic.HashSet[int]
    $taskFolderLower = $TaskFolderPath.ToLowerInvariant()
    $inputPathsLower = @(
        $TaskObject.items |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.path) } |
            ForEach-Object { ([string]$_.path).ToLowerInvariant() }
    )

    $candidateProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.Name -in @("powershell.exe", "pwsh.exe", "ffmpeg.exe")
    })

    foreach ($processInfo in $candidateProcesses) {
        $commandLineLower = ([string]$processInfo.CommandLine).ToLowerInvariant()
        $shouldStop = $false

        if (($processInfo.Name -in @("powershell.exe", "pwsh.exe")) -and $commandLineLower.Contains("invoke-encode-worker.ps1") -and $commandLineLower.Contains($taskFolderLower)) {
            $shouldStop = $true
        } elseif ($processInfo.Name -eq "ffmpeg.exe") {
            foreach ($inputPathLower in $inputPathsLower) {
                if ($commandLineLower.Contains($inputPathLower)) {
                    $shouldStop = $true
                    break
                }
            }
        }

        if ($shouldStop) {
            [void]$matchedProcessIds.Add([int]$processInfo.ProcessId)
        }
    }

    $stoppedCount = 0
    foreach ($processId in $matchedProcessIds) {
        try {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            $stoppedCount++
        } catch {
        }
    }

    return $stoppedCount
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
$removedParallelStateFileCount = 0
$stoppedOrphanProcessCount = Stop-OrphanedEncodeProcessesForTask -TaskFolderPath $resolvedTaskFolder -TaskObject $task
$staleTempFilesByPath = @{}
foreach ($item in @($task.items | Where-Object { $_.status -ne "done" -and -not [string]::IsNullOrWhiteSpace($_.path) })) {
    foreach ($tempFile in @(Get-TemporaryOutputFilesForInput -InputPath $item.path)) {
        $tempKey = $tempFile.FullName.ToLowerInvariant()
        if (-not $staleTempFilesByPath.ContainsKey($tempKey)) {
            $staleTempFilesByPath[$tempKey] = $tempFile
        }
    }
}

foreach ($parallelStateFile in @(Get-ChildItem -LiteralPath $resolvedTaskFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.parallel-progress-*.json' -or $_.Name -like '.parallel-result-*.json' })) {
    try {
        Remove-Item -LiteralPath $parallelStateFile.FullName -Force
        $removedParallelStateFileCount++
    } catch {
        Write-Host ("警告: 无法删除并行状态文件 {0}" -f $parallelStateFile.FullName) -ForegroundColor Yellow
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

if ($resetProcessingCount -gt 0 -or $removedTempFileCount -gt 0 -or $removedParallelStateFileCount -gt 0 -or $stoppedOrphanProcessCount -gt 0) {
    Save-TaskArtifacts -TaskFolderPath $resolvedTaskFolder -TaskObject $task
    Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), "-", $encoderForRecoveryLog, $task.targetKbps, "reset_processing", $replaceOriginal, $keepBackup, ("恢复了 {0} 个中断项目，删除了 {1} 个临时文件，删除了 {2} 个并行状态文件，停止了 {3} 个遗留编码进程" -f $resetProcessingCount, $removedTempFileCount, $removedParallelStateFileCount, $stoppedOrphanProcessCount))
    if ($resetProcessingCount -gt 0) {
        Write-Host ("检测到 {0} 个上次中断的处理中项目，已重置为待处理。" -f $resetProcessingCount) -ForegroundColor Yellow
    }
    if ($removedTempFileCount -gt 0) {
        Write-Host ("已清理遗留临时文件 {0} 个。" -f $removedTempFileCount) -ForegroundColor Yellow
    }
    if ($removedParallelStateFileCount -gt 0) {
        Write-Host ("已清理遗留并行状态文件 {0} 个。" -f $removedParallelStateFileCount) -ForegroundColor Yellow
    }
    if ($stoppedOrphanProcessCount -gt 0) {
        Write-Host ("已停止遗留编码进程 {0} 个。" -f $stoppedOrphanProcessCount) -ForegroundColor Yellow
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
    Write-Host "请选择编码器：" -ForegroundColor Cyan
    $Encoder = Read-MenuChoiceOrDefault -Prompt "输入编号" -Options @{
        "1" = "qsv"
        "2" = "nvenc"
        "3" = "amf"
        "4" = "cpu"
    } -DefaultKey "1"
}

if (-not $PSBoundParameters.ContainsKey("AudioCodec")) {
    $AudioCodec = Read-ChoiceOrDefault -Prompt "音频编码器" -Choices @("aac", "libfdk_aac") -DefaultValue "aac"
}

Assert-AudioCodecSupported -FfmpegPath $ffmpegPath -AudioCodec $AudioCodec

if (($Encoder -eq "nvenc") -and ($ParallelCount -gt 1)) {
    Write-Host "提示: NVENC 双并行会同时占用两路编码任务，建议先确认显卡驱动和显存稳定；脚本会为每个任务单独创建临时输出文件。" -ForegroundColor Yellow
}

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
$parallelWorkerHostJobHandle = [IntPtr]::Zero

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
            $encodeResult = & $encoderScriptPath @scriptArgs

            if ($global:VideoCompassShutdownRequested) {
                throw ($global:VideoCompassShutdownReason)
            }

            $finalEncodeResult = $encodeResult | Select-Object -Last 1
            Complete-TaskItemSuccess -TaskItem $item -TaskObject $task -TaskFolderPath $resolvedTaskFolder -SelectedEncoder $Encoder -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup -EncodeResult $finalEncodeResult
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

    $availableSlots = [System.Collections.Queue]::new()
    for ($slotId = 1; $slotId -le $ParallelCount; $slotId++) {
        $availableSlots.Enqueue($slotId)
    }

    $activeWorkers = New-Object System.Collections.Generic.List[object]
    $launchIndex = 0
    $parallelWorkerHostJobHandle = New-VideoCompassKillOnCloseJob

    try {
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

                $slotId = [int]$availableSlots.Dequeue()

                Write-Host ""
                Write-Host ("启动并行任务 {0}/{1}（槽位 {2}）" -f $launchIndex, $batchTotalCount, $slotId) -ForegroundColor Cyan
                Write-Host ("源文件: {0}" -f $item.path) -ForegroundColor DarkGray

                $item.status = "processing"
                $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
                $item.lastResult = "正在使用 $Encoder 并行处理。"
                Save-TaskArtifacts -TaskFolderPath $resolvedTaskFolder -TaskObject $task

                $scriptArgs = New-EncodeScriptArgs -TaskItem $item -TaskObject $task -SelectedAudioCodec $AudioCodec -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup
                $workerRuntime = Start-EncodeJobWorker -ScriptPath $encoderScriptPath -ScriptArgs $scriptArgs -WorkingDirectory $workingDirectory -TaskFolderPath $resolvedTaskFolder -SlotId $slotId -HostJobHandle $parallelWorkerHostJobHandle
                $activeWorkers.Add([pscustomobject]@{
                    Process = $workerRuntime.Process
                    ProgressFilePath = $workerRuntime.ProgressFilePath
                    ResultFilePath = $workerRuntime.ResultFilePath
                    SlotId = $slotId
                    Item = $item
                })
            }

            Update-ParallelWorkerProgressDisplays -ActiveWorkers $activeWorkers -ParallelTotal $ParallelCount

            $completedCount = $processed + $failedCount + $skippedCount
            Update-ParallelBatchProgress -BatchTotalCount $batchTotalCount -CompletedCount $completedCount -RunningCount $activeWorkers.Count -BatchStartedAtUtc $batchStartedAtUtc

            if ($global:VideoCompassShutdownRequested) {
                if ($parallelWorkerHostJobHandle -ne [IntPtr]::Zero) {
                    try {
                        Close-VideoCompassJobHandle -JobHandle $parallelWorkerHostJobHandle
                    } catch {
                    }
                    $parallelWorkerHostJobHandle = [IntPtr]::Zero
                }

                foreach ($worker in $activeWorkers.ToArray()) {
                    Reset-TaskItemToPending -TaskItem $worker.Item -TaskObject $task -TaskFolderPath $resolvedTaskFolder -SelectedEncoder $Encoder -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup -Reason "父任务中断，已重置为待处理。"
                    Clear-ParallelWorkerArtifacts -Worker $worker
                    Write-Progress -Id (20 + $worker.SlotId) -Activity ("并行任务槽位 {0}" -f $worker.SlotId) -Completed
                }

                $activeWorkers.Clear()
                break
            }

            $completedWorkers = @()
            foreach ($worker in $activeWorkers.ToArray()) {
                if ($worker.Process.HasExited) {
                    $completedWorkers += $worker
                }
            }

            if ($completedWorkers.Count -eq 0) {
                Start-Sleep -Milliseconds 500
                continue
            }

            foreach ($worker in $completedWorkers) {
                $resultObject = Wait-ForParallelWorkerPayload -FilePath $worker.ResultFilePath
                if ($resultObject -and $resultObject.Success) {
                    Complete-TaskItemSuccess -TaskItem $worker.Item -TaskObject $task -TaskFolderPath $resolvedTaskFolder -SelectedEncoder $Encoder -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup -EncodeResult $resultObject
                    $processed++
                    $batchCompletedMediaSec += [double]$worker.Item.durationSec
                } else {
                    $message = "编码任务失败。"
                    if ($resultObject -and $resultObject.Message) {
                        $message = [string]$resultObject.Message
                    } elseif ($worker.Process.ExitCode -ne 0) {
                        $message = ("编码工作进程退出码 {0}" -f $worker.Process.ExitCode)
                    }

                    Complete-TaskItemFailure -TaskItem $worker.Item -TaskObject $task -TaskFolderPath $resolvedTaskFolder -SelectedEncoder $Encoder -ReplaceOriginalValue $replaceOriginal -KeepBackupValue $keepBackup -FailureMessage $message
                    $failedCount++
                    $batchCompletedMediaSec += [double]$worker.Item.durationSec
                    Write-Host "处理失败: $($worker.Item.path)" -ForegroundColor Red
                    Write-Host $message -ForegroundColor Yellow
                }

                Write-Progress -Id (20 + $worker.SlotId) -Activity ("并行任务槽位 {0}" -f $worker.SlotId) -Completed
                Clear-ParallelWorkerArtifacts -Worker $worker
                $availableSlots.Enqueue($worker.SlotId)
                [void]$activeWorkers.Remove($worker)
            }
        }
    } finally {
        if ($parallelWorkerHostJobHandle -ne [IntPtr]::Zero) {
            try {
                Close-VideoCompassJobHandle -JobHandle $parallelWorkerHostJobHandle
            } catch {
            }
        }
    }
}

Write-Progress -Id 1 -Activity "正在压缩当前文件" -Completed
Write-Progress -Id 2 -Activity "批量压缩任务" -Completed
Write-Progress -Id 21 -Activity "并行任务槽位 1" -Completed
Write-Progress -Id 22 -Activity "并行任务槽位 2" -Completed

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
