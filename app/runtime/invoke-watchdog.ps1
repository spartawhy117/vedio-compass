param(
    [Parameter(Mandatory = $true)]
    [int]$ExecutionPid,

    [Parameter(Mandatory = $true)]
    [string]$ContextDirectory,

    [int]$PollMilliseconds = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-ProcessAlive {
    param(
        [int]$ProcessId
    )

    if ($ProcessId -le 0) {
        return $false
    }

    return ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

function Read-WatchdogRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        return ((Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-WatchdogResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResultObject
    )

    try {
        $resultPath = Join-Path -Path $ContextDirectory -ChildPath "watchdog-result.json"
        [System.IO.File]::WriteAllText($resultPath, ($ResultObject | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
    } catch {
    }
}

if (-not (Test-Path -LiteralPath $ContextDirectory)) {
    exit 0
}

while (Test-ProcessAlive -ProcessId $ExecutionPid) {
    Start-Sleep -Milliseconds $PollMilliseconds
}

$records = @(
    Get-ChildItem -LiteralPath $ContextDirectory -File -Filter "encode-*.json" -ErrorAction SilentlyContinue
)

$killedCount = 0
$deletedOutputCount = 0

foreach ($recordFile in $records) {
    $record = Read-WatchdogRecord -Path $recordFile.FullName
    if (-not $record) {
        continue
    }

    $ffmpegPid = 0
    if ($record.PSObject.Properties.Match("ffmpegPid").Count -gt 0) {
        $ffmpegPid = [int]$record.ffmpegPid
    }

    if ($ffmpegPid -gt 0 -and (Test-ProcessAlive -ProcessId $ffmpegPid)) {
        try {
            Stop-Process -Id $ffmpegPid -Force -ErrorAction SilentlyContinue
            $killedCount++
        } catch {
        }
    }

    if ($record.PSObject.Properties.Match("outputPath").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$record.outputPath)) {
        $outputPath = [string]$record.outputPath
        if (Test-Path -LiteralPath $outputPath) {
            try {
                Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
                $deletedOutputCount++
            } catch {
            }
        }
    }
}

Write-WatchdogResult -ResultObject ([pscustomobject]@{
    executionPid = $ExecutionPid
    killedCount = $killedCount
    deletedOutputCount = $deletedOutputCount
    triggeredAt = [DateTime]::UtcNow.ToString("o")
})

exit 0
