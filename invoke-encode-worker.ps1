param(
    [Parameter(Mandatory = $true)]
    [string]$EncoderScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Mandatory = $true)]
    [int]$VideoBitrateKbps,

    [Parameter(Mandatory = $true)]
    [int]$AudioBitrateKbps,

    [Parameter(Mandatory = $true)]
    [int]$AudioSampleRate,

    [Parameter(Mandatory = $true)]
    [ValidateSet("aac", "libfdk_aac")]
    [string]$AudioCodec,

    [Parameter(Mandatory = $true)]
    [double]$DurationToleranceSec,

    [Parameter(Mandatory = $true)]
    [string]$ProgressFilePath,

    [Parameter(Mandatory = $true)]
    [string]$ResultFilePath,

    [Parameter(Mandatory = $true)]
    [string]$ProgressLabel,

    [int]$SupervisorPid = 0,

    [switch]$ReplaceOriginal,
    [switch]$KeepBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$env:VIDEO_COMPASS_PARALLEL_PROGRESS_FILE = $ProgressFilePath
$env:VIDEO_COMPASS_PARALLEL_PROGRESS_LABEL = $ProgressLabel

try {
    $scriptArgs = @{
        InputPath = $InputPath
        VideoBitrateKbps = $VideoBitrateKbps
        AudioBitrateKbps = $AudioBitrateKbps
        AudioSampleRate = $AudioSampleRate
        AudioCodec = $AudioCodec
        DurationToleranceSec = $DurationToleranceSec
    }

    if ($ReplaceOriginal) {
        $scriptArgs.ReplaceOriginal = $true
    }

    if ($KeepBackup) {
        $scriptArgs.KeepBackup = $true
    }

    $encodeResult = & $EncoderScriptPath @scriptArgs
    $finalResult = $encodeResult | Select-Object -Last 1

    $resultPayload = [pscustomobject]@{
        Success = $true
        Message = "completed"
        OutputPath = if ($finalResult) { $finalResult.OutputPath } else { $null }
        BackupPath = if ($finalResult) { $finalResult.BackupPath } else { $null }
        ReplacedOriginal = if ($finalResult) { [bool]$finalResult.ReplacedOriginal } else { $false }
    }

    $progressPayload = [pscustomobject]@{
        label = $ProgressLabel
        percent = 100.0
        status = "当前文件预计剩余 00:00"
        currentOperation = "已完成，等待主任务收尾"
        etaSec = 0.0
        updatedAt = [DateTime]::UtcNow.ToString("o")
    }
    [System.IO.File]::WriteAllText($ProgressFilePath, ($progressPayload | ConvertTo-Json -Depth 3), [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($ResultFilePath, ($resultPayload | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
    exit 0
} catch {
    $resultPayload = [pscustomobject]@{
        Success = $false
        Message = $_.Exception.Message
        OutputPath = $null
        BackupPath = $null
        ReplacedOriginal = $false
    }
    [System.IO.File]::WriteAllText($ResultFilePath, ($resultPayload | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
    exit 1
} finally {
    Remove-Item Env:VIDEO_COMPASS_PARALLEL_PROGRESS_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:VIDEO_COMPASS_PARALLEL_PROGRESS_LABEL -ErrorAction SilentlyContinue
}
