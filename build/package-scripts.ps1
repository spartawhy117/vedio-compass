param(
    [string]$OutputZipPath,
    [switch]$IncludeDocs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$buildRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $buildRoot
if (-not $PSBoundParameters.ContainsKey("OutputZipPath")) {
    $OutputZipPath = Join-Path -Path $buildRoot -ChildPath "vedio-compass-scripts.zip"
}

$outputDirectory = Split-Path -Parent $OutputZipPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory)
}

$stagingRoot = Join-Path -Path $buildRoot -ChildPath ("package-temp-{0}" -f ([guid]::NewGuid().ToString("N")))
$stagingProjectRoot = Join-Path -Path $stagingRoot -ChildPath "vedio-compass"

try {
    [void](New-Item -ItemType Directory -Path $stagingProjectRoot -Force)

    $scriptFiles = Get-ChildItem -LiteralPath $projectRoot -File -Filter "*.ps1" |
        Sort-Object -Property Name

    if (-not $scriptFiles -or $scriptFiles.Count -eq 0) {
        throw "No PowerShell scripts were found in the project root."
    }

    foreach ($file in $scriptFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path -Path $stagingProjectRoot -ChildPath $file.Name)
    }

    if ($IncludeDocs) {
        $docFiles = @("README.md")
        foreach ($docFile in $docFiles) {
            $docPath = Join-Path -Path $projectRoot -ChildPath $docFile
            if (Test-Path -LiteralPath $docPath) {
                Copy-Item -LiteralPath $docPath -Destination (Join-Path -Path $stagingProjectRoot -ChildPath $docFile)
            }
        }
    }

    if (Test-Path -LiteralPath $OutputZipPath) {
        Remove-Item -LiteralPath $OutputZipPath -Force
    }

    Compress-Archive -Path $stagingProjectRoot -DestinationPath $OutputZipPath -CompressionLevel Optimal

    Write-Host "Package created: $OutputZipPath" -ForegroundColor Green
    Write-Host "Scripts included: $($scriptFiles.Count)"
    if ($IncludeDocs) {
        Write-Host "Docs included: README.md"
    }
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
