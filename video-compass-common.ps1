Set-StrictMode -Version Latest

function Initialize-ConsoleEncoding {
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
}

Initialize-ConsoleEncoding

function Initialize-VideoCompassGlobals {
    if (-not (Get-Variable -Name "VideoCompassActiveEncodeContext" -Scope Global -ErrorAction SilentlyContinue)) {
        $global:VideoCompassActiveEncodeContext = $null
    }

    if (-not (Get-Variable -Name "VideoCompassActiveTaskContext" -Scope Global -ErrorAction SilentlyContinue)) {
        $global:VideoCompassActiveTaskContext = $null
    }

    if (-not (Get-Variable -Name "VideoCompassExitHandlingInitialized" -Scope Global -ErrorAction SilentlyContinue)) {
        $global:VideoCompassExitHandlingInitialized = $false
    }

    if (-not (Get-Variable -Name "VideoCompassConsoleCancelHandler" -Scope Global -ErrorAction SilentlyContinue)) {
        $global:VideoCompassConsoleCancelHandler = $null
    }

    if (-not (Get-Variable -Name "VideoCompassConsoleCtrlDelegate" -Scope Global -ErrorAction SilentlyContinue)) {
        $global:VideoCompassConsoleCtrlDelegate = $null
    }

    if (-not (Get-Variable -Name "VideoCompassShutdownRequested" -Scope Global -ErrorAction SilentlyContinue)) {
        $global:VideoCompassShutdownRequested = $false
    }

    if (-not (Get-Variable -Name "VideoCompassShutdownReason" -Scope Global -ErrorAction SilentlyContinue)) {
        $global:VideoCompassShutdownReason = ""
    }
}

Initialize-VideoCompassGlobals

function Set-VideoCompassActiveEncodeContext {
    param(
        [int]$ProcessId,
        [string]$OutputPath
    )

    $global:VideoCompassActiveEncodeContext = @{
        ProcessId = $ProcessId
        OutputPath = $OutputPath
        CleanupDone = $false
    }
}

function Update-VideoCompassActiveEncodeProcessId {
    param(
        [int]$ProcessId
    )

    if (-not $global:VideoCompassActiveEncodeContext) {
        return
    }

    $global:VideoCompassActiveEncodeContext.ProcessId = $ProcessId
}

function Clear-VideoCompassActiveEncodeContext {
    $global:VideoCompassActiveEncodeContext = $null
}

function Set-VideoCompassActiveTaskContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder,

        [Parameter(Mandatory = $true)]
        [object]$Task,

        [Parameter(Mandatory = $true)]
        [object]$Item,

        [Parameter(Mandatory = $true)]
        [string]$Encoder,

        [bool]$ReplaceOriginal = $false,
        [bool]$KeepBackup = $false
    )

    $global:VideoCompassActiveTaskContext = @{
        TaskFolder = $TaskFolder
        Task = $Task
        Item = $Item
        Encoder = $Encoder
        ReplaceOriginal = $ReplaceOriginal
        KeepBackup = $KeepBackup
        CleanupDone = $false
    }
}

function Clear-VideoCompassActiveTaskContext {
    $global:VideoCompassActiveTaskContext = $null
}

function Save-VideoCompassInterruptedTaskState {
    param(
        [string]$Reason = "脚本在处理中被中断，已重置为待处理。"
    )

    $context = $global:VideoCompassActiveTaskContext
    if (-not $context) {
        return
    }

    if ($context.CleanupDone) {
        return
    }

    $context.CleanupDone = $true

    try {
        $task = $context.Task
        $item = $context.Item
        if (-not $task -or -not $item) {
            return
        }

        if ($item.status -eq "processing") {
            $timestamp = [DateTime]::UtcNow.ToString("o")
            $item.status = "pending"
            $item.lastAttemptAt = $timestamp
            $item.lastResult = $Reason
            $item.replacedOriginal = $false
            $task.updatedAt = $timestamp

            Save-TaskFile -TaskFolder $context.TaskFolder -Task $task
            Write-TaskSummary -TaskFolder $context.TaskFolder -Task $task
            Append-HistoryLine -TaskFolder $context.TaskFolder -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f $timestamp, $item.path, $context.Encoder, $task.targetKbps, "interrupted", $context.ReplaceOriginal, $context.KeepBackup, $Reason)
        }
    } catch {
    } finally {
        Clear-VideoCompassActiveTaskContext
    }
}

function Request-VideoCompassShutdown {
    param(
        [string]$Reason = "脚本退出"
    )

    $global:VideoCompassShutdownRequested = $true
    $global:VideoCompassShutdownReason = $Reason

    Save-VideoCompassInterruptedTaskState -Reason ("{0} 已中断当前项目，已重置为待处理。" -f $Reason)
    Stop-VideoCompassActiveEncode -Reason $Reason
}

function Stop-VideoCompassActiveEncode {
    param(
        [string]$Reason = "脚本退出"
    )

    $context = $global:VideoCompassActiveEncodeContext
    if (-not $context) {
        return
    }

    if ($context.CleanupDone) {
        return
    }

    $context.CleanupDone = $true

    $processId = 0
    if ($context.ContainsKey("ProcessId") -and $context.ProcessId) {
        $processId = [int]$context.ProcessId
    }

    if ($processId -gt 0) {
        try {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($process -and (-not $process.HasExited)) {
                Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 200
            }
        } catch {
        }
    }

    $outputPath = ""
    if ($context.ContainsKey("OutputPath") -and $context.OutputPath) {
        $outputPath = [string]$context.OutputPath
    }

    if ($outputPath -and (Test-Path -LiteralPath $outputPath)) {
        try {
            Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }

    Clear-VideoCompassActiveEncodeContext
}

function Initialize-VideoCompassExitHandling {
    if ($global:VideoCompassExitHandlingInitialized) {
        return
    }

    try {
        Register-EngineEvent -SourceIdentifier "PowerShell.Exiting" -Action {
            try {
                Request-VideoCompassShutdown -Reason "PowerShell 正在退出"
            } catch {
            }
        } | Out-Null
    } catch {
    }

    try {
        $global:VideoCompassConsoleCancelHandler = [System.ConsoleCancelEventHandler]{
            param($sender, $eventArgs)
            try {
                Request-VideoCompassShutdown -Reason "用户中断了脚本"
            } catch {
            }
        }
        [Console]::add_CancelKeyPress($global:VideoCompassConsoleCancelHandler)
    } catch {
    }

    try {
        if (-not ("VideoCompass.NativeMethods" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace VideoCompass {
    public static class NativeMethods {
        public delegate bool ConsoleCtrlDelegate(int ctrlType);

        [DllImport("Kernel32.dll")]
        public static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate handler, bool add);
    }
}
"@
        }

        $global:VideoCompassConsoleCtrlDelegate = [VideoCompass.NativeMethods+ConsoleCtrlDelegate]{
            param([int]$ctrlType)
            try {
                Request-VideoCompassShutdown -Reason ("收到控制台关闭信号: {0}" -f $ctrlType)
            } catch {
            }

            return $false
        }

        [void][VideoCompass.NativeMethods]::SetConsoleCtrlHandler($global:VideoCompassConsoleCtrlDelegate, $true)
    } catch {
    }

    $global:VideoCompassExitHandlingInitialized = $true
}

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

    throw "找不到 $CommandName。请先运行 .\check-video-compass-env.ps1，或安装 FFmpeg，并把 $LocalFileName 放到 PATH 或脚本同目录。"
}

function Test-ToolResolvable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$LocalFileName
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) {
        return $true
    }

    $localPath = Join-Path -Path $PSScriptRoot -ChildPath $LocalFileName
    return (Test-Path -LiteralPath $localPath)
}

function Assert-RequiredVideoTools {
    param(
        [switch]$RequireFfmpeg,
        [switch]$RequireFfprobe
    )

    $missingTools = New-Object System.Collections.Generic.List[string]

    if ($RequireFfmpeg -and (-not (Test-ToolResolvable -CommandName "ffmpeg.exe" -LocalFileName "ffmpeg.exe"))) {
        $missingTools.Add("ffmpeg.exe")
    }

    if ($RequireFfprobe -and (-not (Test-ToolResolvable -CommandName "ffprobe.exe" -LocalFileName "ffprobe.exe"))) {
        $missingTools.Add("ffprobe.exe")
    }

    if ($missingTools.Count -gt 0) {
        $toolList = $missingTools -join ", "
        throw "缺少必需工具: $toolList。请先运行 .\check-video-compass-env.ps1，或执行 winget install --id Gyan.FFmpeg.Essentials -e 安装 FFmpeg。"
    }
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Path $Path)
    }
}

function Format-Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Bytes
    )

    $units = @("B", "KB", "MB", "GB", "TB")
    $size = [double]$Bytes
    $unitIndex = 0

    while ($size -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $size /= 1024
        $unitIndex++
    }

    return ("{0:N2} {1}" -f $size, $units[$unitIndex])
}

function Get-SumOrZero {
    param(
        [AllowEmptyCollection()]
        [object[]]$Items = @(),

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    $measure = $Items | Measure-Object -Property $PropertyName -Sum
    if ($measure -and $measure.PSObject.Properties.Match("Sum").Count -gt 0 -and $null -ne $measure.Sum) {
        return [double]$measure.Sum
    }

    return 0.0
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $escapedArguments = $Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '(\\*)"', '$1$1\"') + '"'
        } else {
            $_
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($escapedArguments -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Get-VideoProbeData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProbePath,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $probeArgs = @(
        "-v", "error"
        "-show_entries", "stream=index,codec_type,codec_name,bit_rate:format=duration,size,bit_rate"
        "-of", "json"
        $FilePath
    )

    $probeResult = Invoke-ProcessCapture -FilePath $ProbePath -Arguments $probeArgs
    if ($probeResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($probeResult.StdOut)) {
        return $null
    }

    return ($probeResult.StdOut | ConvertFrom-Json)
}

function Get-VideoInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProbePath,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $probe = Get-VideoProbeData -ProbePath $ProbePath -FilePath $FilePath
    if (-not $probe) {
        return $null
    }

    $streams = @($probe.streams)
    $format = $probe.format
    $videoStream = $streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    if (-not $videoStream) {
        return $null
    }

    $audioStream = $streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    $durationSec = 0.0
    if ($format.PSObject.Properties.Match("duration").Count -gt 0 -and $format.duration) {
        $durationSec = [double]$format.duration
    }

    $fileSizeBytes = 0.0
    if ($format.PSObject.Properties.Match("size").Count -gt 0 -and $format.size) {
        $fileSizeBytes = [double]$format.size
    }

    $audioMeasure = $streams |
        Where-Object {
            $_.codec_type -eq "audio" -and
            $_.PSObject.Properties.Match("bit_rate").Count -gt 0 -and
            $_.bit_rate
        } |
        Measure-Object -Property bit_rate -Sum

    $audioBitrateBps = 0.0
    if ($audioMeasure -and $audioMeasure.PSObject.Properties.Match("Sum").Count -gt 0 -and $audioMeasure.Sum) {
        $audioBitrateBps = [double]$audioMeasure.Sum
    }

    $totalBitrateBps = 0.0
    if ($format.PSObject.Properties.Match("bit_rate").Count -gt 0 -and $format.bit_rate) {
        $totalBitrateBps = [double]$format.bit_rate
    } elseif ($durationSec -gt 0 -and $fileSizeBytes -gt 0) {
        $totalBitrateBps = ($fileSizeBytes * 8.0) / $durationSec
    }

    $videoBitrateBps = 0.0
    $bitrateSource = "stream"

    if ($videoStream.PSObject.Properties.Match("bit_rate").Count -gt 0 -and $videoStream.bit_rate) {
        $videoBitrateBps = [double]$videoStream.bit_rate
    } elseif ($totalBitrateBps -gt 0) {
        $videoBitrateBps = [Math]::Max($totalBitrateBps - $audioBitrateBps, 0.0)
        $bitrateSource = "estimated_from_total"
    }

    if ($videoBitrateBps -le 0 -or $durationSec -le 0 -or $fileSizeBytes -le 0) {
        return $null
    }

    [pscustomobject]@{
        DurationSec     = $durationSec
        FileSizeBytes   = $fileSizeBytes
        TotalBitrateBps = $totalBitrateBps
        VideoBitrateBps = $videoBitrateBps
        AudioBitrateBps = [double]$audioBitrateBps
        BitrateSource   = $bitrateSource
        VideoCodec      = if ($videoStream) { [string]$videoStream.codec_name } else { "" }
        AudioCodec      = if ($audioStream) { [string]$audioStream.codec_name } else { "" }
    }
}

function Get-TaskRootPath {
    return (Join-Path -Path $PSScriptRoot -ChildPath "tasks")
}

function Get-SafeLeafName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $trimmed = $Path.TrimEnd('\', '/')
    $leafName = Split-Path -Path $trimmed -Leaf
    if ([string]::IsNullOrWhiteSpace($leafName)) {
        $leafName = "task"
    }

    return ($leafName -replace '[<>:"/\\|?*]', '_')
}

function Get-TaskFolderName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [int]$ThresholdKbps,

        [Parameter(Mandatory = $true)]
        [int]$TargetKbps
    )

    $leafName = Get-SafeLeafName -Path $SourceRoot
    return ("{0}__scan-{1}__target-{2}" -f $leafName, $ThresholdKbps, $TargetKbps)
}

function Get-TaskFolderPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [int]$ThresholdKbps,

        [Parameter(Mandatory = $true)]
        [int]$TargetKbps
    )

    $taskRoot = Get-TaskRootPath
    Ensure-Directory -Path $taskRoot
    return (Join-Path -Path $taskRoot -ChildPath (Get-TaskFolderName -SourceRoot $SourceRoot -ThresholdKbps $ThresholdKbps -TargetKbps $TargetKbps))
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Data
    )

    $json = $Data | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function Read-TaskFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder
    )

    $taskPath = Join-Path -Path $TaskFolder -ChildPath "task.json"
    if (-not (Test-Path -LiteralPath $taskPath)) {
        throw "找不到任务文件: $taskPath"
    }

    return ((Get-Content -LiteralPath $taskPath -Raw) | ConvertFrom-Json)
}

function Save-TaskFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder,

        [Parameter(Mandatory = $true)]
        [object]$Task
    )

    Ensure-Directory -Path $TaskFolder
    $taskPath = Join-Path -Path $TaskFolder -ChildPath "task.json"
    Save-JsonFile -Path $taskPath -Data $Task
}

function Write-TaskSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder,

        [Parameter(Mandatory = $true)]
        [object]$Task
    )

    $items = @($Task.items)
    $pending = @($items | Where-Object { $_.status -eq "pending" })
    $done = @($items | Where-Object { $_.status -eq "done" })
    $failed = @($items | Where-Object { $_.status -eq "failed" })
    $skipped = @($items | Where-Object { $_.status -eq "skipped" })
    $processing = @($items | Where-Object { $_.status -eq "processing" })

    $remainingSizeBytes = Get-SumOrZero -Items $pending -PropertyName "sizeBytes"
    $remainingSavedBytes = Get-SumOrZero -Items $pending -PropertyName "estimatedSavedBytes"

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("任务名称: $($Task.taskName)")
    $lines.Add("源目录: $($Task.sourceRoot)")
    $lines.Add("扫描阈值码率: $($Task.thresholdKbps) kbps")
    $lines.Add("目标压缩码率: $($Task.targetKbps) kbps")
    $lines.Add("候选文件数: $($items.Count)")
    $lines.Add("待处理: $($pending.Count)")
    $lines.Add("处理中: $($processing.Count)")
    $lines.Add("已完成: $($done.Count)")
    $lines.Add("失败: $($failed.Count)")
    $lines.Add("已跳过: $($skipped.Count)")
    $lines.Add("待处理文件总体积: $(Format-Bytes -Bytes $remainingSizeBytes)")
    $lines.Add("预计剩余可节省空间: $(Format-Bytes -Bytes $remainingSavedBytes)")
    $lines.Add("最后更新时间: $($Task.updatedAt)")

    if ($failed.Count -gt 0) {
        $lines.Add("")
        $lines.Add("失败文件:")
        $failed | Select-Object -First 10 | ForEach-Object {
            $reason = ""
            if ($_.PSObject.Properties.Match("lastResult").Count -gt 0 -and $_.lastResult) {
                $reason = " :: $($_.lastResult)"
            }

            $lines.Add(("- {0}{1}" -f $_.path, $reason))
        }
    }

    $summaryPath = Join-Path -Path $TaskFolder -ChildPath "summary.txt"
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($summaryPath, $lines, $utf8WithBom)
}

function Append-HistoryLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder,

        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $historyPath = Join-Path -Path $TaskFolder -ChildPath "history.log"
    Add-Content -LiteralPath $historyPath -Value $Line -Encoding UTF8
}

function Read-InputOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [string]$DefaultValue
    )

    $response = Read-Host "$Prompt（直接回车使用默认值: $DefaultValue）"
    if ([string]::IsNullOrWhiteSpace($response)) {
        return $DefaultValue
    }

    return $response.Trim()
}

function Read-RequiredInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    while ($true) {
        $response = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($response)) {
            return $response.Trim()
        }

        Write-Host "此项不能为空，请重新输入。" -ForegroundColor Yellow
    }
}

function Read-IntOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [int]$DefaultValue
    )

    while ($true) {
        $value = Read-InputOrDefault -Prompt $Prompt -DefaultValue ([string]$DefaultValue)
        $parsed = 0
        if ([int]::TryParse($value, [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }

        Write-Host "请输入大于 0 的整数。" -ForegroundColor Yellow
    }
}

function Read-ChoiceOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [string[]]$Choices,

        [Parameter(Mandatory = $true)]
        [string]$DefaultValue
    )

    $normalizedChoices = $Choices | ForEach-Object { $_.ToLowerInvariant() }
    while ($true) {
        $value = Read-InputOrDefault -Prompt "$Prompt [$($Choices -join '/')] " -DefaultValue $DefaultValue
        $normalized = $value.ToLowerInvariant()
        if ($normalizedChoices -contains $normalized) {
            return $normalized
        }

        Write-Host "请输入以下选项之一: $($Choices -join ', ')。" -ForegroundColor Yellow
    }
}

function Read-YesNoOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [bool]$DefaultValue
    )

    $defaultText = if ($DefaultValue) { "Y" } else { "N" }
    while ($true) {
        $value = Read-InputOrDefault -Prompt "$Prompt [Y/N]" -DefaultValue $defaultText
        switch ($value.ToLowerInvariant()) {
            "y" { return $true }
            "yes" { return $true }
            "n" { return $false }
            "no" { return $false }
        }

        Write-Host "请输入 Y 或 N。" -ForegroundColor Yellow
    }
}

function Get-OutputExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $extension = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()
    if ($extension -in @(".mp4", ".m4v", ".mov", ".mkv")) {
        return $extension
    }

    return ".mp4"
}

function Test-ReplaceOriginalSupported {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $extension = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()
    return ($extension -in @(".mp4", ".m4v", ".mov", ".mkv"))
}

function Get-DefaultOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    $directory = Split-Path -Path $InputPath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $extension = Get-OutputExtension -InputPath $InputPath
    return (Join-Path -Path $directory -ChildPath ("{0}_{1}{2}" -f $baseName, $Suffix, $extension))
}

function New-TemporaryOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $directory = Split-Path -Path $InputPath -Parent
    $extension = Get-OutputExtension -InputPath $InputPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $token = [System.Guid]::NewGuid().ToString("N")
    return (Join-Path -Path $directory -ChildPath ("{0}.codex-temp-{1}{2}" -f $baseName, $token, $extension))
}

function Get-TemporaryOutputFilesForInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $directory = Split-Path -Path $InputPath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)

    if (-not (Test-Path -LiteralPath $directory)) {
        return @()
    }

    $prefix = "{0}.codex-temp-" -f $baseName
    return @(
        Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            }
    )
}

function New-BackupPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return ("{0}.codex-backup-{1}" -f $InputPath, $stamp)
}

function Test-OutputForReplacement {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProbePath,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [double]$DurationToleranceSec = 2.0
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "编码输出文件未生成。"
    }

    $outputInfo = Get-VideoInfo -ProbePath $ProbePath -FilePath $OutputPath
    if (-not $outputInfo) {
        throw "编码输出文件未通过 ffprobe 校验。"
    }

    if ($outputInfo.FileSizeBytes -le 0) {
        throw "编码输出文件大小为 0。"
    }

    $sourceInfo = Get-VideoInfo -ProbePath $ProbePath -FilePath $SourcePath
    if (-not $sourceInfo) {
        throw "替换原文件前，源文件校验失败。"
    }

    if ([Math]::Abs($sourceInfo.DurationSec - $outputInfo.DurationSec) -gt $DurationToleranceSec) {
        throw "输出文件与源文件时长差超出允许范围。"
    }

    return $outputInfo
}

function Replace-OriginalFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [switch]$KeepBackup
    )

    $backupPath = New-BackupPath -InputPath $SourcePath
    Move-Item -LiteralPath $SourcePath -Destination $backupPath

    try {
        Move-Item -LiteralPath $OutputPath -Destination $SourcePath
        if (-not $KeepBackup) {
            Remove-Item -LiteralPath $backupPath -Force
            return $null
        }

        return $backupPath
    } catch {
        if (Test-Path -LiteralPath $OutputPath) {
            Remove-Item -LiteralPath $OutputPath -Force
        }

        if (-not (Test-Path -LiteralPath $SourcePath) -and (Test-Path -LiteralPath $backupPath)) {
            Move-Item -LiteralPath $backupPath -Destination $SourcePath
        }

        throw
    }
}

function Format-DurationClock {
    param(
        [double]$TotalSeconds
    )

    if ($TotalSeconds -lt 0 -or [double]::IsNaN($TotalSeconds) -or [double]::IsInfinity($TotalSeconds)) {
        $TotalSeconds = 0
    }

    $rounded = [int][Math]::Round($TotalSeconds, 0, [MidpointRounding]::AwayFromZero)
    $span = [TimeSpan]::FromSeconds($rounded)

    if ($span.TotalHours -ge 1) {
        return $span.ToString("hh\:mm\:ss")
    }

    return $span.ToString("mm\:ss")
}

function ConvertTo-DoubleOrZero {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 0.0
    }

    $parsed = 0.0
    if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }

    return 0.0
}

function Get-FfmpegProgressSeconds {
    param(
        [hashtable]$ProgressState
    )

    if ($ProgressState.ContainsKey("out_time")) {
        $timeSpan = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse([string]$ProgressState["out_time"], [ref]$timeSpan)) {
            return [double]$timeSpan.TotalSeconds
        }
    }

    if ($ProgressState.ContainsKey("out_time_us")) {
        return (ConvertTo-DoubleOrZero -Value ([string]$ProgressState["out_time_us"])) / 1000000.0
    }

    if ($ProgressState.ContainsKey("out_time_ms")) {
        return (ConvertTo-DoubleOrZero -Value ([string]$ProgressState["out_time_ms"])) / 1000000.0
    }

    return 0.0
}

function Update-EncodeProgressDisplay {
    param(
        [Parameter(Mandatory = $true)]
        [double]$CurrentDurationSec,

        [Parameter(Mandatory = $true)]
        [double]$CurrentOutTimeSec,

        [Parameter(Mandatory = $true)]
        [DateTime]$CurrentStartedAtUtc
    )

    $safeCurrentDuration = [Math]::Max($CurrentDurationSec, 0.001)
    $safeCurrentOutTime = [Math]::Min([Math]::Max($CurrentOutTimeSec, 0.0), $safeCurrentDuration)
    $currentPercent = [Math]::Min(($safeCurrentOutTime / $safeCurrentDuration) * 100.0, 100.0)

    $currentElapsedSec = [Math]::Max(([DateTime]::UtcNow - $CurrentStartedAtUtc).TotalSeconds, 0.001)
    $currentEtaSec = 0.0
    if ($safeCurrentOutTime -gt 0.1) {
        $currentRate = $safeCurrentOutTime / $currentElapsedSec
        if ($currentRate -gt 0) {
            $currentEtaSec = [Math]::Max(($safeCurrentDuration - $safeCurrentOutTime) / $currentRate, 0.0)
        }
    }

    $currentStatus = ("{0:N1}% | 当前文件预计剩余 {1}" -f $currentPercent, (Format-DurationClock -TotalSeconds $currentEtaSec))
    Write-Progress -Id 1 -Activity "正在压缩当前文件" -Status $currentStatus -PercentComplete $currentPercent

    $batchTotalCount = [int](ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_TOTAL_COUNT)
    if ($batchTotalCount -le 0) {
        return
    }

    $batchCurrentIndex = [int](ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_CURRENT_INDEX)
    $batchTotalMediaSec = ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_TOTAL_MEDIA_SEC
    $batchCompletedMediaSec = ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_COMPLETED_MEDIA_SEC

    if ($batchTotalMediaSec -le 0) {
        $batchPercent = [Math]::Min((([Math]::Max($batchCurrentIndex - 1, 0) + ($currentPercent / 100.0)) / $batchTotalCount) * 100.0, 100.0)
        $batchStatus = ("第 {0}/{1} 个 | 本轮预计剩余计算中..." -f $batchCurrentIndex, $batchTotalCount)
        Write-Progress -Id 2 -Activity "批量压缩任务" -Status $batchStatus -PercentComplete $batchPercent
        return
    }

    $processedMediaSec = [Math]::Min($batchCompletedMediaSec + $safeCurrentOutTime, $batchTotalMediaSec)
    $batchPercent = [Math]::Min(($processedMediaSec / $batchTotalMediaSec) * 100.0, 100.0)

    $batchStartedAtUtc = $null
    if ($env:VIDEO_COMPASS_BATCH_STARTED_AT_UTC) {
        $parsedBatchStartedAt = [DateTime]::MinValue
        if ([DateTime]::TryParse($env:VIDEO_COMPASS_BATCH_STARTED_AT_UTC, [ref]$parsedBatchStartedAt)) {
            $batchStartedAtUtc = $parsedBatchStartedAt.ToUniversalTime()
        }
    }

    $batchEtaSec = 0.0
    if ($batchStartedAtUtc) {
        $batchElapsedSec = [Math]::Max(([DateTime]::UtcNow - $batchStartedAtUtc).TotalSeconds, 0.001)
        if ($processedMediaSec -gt 0.1) {
            $batchRate = $processedMediaSec / $batchElapsedSec
            if ($batchRate -gt 0) {
                $batchEtaSec = [Math]::Max(($batchTotalMediaSec - $processedMediaSec) / $batchRate, 0.0)
            }
        }
    }

    $batchStatus = ("第 {0}/{1} 个 | 本轮预计剩余 {2}" -f $batchCurrentIndex, $batchTotalCount, (Format-DurationClock -TotalSeconds $batchEtaSec))
    Write-Progress -Id 2 -Activity "批量压缩任务" -Status $batchStatus -PercentComplete $batchPercent
}

function Invoke-FfmpegWithProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FfmpegPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [double]$SourceDurationSec
    )

    $escapedArguments = $Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '(\\*)"', '$1$1\"') + '"'
        } else {
            $_
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegPath
    $psi.Arguments = ($escapedArguments -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $currentStartedAtUtc = [DateTime]::UtcNow
    $progressState = @{}
    $processStarted = $false

    try {
        Initialize-VideoCompassExitHandling

        [void]$process.Start()
        $processStarted = $true
        Update-VideoCompassActiveEncodeProcessId -ProcessId $process.Id

        while (-not $process.StandardOutput.EndOfStream) {
            $line = $process.StandardOutput.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            if ($line -match "=") {
                $pair = $line -split "=", 2
                $progressState[$pair[0]] = $pair[1]

                if ($pair[0] -eq "progress") {
                    $currentOutTimeSec = Get-FfmpegProgressSeconds -ProgressState $progressState
                    Update-EncodeProgressDisplay -CurrentDurationSec $SourceDurationSec -CurrentOutTimeSec $currentOutTimeSec -CurrentStartedAtUtc $currentStartedAtUtc
                }
            }
        }

        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Write-Progress -Id 1 -Activity "正在压缩当前文件" -Completed

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdErr = $stderr
        }
    } finally {
        Write-Progress -Id 1 -Activity "正在压缩当前文件" -Completed
    }
}

function Invoke-EncodeWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FfmpegPath,

        [Parameter(Mandatory = $true)]
        [string]$ProbePath,

        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string[]]$VideoArguments,

        [Parameter(Mandatory = $true)]
        [string]$DefaultSuffix,

        [int]$AudioBitrateKbps = 320,
        [int]$AudioSampleRate = 48000,
        [switch]$ReplaceOriginal,
        [switch]$KeepBackup,
        [double]$DurationToleranceSec = 2.0
    )

    $resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path
    if ($ReplaceOriginal -and (-not (Test-ReplaceOriginalSupported -InputPath $resolvedInputPath))) {
        throw "只有 mp4、m4v、mov、mkv 输入文件支持直接替换原文件。"
    }

    $resolvedOutputPath = $null
    $temporaryOutputPath = $null

    if ($ReplaceOriginal) {
        $temporaryOutputPath = New-TemporaryOutputPath -InputPath $resolvedInputPath
        $resolvedOutputPath = $temporaryOutputPath
    } elseif ($OutputPath) {
        $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    } else {
        $resolvedOutputPath = Get-DefaultOutputPath -InputPath $resolvedInputPath -Suffix $DefaultSuffix
    }

    $sourceInfo = Get-VideoInfo -ProbePath $ProbePath -FilePath $resolvedInputPath
    if (-not $sourceInfo) {
        throw "编码前无法正确读取源文件信息。"
    }

    $extension = [System.IO.Path]::GetExtension($resolvedOutputPath).ToLowerInvariant()
    $arguments = @(
        "-hide_banner"
        "-v", "error"
        "-nostats"
        "-progress", "pipe:1"
        "-stats_period", "1"
        "-y"
        "-i", $resolvedInputPath
        "-af", "aresample=$AudioSampleRate`:resampler=soxr"
    )

    if ($extension -in @(".mp4", ".m4v")) {
        $arguments += @("-movflags", "+faststart+use_metadata_tags")
    }

    $arguments += $VideoArguments
    $arguments += @(
        "-fps_mode", "cfr"
        "-c:a", "aac"
        "-b:a", ("{0}k" -f $AudioBitrateKbps)
        "-sn"
        $resolvedOutputPath
    )

    Write-Host "开始编码..." -ForegroundColor Cyan
    Write-Host ("输出位置: {0}" -f $resolvedOutputPath) -ForegroundColor DarkGray

    Initialize-VideoCompassExitHandling
    Set-VideoCompassActiveEncodeContext -ProcessId 0 -OutputPath $resolvedOutputPath

    try {
        $ffmpegResult = Invoke-FfmpegWithProgress -FfmpegPath $FfmpegPath -Arguments $arguments -SourceDurationSec $sourceInfo.DurationSec
        if ($ffmpegResult.ExitCode -ne 0) {
            if ($resolvedOutputPath -and (Test-Path -LiteralPath $resolvedOutputPath)) {
                Remove-Item -LiteralPath $resolvedOutputPath -Force
            }

            $errorText = ""
            if (-not [string]::IsNullOrWhiteSpace($ffmpegResult.StdErr)) {
                $errorLines = @($ffmpegResult.StdErr -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($errorLines.Count -gt 0) {
                    $errorText = $errorLines[-1]
                }
            }

            if ($errorText) {
                throw "ffmpeg 执行失败，退出码 $($ffmpegResult.ExitCode): $errorText"
            }

            throw "ffmpeg 执行失败，退出码 $($ffmpegResult.ExitCode)。"
        }

        $validatedOutput = Test-OutputForReplacement -ProbePath $ProbePath -SourcePath $resolvedInputPath -OutputPath $resolvedOutputPath -DurationToleranceSec $DurationToleranceSec

        $backupPath = $null
        if ($ReplaceOriginal) {
            $backupPath = Replace-OriginalFile -SourcePath $resolvedInputPath -OutputPath $resolvedOutputPath -KeepBackup:$KeepBackup
            $resolvedOutputPath = $resolvedInputPath
        }

        [pscustomobject]@{
            OutputPath = $resolvedOutputPath
            BackupPath = $backupPath
            DurationSec = $validatedOutput.DurationSec
            SizeBytes = $validatedOutput.FileSizeBytes
            VideoBitrateBps = $validatedOutput.VideoBitrateBps
            ReplacedOriginal = [bool]$ReplaceOriginal
        }
    } finally {
        Clear-VideoCompassActiveEncodeContext
    }
}
