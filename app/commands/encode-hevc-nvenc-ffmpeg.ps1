param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$OutputPath,

    [int]$VideoBitrateKbps = 3500,
    [int]$AudioBitrateKbps = 320,
    [int]$AudioSampleRate = 48000,
    [ValidateSet("aac", "libfdk_aac")]
    [string]$AudioCodec = "aac",
    [switch]$ReplaceOriginal,
    [switch]$KeepBackup,
    [double]$DurationToleranceSec = 2.0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "..\core\video-compass-common.ps1")

$ffmpegPath = Resolve-ToolPath -CommandName "ffmpeg.exe" -LocalFileName "ffmpeg.exe"
$ffprobePath = Resolve-ToolPath -CommandName "ffprobe.exe" -LocalFileName "ffprobe.exe"

$videoArguments = @(
    "-c:v", "hevc_nvenc"
    "-b:v", ("{0}k" -f $VideoBitrateKbps)
    "-rc:v", "vbr"
    "-preset:v", "p4"
    "-profile:v", "main"
)

$result = Invoke-EncodeWorkflow `
    -FfmpegPath $ffmpegPath `
    -ProbePath $ffprobePath `
    -InputPath $InputPath `
    -OutputPath $OutputPath `
    -VideoArguments $videoArguments `
    -DefaultSuffix "ffmpeg_nvenc" `
    -AudioBitrateKbps $AudioBitrateKbps `
    -AudioSampleRate $AudioSampleRate `
    -AudioCodec $AudioCodec `
    -ReplaceOriginal:$ReplaceOriginal `
    -KeepBackup:$KeepBackup `
    -DurationToleranceSec $DurationToleranceSec

Write-Host "输出文件: $($result.OutputPath)" -ForegroundColor Green
if ($result.BackupPath) {
    Write-Host "备份文件: $($result.BackupPath)" -ForegroundColor Yellow
}

$result
