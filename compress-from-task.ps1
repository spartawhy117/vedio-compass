param(
    [string]$TaskFolder,
    [int]$Count,
    [ValidateSet("qsv", "nvenc", "amf", "cpu")]
    [string]$Encoder,
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

$taskRoot = Get-TaskRootPath
Ensure-Directory -Path $taskRoot

if (-not $PSBoundParameters.ContainsKey("TaskFolder")) {
    $TaskFolder = Read-RequiredInput -Prompt "任务目录"
}

$resolvedTaskFolder = (Resolve-Path -LiteralPath $TaskFolder).Path

Assert-RequiredVideoTools -RequireFfmpeg -RequireFfprobe

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
    $task.updatedAt = [DateTime]::UtcNow.ToString("o")
    Save-TaskFile -TaskFolder $resolvedTaskFolder -Task $task
    Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
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

if (-not $PSBoundParameters.ContainsKey("Encoder")) {
    $Encoder = Read-ChoiceOrDefault -Prompt "编码器" -Choices @("qsv", "nvenc", "amf", "cpu") -DefaultValue "qsv"
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
        $task.updatedAt = [DateTime]::UtcNow.ToString("o")
        Save-TaskFile -TaskFolder $resolvedTaskFolder -Task $task
        Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
        Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $item.path, $Encoder, $task.targetKbps, "skipped", $replaceOriginal, $keepBackup, "源文件不存在")
        $batchCompletedMediaSec += [double]$item.durationSec
        continue
    }

    $item.status = "processing"
    $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
    $item.lastResult = "正在使用 $Encoder 处理。"
    $task.updatedAt = [DateTime]::UtcNow.ToString("o")
    Save-TaskFile -TaskFolder $resolvedTaskFolder -Task $task
    Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
    Set-VideoCompassActiveTaskContext -TaskFolder $resolvedTaskFolder -Task $task -Item $item -Encoder $Encoder -ReplaceOriginal:$replaceOriginal -KeepBackup:$keepBackup

    try {
        $scriptArgs = @{
            InputPath = $item.path
            VideoBitrateKbps = [int]$task.targetKbps
            AudioBitrateKbps = [int]$task.audioBitrateKbps
            AudioSampleRate = [int]$task.audioSampleRate
            DurationToleranceSec = 2.0
        }

        if ($replaceOriginal) {
            $scriptArgs.ReplaceOriginal = $true
        }

        if ($keepBackup) {
            $scriptArgs.KeepBackup = $true
        }

        & $encoderScriptPath @scriptArgs

        if ($global:VideoCompassShutdownRequested) {
            throw ($global:VideoCompassShutdownReason)
        }

        $item.status = "done"
        $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
        $item.lastResult = "已使用 $Encoder 完成处理。"
        $item.replacedOriginal = $replaceOriginal
        $task.updatedAt = [DateTime]::UtcNow.ToString("o")
        Save-TaskFile -TaskFolder $resolvedTaskFolder -Task $task
        Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
        Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $item.path, $Encoder, $task.targetKbps, "done", $replaceOriginal, $keepBackup, "已完成")
        $processed++
    } catch {
        if ($global:VideoCompassShutdownRequested) {
            Write-Host ("检测到脚本中断，当前项目已重置为待处理: {0}" -f $item.path) -ForegroundColor Yellow
            break
        }

        $item.status = "failed"
        $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
        $item.lastResult = $_.Exception.Message
        $item.replacedOriginal = $false
        $task.updatedAt = [DateTime]::UtcNow.ToString("o")
        Save-TaskFile -TaskFolder $resolvedTaskFolder -Task $task
        Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
        Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $item.path, $Encoder, $task.targetKbps, "failed", $replaceOriginal, $keepBackup, $_.Exception.Message)
        Write-Host "处理失败: $($item.path)" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    } finally {
        Clear-VideoCompassActiveTaskContext
        $batchCompletedMediaSec += [double]$item.durationSec
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
Write-Host "剩余待处理数量: $remainingPending"
Write-Host "任务目录: $resolvedTaskFolder"
