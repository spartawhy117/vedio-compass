param(
    [switch]$InstallFfmpeg
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "..\core\video-compass-common.ps1")

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

function Get-ResolvedTool {
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

    foreach ($localPath in @(Get-VideoCompassLocalToolCandidatePaths -LocalFileName $LocalFileName)) {
        if ($localPath -and (Test-Path -LiteralPath $localPath)) {
            return $localPath
        }
    }

    return $null
}

function Write-ToolStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [string]$Path
    )

    if ($Path) {
        Write-Host ("[正常] {0}: {1}" -f $Name, $Path) -ForegroundColor Green
    } else {
        Write-Host ("[缺失] {0}" -f $Name) -ForegroundColor Yellow
    }
}

function Install-FfmpegWithWinget {
    $wingetPath = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if (-not $wingetPath) {
        throw "当前无法使用 winget.exe。请手动安装 FFmpeg，或先从 Microsoft Store 安装 App Installer。"
    }

    $arguments = @(
        "install"
        "--id", "Gyan.FFmpeg.Essentials"
        "-e"
        "--accept-package-agreements"
        "--accept-source-agreements"
    )

    Write-Host "正在通过 winget 安装 FFmpeg..." -ForegroundColor Cyan
    & $wingetPath.Source @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "winget 安装失败，退出码 $LASTEXITCODE。"
    }
}

$ffmpegPath = Get-ResolvedTool -CommandName "ffmpeg.exe" -LocalFileName "ffmpeg.exe"
$ffprobePath = Get-ResolvedTool -CommandName "ffprobe.exe" -LocalFileName "ffprobe.exe"
$wingetCommand = Get-Command "winget.exe" -ErrorAction SilentlyContinue

Write-Host "Video Compass 环境检查" -ForegroundColor Cyan
Write-Host ""
Write-ToolStatus -Name "ffmpeg.exe" -Path $ffmpegPath
Write-ToolStatus -Name "ffprobe.exe" -Path $ffprobePath
if ($wingetCommand) {
    Write-Host ("[正常] winget.exe: {0}" -f $wingetCommand.Source) -ForegroundColor Green
} else {
    Write-Host "[缺失] winget.exe" -ForegroundColor Yellow
}

$missingFfmpegFamily = (-not $ffmpegPath) -or (-not $ffprobePath)

if ($missingFfmpegFamily -and $InstallFfmpeg) {
    Install-FfmpegWithWinget

    $ffmpegPath = Get-ResolvedTool -CommandName "ffmpeg.exe" -LocalFileName "ffmpeg.exe"
    $ffprobePath = Get-ResolvedTool -CommandName "ffprobe.exe" -LocalFileName "ffprobe.exe"

    Write-Host ""
    Write-Host "安装后重新检查:" -ForegroundColor Cyan
    Write-ToolStatus -Name "ffmpeg.exe" -Path $ffmpegPath
    Write-ToolStatus -Name "ffprobe.exe" -Path $ffprobePath
}

Write-Host ""

if ($ffmpegPath -and $ffprobePath) {
    Write-Host "环境已准备完成。" -ForegroundColor Green
    exit 0
}

Write-Host "环境尚未准备完成。" -ForegroundColor Yellow
Write-Host "建议处理方式:" -ForegroundColor Cyan
Write-Host "1. 执行: .\\check-video-compass-env.ps1 -InstallFfmpeg"
Write-Host "2. 或手动执行: winget install --id Gyan.FFmpeg.Essentials -e"
Write-Host "3. 如果 FFmpeg 已安装，请确认 ffmpeg.exe 和 ffprobe.exe 在 PATH 中，或放在脚本同目录。"
Write-Host "4. 安装完成后，重新打开 PowerShell 再执行一次本脚本。"
exit 1
