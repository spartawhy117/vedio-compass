param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$workspaceRoot = Join-Path $repoRoot "e2e\workspace"
$projectRoot = Join-Path $workspaceRoot "project"
$sourceRoot = Join-Path $projectRoot "source"
$tasksRoot = Join-Path $projectRoot "tasks"

$workspaceLower = $workspaceRoot.ToLowerInvariant()
@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and
    $_.Name -in @("ffmpeg.exe", "pwsh.exe", "powershell.exe") -and
    $_.CommandLine.ToLowerInvariant().Contains($workspaceLower)
}) | ForEach-Object {
    try {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    } catch {
    }
}

if (Test-Path -LiteralPath $workspaceRoot) {
    $removed = $false
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            Remove-Item -LiteralPath $workspaceRoot -Recurse -Force -ErrorAction Stop
            $removed = $true
            break
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $removed -and (Test-Path -LiteralPath $workspaceRoot)) {
        throw "无法重置测试工作区目录: $workspaceRoot"
    }
}

[void](New-Item -ItemType Directory -Path $sourceRoot -Force)
[void](New-Item -ItemType Directory -Path $tasksRoot -Force)

$sampleA = Join-Path $sourceRoot "sample-a.mp4"
$sampleB = Join-Path $sourceRoot "sample-b.mp4"

& ffmpeg.exe -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "sine=frequency=880:sample_rate=48000" -t 18 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 128k $sampleA
if ($LASTEXITCODE -ne 0) {
    throw "生成 sample-a 失败。"
}

& ffmpeg.exe -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 10 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 128k $sampleB
if ($LASTEXITCODE -ne 0) {
    throw "生成 sample-b 失败。"
}

[pscustomobject]@{
    RepoRoot = $repoRoot
    WorkspaceRoot = $workspaceRoot
    ProjectRoot = $projectRoot
    SourceRoot = $sourceRoot
    TasksRoot = $tasksRoot
    SampleAPath = $sampleA
    SampleBPath = $sampleB
}
