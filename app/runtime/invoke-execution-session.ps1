param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("scan", "compress", "repair-metadata", "env-check")]
    [string]$Operation,

    [string]$RootPath,
    [int]$ThresholdKbps,
    [int]$TargetKbps,
    [string]$TaskFolder,
    [int]$Count,
    [int]$ParallelCount,
    [string]$Encoder,
    [string]$AudioCodec,
    [string]$ReplaceOriginalMode,
    [string]$KeepBackupMode,
    [switch]$InstallFfmpeg
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "..\core\video-compass-common.ps1")

$projectRoot = Get-VideoCompassProjectRoot
$env:VIDEO_COMPASS_PROJECT_ROOT = $projectRoot

$watchdogProcess = $null
$watchdogContextDirectory = $null

try {
    switch ($Operation) {
        "scan" {
            $commandPath = Get-VideoCompassCommandPath -FileName "analyze-video-bitrate.ps1"
            & $commandPath -RootPath $RootPath -ThresholdKbps $ThresholdKbps -TargetKbps $TargetKbps
        }

        "compress" {
            $resolvedTaskFolder = (Resolve-Path -LiteralPath $TaskFolder).Path
            $watchdogContextDirectory = Join-Path -Path $resolvedTaskFolder -ChildPath (".watchdog-{0}" -f [System.Guid]::NewGuid().ToString("N"))
            [void](New-Item -ItemType Directory -Path $watchdogContextDirectory -Force)

            $env:VIDEO_COMPASS_WATCHDOG_CONTEXT_DIR = $watchdogContextDirectory
            $watchdogScript = Get-VideoCompassRuntimePath -FileName "invoke-watchdog.ps1"
            $watchdogPowerShell = Resolve-WorkerPowerShellPath
            $watchdogArgs = @(
                "-NoProfile"
                "-ExecutionPolicy"
                "Bypass"
                "-File"
                $watchdogScript
                "-ExecutionPid"
                [string]$PID
                "-ContextDirectory"
                $watchdogContextDirectory
            )
            $watchdogProcess = Start-Process -FilePath $watchdogPowerShell -ArgumentList $watchdogArgs -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru

            $commandPath = Get-VideoCompassCommandPath -FileName "compress-from-task.ps1"
            & $commandPath `
                -TaskFolder $resolvedTaskFolder `
                -Count $Count `
                -ParallelCount $ParallelCount `
                -Encoder $Encoder `
                -AudioCodec $AudioCodec `
                -ReplaceOriginalMode $ReplaceOriginalMode `
                -KeepBackupMode $KeepBackupMode
        }

        "repair-metadata" {
            $commandPath = Get-VideoCompassCommandPath -FileName "repair-zero-system-bitrate.ps1"
            if ($KeepBackupMode -eq "yes") {
                & $commandPath -RootPath $RootPath -KeepBackup
            } else {
                & $commandPath -RootPath $RootPath
            }
        }

        "env-check" {
            $commandPath = Get-VideoCompassCommandPath -FileName "check-video-compass-env.ps1"
            if ($InstallFfmpeg) {
                & $commandPath -InstallFfmpeg
            } else {
                & $commandPath
            }
        }
    }
} finally {
    Remove-Item Env:VIDEO_COMPASS_WATCHDOG_CONTEXT_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:VIDEO_COMPASS_PROJECT_ROOT -ErrorAction SilentlyContinue

    if ($watchdogProcess) {
        try {
            $watchdogProcess.WaitForExit(1000) | Out-Null
        } catch {
        }
    }

    if ($watchdogContextDirectory -and (Test-Path -LiteralPath $watchdogContextDirectory)) {
        try {
            Remove-Item -LiteralPath $watchdogContextDirectory -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
}
