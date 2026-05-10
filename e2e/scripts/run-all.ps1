Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scripts = @(
    "test-watchdog-kill.ps1",
    "test-task-recovery.ps1",
    "test-repeated-execution.ps1"
)

foreach ($scriptName in $scripts) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    Write-Host ("Running {0}..." -f $scriptName) -ForegroundColor Cyan
    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Write-Host "PASS run-all" -ForegroundColor Green
exit 0
