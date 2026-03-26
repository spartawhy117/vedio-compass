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

$taskRoot = Get-TaskRootPath
Ensure-Directory -Path $taskRoot

if (-not $PSBoundParameters.ContainsKey("TaskFolder")) {
    $TaskFolder = Read-InputOrDefault -Prompt "Task folder" -DefaultValue $taskRoot
}

$resolvedTaskFolder = (Resolve-Path -LiteralPath $TaskFolder).Path

if (-not $PSBoundParameters.ContainsKey("Count")) {
    $Count = Read-IntOrDefault -Prompt "How many files to process this run" -DefaultValue 1
}

if (-not $PSBoundParameters.ContainsKey("Encoder")) {
    $Encoder = Read-ChoiceOrDefault -Prompt "Encoder" -Choices @("qsv", "nvenc", "amf", "cpu") -DefaultValue "qsv"
}

if (-not $PSBoundParameters.ContainsKey("ReplaceOriginalMode")) {
    $ReplaceOriginalMode = if (Read-YesNoOrDefault -Prompt "Replace originals after successful encode" -DefaultValue $true) { "yes" } else { "no" }
}

if (-not $PSBoundParameters.ContainsKey("KeepBackupMode")) {
    $KeepBackupMode = if (Read-YesNoOrDefault -Prompt "Keep backup copy when replacing originals" -DefaultValue $false) { "yes" } else { "no" }
}

$replaceOriginal = ($ReplaceOriginalMode -eq "yes")
$keepBackup = ($KeepBackupMode -eq "yes")

$task = Read-TaskFile -TaskFolder $resolvedTaskFolder
$task.updatedAt = [DateTime]::UtcNow.ToString("o")
$task.encoderPreference = $Encoder

$pendingItems = @($task.items | Where-Object { $_.status -eq "pending" } | Select-Object -First $Count)
if (-not $pendingItems -or $pendingItems.Count -eq 0) {
    Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
    Write-Host "No pending items to process." -ForegroundColor Yellow
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
    throw "Encoder script not found: $encoderScriptPath"
}

$processed = 0
foreach ($item in $pendingItems) {
    if (-not (Test-Path -LiteralPath $item.path)) {
        $item.status = "skipped"
        $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
        $item.lastResult = "Source file no longer exists."
        $task.updatedAt = [DateTime]::UtcNow.ToString("o")
        Save-TaskFile -TaskFolder $resolvedTaskFolder -Task $task
        Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
        Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $item.path, $Encoder, $task.targetKbps, "skipped", $replaceOriginal, $keepBackup, "Source file missing")
        continue
    }

    $item.status = "processing"
    $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
    $item.lastResult = "Processing with $Encoder."
    $task.updatedAt = [DateTime]::UtcNow.ToString("o")
    Save-TaskFile -TaskFolder $resolvedTaskFolder -Task $task
    Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task

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
        if ($LASTEXITCODE -ne 0) {
            throw "Encoder script failed with exit code $LASTEXITCODE."
        }

        $item.status = "done"
        $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
        $item.lastResult = "Completed with $Encoder."
        $item.replacedOriginal = $replaceOriginal
        $task.updatedAt = [DateTime]::UtcNow.ToString("o")
        Save-TaskFile -TaskFolder $resolvedTaskFolder -Task $task
        Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
        Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $item.path, $Encoder, $task.targetKbps, "done", $replaceOriginal, $keepBackup, "Completed")
        $processed++
    } catch {
        $item.status = "failed"
        $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
        $item.lastResult = $_.Exception.Message
        $item.replacedOriginal = $false
        $task.updatedAt = [DateTime]::UtcNow.ToString("o")
        Save-TaskFile -TaskFolder $resolvedTaskFolder -Task $task
        Write-TaskSummary -TaskFolder $resolvedTaskFolder -Task $task
        Append-HistoryLine -TaskFolder $resolvedTaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), $item.path, $Encoder, $task.targetKbps, "failed", $replaceOriginal, $keepBackup, $_.Exception.Message)
        Write-Host "Failed: $($item.path)" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }
}

$remainingPending = @($task.items | Where-Object { $_.status -eq "pending" }).Count

Write-Host ""
Write-Host "Processed: $processed"
Write-Host "Remaining pending: $remainingPending"
Write-Host "Task folder: $resolvedTaskFolder"
