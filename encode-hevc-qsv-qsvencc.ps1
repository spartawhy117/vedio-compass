param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$OutputPath,

    [int]$VideoBitrateKbps = 3500,
    [int]$AudioBitrateKbps = 320,
    [int]$AudioSampleRate = 48000,
    [string]$Device = "auto",

    [ValidateSet("hw", "sw")]
    [string]$DecodeMode = "hw",

    [int]$Parallel = 0,

    [ValidateSet("background", "idle", "lowest", "belownormal", "normal", "abovenormal", "highest")]
    [string]$ProcessPriority = "belownormal"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ToolPath {
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

    $localPath = Join-Path -Path $PSScriptRoot -ChildPath $LocalFileName
    if (Test-Path -LiteralPath $localPath) {
        return $localPath
    }

    throw "找不到 $CommandName。请先加入 PATH，或把 $LocalFileName 放到脚本同目录。"
}

$qsvEncPath = Resolve-ToolPath -CommandName "QSVEncC64.exe" -LocalFileName "QSVEncC64.exe"

$resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path

if (-not $OutputPath) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInputPath)
    $OutputPath = Join-Path -Path (Split-Path -Path $resolvedInputPath -Parent) -ChildPath ("{0}_qsvencc.mp4" -f $baseName)
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)

$arguments = @(
    "--device", $Device
    "-i", $resolvedInputPath
    "-o", $resolvedOutputPath
    "--output-format", "mp4"
    "--codec", "hevc"
    "--vbr", $VideoBitrateKbps
    "--avsync", "forcecfr"
    "--profile", "main"
    "--level", "auto"
    "--quality", "faster"
    "--audio-codec", "aac"
    "--audio-bitrate", $AudioBitrateKbps
    "--audio-samplerate", $AudioSampleRate
    "--audio-resampler", "soxr"
    "--thread-priority", ("process={0}" -f $ProcessPriority)
)

if ($DecodeMode -eq "hw") {
    $arguments = @("--avhw") + $arguments
} else {
    $arguments = @("--avsw") + $arguments
}

if ($Parallel -gt 1) {
    $arguments += @("--parallel", $Parallel)
}

Write-Host "Running:" -ForegroundColor Cyan
Write-Host ('"{0}" {1}' -f $qsvEncPath, ($arguments -join " ")) -ForegroundColor DarkGray

& $qsvEncPath @arguments

if ($LASTEXITCODE -ne 0) {
    throw "QSVEncC 执行失败，退出码: $LASTEXITCODE"
}

Write-Host "输出文件: $resolvedOutputPath" -ForegroundColor Green
