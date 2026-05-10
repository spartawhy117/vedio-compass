Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resetScript = Join-Path $PSScriptRoot "..\fixtures\reset-test-workspace.ps1"
$workspace = & $resetScript
$env:VIDEO_COMPASS_PROJECT_ROOT = $workspace.ProjectRoot

try {
    . (Join-Path $workspace.RepoRoot "app\core\video-compass-common.ps1")
    $runtimeScript = Join-Path $workspace.RepoRoot "app\runtime\invoke-execution-session.ps1"
    $taskFolder = Get-TaskFolderPath -SourceRoot $workspace.SourceRoot -ThresholdKbps 100 -TargetKbps 80

    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeScript -Operation scan -RootPath $workspace.SourceRoot -ThresholdKbps 100 -TargetKbps 80
    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeScript -Operation compress -TaskFolder $taskFolder -Count 1 -ParallelCount 1 -Encoder cpu -AudioCodec aac -ReplaceOriginalMode no -KeepBackupMode no
    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeScript -Operation compress -TaskFolder $taskFolder -Count 1 -ParallelCount 1 -Encoder cpu -AudioCodec aac -ReplaceOriginalMode no -KeepBackupMode no

    $task = Read-TaskFile -TaskFolder $taskFolder
    $doneCount = @($task.items | Where-Object { $_.status -eq "done" }).Count
    $processingCount = @($task.items | Where-Object { $_.status -eq "processing" }).Count
    $workspaceLower = $workspace.WorkspaceRoot.ToLowerInvariant()
    $orphanCount = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -eq "ffmpeg.exe" -and
            $_.CommandLine -and
            $_.CommandLine.ToLowerInvariant().Contains($workspaceLower)
        }
    ).Count

    if ($doneCount -lt 2) {
        throw "连续两次压缩后完成数量不足 2。"
    }

    if ($processingCount -ne 0) {
        throw "连续执行后仍存在 processing 状态。"
    }

    if ($orphanCount -ne 0) {
        throw "连续执行后仍存在遗留 ffmpeg 进程。"
    }

    Write-Host "PASS test-repeated-execution"
    exit 0
} catch {
    Write-Host ("FAIL test-repeated-execution: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    Remove-Item Env:VIDEO_COMPASS_PROJECT_ROOT -ErrorAction SilentlyContinue
}
