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

    $compressArgs = @(
        "-NoProfile"
        "-ExecutionPolicy"
        "Bypass"
        "-File"
        $runtimeScript
        "-Operation"
        "compress"
        "-TaskFolder"
        $taskFolder
        "-Count"
        "1"
        "-ParallelCount"
        "1"
        "-Encoder"
        "cpu"
        "-AudioCodec"
        "aac"
        "-ReplaceOriginalMode"
        "no"
        "-KeepBackupMode"
        "no"
    )
    $executionProcess = Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList $compressArgs -WorkingDirectory $workspace.RepoRoot -WindowStyle Hidden -PassThru

    $sourceLower = $workspace.SampleAPath.ToLowerInvariant()
    $ffmpeg = $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Seconds 1
        $ffmpeg = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -eq "ffmpeg.exe" -and
            $_.CommandLine -and
            $_.CommandLine.ToLowerInvariant().Contains($sourceLower)
        }) | Select-Object -First 1
        if ($ffmpeg) {
            break
        }
    }

    if (-not $ffmpeg) {
        throw "未观测到 ffmpeg 启动。"
    }

    Stop-Process -Id $executionProcess.Id -Force

    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Id $ffmpeg.ProcessId -ErrorAction SilentlyContinue)) {
            break
        }
    }

    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeScript -Operation compress -TaskFolder $taskFolder -Count 1 -ParallelCount 1 -Encoder cpu -AudioCodec aac -ReplaceOriginalMode no -KeepBackupMode no

    $task = Read-TaskFile -TaskFolder $taskFolder
    $doneCount = @($task.items | Where-Object { $_.status -eq "done" }).Count
    $processingCount = @($task.items | Where-Object { $_.status -eq "processing" }).Count

    if ($doneCount -lt 1) {
        throw "恢复后没有任何任务项完成。"
    }

    if ($processingCount -ne 0) {
        throw "恢复后仍存在 processing 状态。"
    }

    Write-Host "PASS test-task-recovery"
    exit 0
} catch {
    Write-Host ("FAIL test-task-recovery: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    Remove-Item Env:VIDEO_COMPASS_PROJECT_ROOT -ErrorAction SilentlyContinue
}
