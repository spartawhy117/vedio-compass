Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resetScript = Join-Path $PSScriptRoot "..\fixtures\reset-test-workspace.ps1"
$workspace = & $resetScript
$env:VIDEO_COMPASS_PROJECT_ROOT = $workspace.ProjectRoot

try {
    . (Join-Path $workspace.RepoRoot "app\core\video-compass-common.ps1")
    $runtimeScript = Join-Path $workspace.RepoRoot "app\runtime\invoke-execution-session.ps1"
    $taskFolder = Get-TaskFolderPath -SourceRoot $workspace.SourceRoot -ThresholdKbps 100 -TargetKbps 80
    $outputPath = Join-Path $workspace.SourceRoot "sample-a_ffmpeg_cpu.mp4"

    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeScript -Operation scan -RootPath $workspace.SourceRoot -ThresholdKbps 100 -TargetKbps 80
    if (-not (Test-Path -LiteralPath (Join-Path $taskFolder "task.json"))) {
        throw "扫描未生成 task.json。"
    }

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

    $ffmpegAlive = $true
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        Start-Sleep -Seconds 1
        $ffmpegAlive = ($null -ne (Get-Process -Id $ffmpeg.ProcessId -ErrorAction SilentlyContinue))
        if (-not $ffmpegAlive) {
            break
        }
    }

    if ($ffmpegAlive) {
        Stop-Process -Id $ffmpeg.ProcessId -Force -ErrorAction SilentlyContinue
        throw "watchdog 未能在预期时间内回收 ffmpeg。"
    }

    if (Test-Path -LiteralPath $outputPath) {
        throw "watchdog 未删除中断后的输出文件。"
    }

    Write-Host "PASS test-watchdog-kill"
    exit 0
} catch {
    Write-Host ("FAIL test-watchdog-kill: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    Remove-Item Env:VIDEO_COMPASS_PROJECT_ROOT -ErrorAction SilentlyContinue
}
