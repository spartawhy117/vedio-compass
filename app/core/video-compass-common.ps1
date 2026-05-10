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

function Get-VideoCompassInstallRoot {
    $current = $PSScriptRoot
    for ($depth = 0; $depth -lt 6; $depth++) {
        if (
            (Test-Path -LiteralPath (Join-Path -Path $current -ChildPath "README.md")) -and
            (
                (Test-Path -LiteralPath (Join-Path -Path $current -ChildPath "tasks")) -or
                (Test-Path -LiteralPath (Join-Path -Path $current -ChildPath "app"))
            )
        ) {
            return $current
        }

        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or ($parent -eq $current)) {
            break
        }

        $current = $parent
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "..\.."))
}

function Get-VideoCompassProjectRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:VIDEO_COMPASS_PROJECT_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:VIDEO_COMPASS_PROJECT_ROOT)
    }

    return (Get-VideoCompassInstallRoot)
}

function Get-VideoCompassAppRoot {
    return (Join-Path -Path (Get-VideoCompassInstallRoot) -ChildPath "app")
}

function Get-VideoCompassCommandRoot {
    return (Join-Path -Path (Get-VideoCompassAppRoot) -ChildPath "commands")
}

function Get-VideoCompassRuntimeRoot {
    return (Join-Path -Path (Get-VideoCompassAppRoot) -ChildPath "runtime")
}

function Get-VideoCompassCommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    return (Join-Path -Path (Get-VideoCompassCommandRoot) -ChildPath $FileName)
}

function Get-VideoCompassRuntimePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    return (Join-Path -Path (Get-VideoCompassRuntimeRoot) -ChildPath $FileName)
}

function Get-VideoCompassLocalToolCandidatePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalFileName
    )

    return @(
        (Join-Path -Path (Get-VideoCompassProjectRoot) -ChildPath $LocalFileName),
        (Join-Path -Path (Get-VideoCompassInstallRoot) -ChildPath $LocalFileName),
        (Join-Path -Path (Get-VideoCompassCommandRoot) -ChildPath $LocalFileName),
        (Join-Path -Path $PSScriptRoot -ChildPath $LocalFileName)
    )
}

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

    if (-not (Get-Variable -Name "VideoCompassJobObjectTypesInitialized" -Scope Global -ErrorAction SilentlyContinue)) {
        $global:VideoCompassJobObjectTypesInitialized = $false
    }

    if (-not (Get-Variable -Name "VideoCompassProgressRenderState" -Scope Global -ErrorAction SilentlyContinue)) {
        $global:VideoCompassProgressRenderState = @{}
    }
}

Initialize-VideoCompassGlobals

function Reset-VideoCompassProgressRenderState {
    $global:VideoCompassProgressRenderState = @{}
}

function Write-VideoCompassProgress {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Id,

        [int]$ParentId = -1,

        [Parameter(Mandatory = $true)]
        [string]$Activity,

        [string]$Status = "",

        [string]$CurrentOperation = "",

        [double]$PercentComplete = 0.0,

        [switch]$Completed,

        [switch]$HideProgressBar,

        [int]$ThrottleMilliseconds = 700,

        [int]$FastChangeThrottleMilliseconds = 250,

        [double]$MinimumPercentDelta = 0.5
    )

    if (-not $global:VideoCompassProgressRenderState) {
        Reset-VideoCompassProgressRenderState
    }

    $stateKey = [string]$Id
    $now = [DateTime]::UtcNow
    $lastState = $null
    if ($global:VideoCompassProgressRenderState.ContainsKey($stateKey)) {
        $lastState = $global:VideoCompassProgressRenderState[$stateKey]
    }

    $safePercent = [Math]::Round([Math]::Min([Math]::Max($PercentComplete, 0.0), 100.0), 2)
    $shouldWrite = $true

    if ($lastState) {
        $elapsedMs = ($now - $lastState.WrittenAt).TotalMilliseconds
        $percentDelta = [Math]::Abs($safePercent - [double]$lastState.PercentComplete)
        $parentChanged = ($ParentId -ne [int]$lastState.ParentId)
        $hideBarChanged = ([bool]$HideProgressBar -ne [bool]$lastState.HideProgressBar)
        $activityChanged = ($Activity -ne [string]$lastState.Activity)
        $statusChanged = ($Status -ne [string]$lastState.Status)
        $operationChanged = ($CurrentOperation -ne [string]$lastState.CurrentOperation)
        $completedChanged = ([bool]$Completed -ne [bool]$lastState.Completed)

        if (-not $parentChanged -and -not $hideBarChanged -and -not $activityChanged -and -not $statusChanged -and -not $operationChanged -and -not $completedChanged -and ($percentDelta -lt 0.01)) {
            $shouldWrite = $false
        } elseif ($Completed -and -not [bool]$lastState.Completed) {
            $shouldWrite = $true
        } elseif ($safePercent -ge 100.0 -and [double]$lastState.PercentComplete -lt 100.0) {
            $shouldWrite = $true
        } elseif ($parentChanged -or $hideBarChanged -or $activityChanged -or $statusChanged -or $operationChanged -or $percentDelta -ge $MinimumPercentDelta) {
            $shouldWrite = ($elapsedMs -ge $FastChangeThrottleMilliseconds)
        } else {
            $shouldWrite = ($elapsedMs -ge $ThrottleMilliseconds)
        }
    }

    if (-not $shouldWrite) {
        return
    }

    if ($Completed) {
        Write-Progress -Id $Id -Activity $Activity -Completed
    } else {
        $percentArgument = if ($HideProgressBar) { -1 } else { $safePercent }
        if ($ParentId -ge 0) {
            Write-Progress -Id $Id -ParentId $ParentId -Activity $Activity -Status $Status -CurrentOperation $CurrentOperation -PercentComplete $percentArgument
        } else {
            Write-Progress -Id $Id -Activity $Activity -Status $Status -CurrentOperation $CurrentOperation -PercentComplete $percentArgument
        }
    }

    $global:VideoCompassProgressRenderState[$stateKey] = @{
        ParentId = $ParentId
        HideProgressBar = [bool]$HideProgressBar
        Activity = $Activity
        Status = $Status
        CurrentOperation = $CurrentOperation
        PercentComplete = $safePercent
        Completed = [bool]$Completed
        WrittenAt = $now
    }
}

function Set-VideoCompassActiveEncodeContext {
    param(
        [int]$ProcessId,
        [string]$OutputPath,
        [string]$InputPath = "",
        [IntPtr]$JobHandle = [IntPtr]::Zero
    )

    $global:VideoCompassActiveEncodeContext = @{
        ProcessId = $ProcessId
        OutputPath = $OutputPath
        InputPath = $InputPath
        JobHandle = $JobHandle
        WatchdogFilePath = ""
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

function Update-VideoCompassActiveEncodeJobHandle {
    param(
        [IntPtr]$JobHandle
    )

    if (-not $global:VideoCompassActiveEncodeContext) {
        return
    }

    $global:VideoCompassActiveEncodeContext.JobHandle = $JobHandle
}

function Clear-VideoCompassActiveEncodeContext {
    $global:VideoCompassActiveEncodeContext = $null
}

function Get-VideoCompassWatchdogContextDirectory {
    if ([string]::IsNullOrWhiteSpace($env:VIDEO_COMPASS_WATCHDOG_CONTEXT_DIR)) {
        return $null
    }

    $resolved = [System.IO.Path]::GetFullPath($env:VIDEO_COMPASS_WATCHDOG_CONTEXT_DIR)
    if (-not (Test-Path -LiteralPath $resolved)) {
        [void](New-Item -ItemType Directory -Path $resolved -Force)
    }

    return $resolved
}

function Register-VideoCompassWatchdogProcess {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    $context = $global:VideoCompassActiveEncodeContext
    if (-not $context) {
        return
    }

    $watchdogDir = Get-VideoCompassWatchdogContextDirectory
    if (-not $watchdogDir) {
        return
    }

    $recordPath = Join-Path -Path $watchdogDir -ChildPath ("encode-{0}-{1}.json" -f $PID, [System.Guid]::NewGuid().ToString("N"))
    $payload = [pscustomobject]@{
        parentPid = $PID
        ffmpegPid = $ProcessId
        inputPath = if ($context.ContainsKey("InputPath")) { [string]$context.InputPath } else { "" }
        outputPath = if ($context.ContainsKey("OutputPath")) { [string]$context.OutputPath } else { "" }
        writtenAt = [DateTime]::UtcNow.ToString("o")
    }

    [System.IO.File]::WriteAllText($recordPath, ($payload | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
    $context.WatchdogFilePath = $recordPath
}

function Unregister-VideoCompassWatchdogProcess {
    $context = $global:VideoCompassActiveEncodeContext
    if (-not $context) {
        return
    }

    if ($context.ContainsKey("WatchdogFilePath") -and -not [string]::IsNullOrWhiteSpace($context.WatchdogFilePath)) {
        try {
            if (Test-Path -LiteralPath $context.WatchdogFilePath) {
                Remove-Item -LiteralPath $context.WatchdogFilePath -Force -ErrorAction SilentlyContinue
            }
        } catch {
        }
    }

    $context.WatchdogFilePath = ""
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

    if ($context.ContainsKey("JobHandle") -and $context.JobHandle -and ($context.JobHandle -ne [IntPtr]::Zero)) {
        try {
            Close-VideoCompassJobHandle -JobHandle $context.JobHandle
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

    Unregister-VideoCompassWatchdogProcess
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

function Initialize-VideoCompassJobObjectTypes {
    if ($global:VideoCompassJobObjectTypesInitialized) {
        return
    }

    if (-not ("VideoCompass.JobObjectNativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace VideoCompass {
    public enum JOBOBJECTINFOCLASS {
        JobObjectExtendedLimitInformation = 9
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    public static class JobObjectNativeMethods {
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetInformationJobObject(
            IntPtr hJob,
            JOBOBJECTINFOCLASS JobObjectInfoClass,
            IntPtr lpJobObjectInfo,
            uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr hObject);
    }
}
"@
    }

    $global:VideoCompassJobObjectTypesInitialized = $true
}

function New-VideoCompassKillOnCloseJob {
    Initialize-VideoCompassJobObjectTypes

    $jobHandle = [VideoCompass.JobObjectNativeMethods]::CreateJobObject([IntPtr]::Zero, $null)
    if ($jobHandle -eq [IntPtr]::Zero) {
        throw "创建 Windows Job Object 失败。"
    }

    $info = New-Object VideoCompass.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    $info.BasicLimitInformation.LimitFlags = [VideoCompass.JobObjectNativeMethods]::JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE

    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal([Runtime.InteropServices.Marshal]::SizeOf([type][VideoCompass.JOBOBJECT_EXTENDED_LIMIT_INFORMATION]))
    try {
        [Runtime.InteropServices.Marshal]::StructureToPtr($info, $buffer, $false)
        $ok = [VideoCompass.JobObjectNativeMethods]::SetInformationJobObject(
            $jobHandle,
            [VideoCompass.JOBOBJECTINFOCLASS]::JobObjectExtendedLimitInformation,
            $buffer,
            [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][VideoCompass.JOBOBJECT_EXTENDED_LIMIT_INFORMATION]))

        if (-not $ok) {
            [void][VideoCompass.JobObjectNativeMethods]::CloseHandle($jobHandle)
            throw "设置 Windows Job Object 失败。"
        }
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }

    return $jobHandle
}

function Add-VideoCompassProcessToJob {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$JobHandle,

        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    Initialize-VideoCompassJobObjectTypes

    if ($JobHandle -eq [IntPtr]::Zero) {
        throw "Job Handle 无效。"
    }

    $assigned = [VideoCompass.JobObjectNativeMethods]::AssignProcessToJobObject($JobHandle, $Process.Handle)
    if (-not $assigned) {
        throw "将进程加入 Windows Job Object 失败。"
    }
}

function Close-VideoCompassJobHandle {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$JobHandle
    )

    Initialize-VideoCompassJobObjectTypes

    if ($JobHandle -ne [IntPtr]::Zero) {
        [void][VideoCompass.JobObjectNativeMethods]::CloseHandle($JobHandle)
    }
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

    foreach ($localPath in @(Get-VideoCompassLocalToolCandidatePaths -LocalFileName $LocalFileName)) {
        if ($localPath -and (Test-Path -LiteralPath $localPath)) {
            return $localPath
        }
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

    foreach ($localPath in @(Get-VideoCompassLocalToolCandidatePaths -LocalFileName $LocalFileName)) {
        if ($localPath -and (Test-Path -LiteralPath $localPath)) {
            return $true
        }
    }

    return $false
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

function Test-FfmpegEncoderAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FfmpegPath,

        [Parameter(Mandatory = $true)]
        [string]$EncoderName
    )

    $result = Invoke-ProcessCapture -FilePath $FfmpegPath -Arguments @("-hide_banner", "-encoders")
    if ($result.ExitCode -ne 0) {
        return $false
    }

    return ($result.StdOut -match ("(?im)^\s*[A-Z\.]+\s+{0}(\s|$)" -f [Regex]::Escape($EncoderName)))
}

function Assert-AudioCodecSupported {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FfmpegPath,

        [Parameter(Mandatory = $true)]
        [string]$AudioCodec
    )

    if (-not (Test-FfmpegEncoderAvailable -FfmpegPath $FfmpegPath -EncoderName $AudioCodec)) {
        throw "当前 ffmpeg 不支持音频编码器 $AudioCodec。请改用 aac，或更换包含该编码器的 FFmpeg 构建。"
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
    return (Join-Path -Path (Get-VideoCompassProjectRoot) -ChildPath "tasks")
}

function Get-VideoCompassTaskDirectories {
    $taskRoot = Get-TaskRootPath
    if (-not (Test-Path -LiteralPath $taskRoot)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $taskRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath "task.json") } |
            Sort-Object LastWriteTime -Descending
    )
}

function Get-VideoCompassTaskSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder
    )

    $task = Read-TaskFile -TaskFolder $TaskFolder
    $items = @($task.items)
    return [pscustomobject]@{
        Task = $task
        TaskName = [string]$task.taskName
        SourceRoot = [string]$task.sourceRoot
        PendingCount = @($items | Where-Object { $_.status -eq "pending" }).Count
        ProcessingCount = @($items | Where-Object { $_.status -eq "processing" }).Count
        DoneCount = @($items | Where-Object { $_.status -eq "done" }).Count
        FailedCount = @($items | Where-Object { $_.status -eq "failed" }).Count
        UpdatedAt = [string]$task.updatedAt
        TargetKbps = [int]$task.targetKbps
        ThresholdKbps = [int]$task.thresholdKbps
    }
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
    $totalEstimatedSavedBytes = Get-SumOrZero -Items $items -PropertyName "estimatedSavedBytes"

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
    $lines.Add("本次扫描全部优化预计可节省空间: $(Format-Bytes -Bytes $totalEstimatedSavedBytes)")
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

    Write-Host ("{0}（直接回车使用默认值: {1}）: " -f $Prompt, $DefaultValue) -NoNewline
    $response = Read-Host
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
        Write-Host ("{0}: " -f $Prompt) -NoNewline
        $response = Read-Host
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
        $value = Read-InputOrDefault -Prompt ("{0} [{1}]" -f $Prompt, ($Choices -join '/')) -DefaultValue $DefaultValue
        $normalized = $value.ToLowerInvariant()
        if ($normalizedChoices -contains $normalized) {
            return $normalized
        }

        Write-Host "请输入以下选项之一: $($Choices -join ', ')。" -ForegroundColor Yellow
    }
}

function Read-MenuChoiceOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [hashtable]$Options,

        [Parameter(Mandatory = $true)]
        [string]$DefaultKey
    )

    $orderedKeys = @($Options.Keys | Sort-Object)
    while ($true) {
        foreach ($key in $orderedKeys) {
            Write-Host ("  {0}. {1}" -f $key, $Options[$key])
        }

        $selectedKey = Read-InputOrDefault -Prompt $Prompt -DefaultValue $DefaultKey
        if ($Options.ContainsKey($selectedKey)) {
            return [string]$Options[$selectedKey]
        }

        Write-Host ("请输入以下编号之一: {0}" -f ($orderedKeys -join ", ")) -ForegroundColor Yellow
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

function Resolve-WorkerPowerShellPath {
    $candidates = @(
        (Join-Path -Path $PSHOME -ChildPath "powershell.exe"),
        (Join-Path -Path $PSHOME -ChildPath "pwsh.exe")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "找不到可用的 PowerShell 可执行文件。"
}

function Get-OutputExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $extension = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()
    if ($extension -eq ".mkv") {
        return ".mkv"
    }

    return ".mp4"
}

function Test-ReplaceOriginalSupported {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    return $true
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

function Stop-OrphanedEncodeProcessesForTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolderPath,

        [Parameter(Mandatory = $true)]
        [object]$TaskObject
    )

    $matchedProcessIds = New-Object System.Collections.Generic.HashSet[int]
    $taskFolderLower = $TaskFolderPath.ToLowerInvariant()
    $inputPathsLower = @(
        $TaskObject.items |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.path) } |
            ForEach-Object { ([string]$_.path).ToLowerInvariant() }
    )

    $candidateProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.Name -in @("powershell.exe", "pwsh.exe", "ffmpeg.exe")
    })

    foreach ($processInfo in $candidateProcesses) {
        $commandLineLower = ([string]$processInfo.CommandLine).ToLowerInvariant()
        $shouldStop = $false

        if (($processInfo.Name -in @("powershell.exe", "pwsh.exe")) -and $commandLineLower.Contains("invoke-encode-worker.ps1") -and $commandLineLower.Contains($taskFolderLower)) {
            $shouldStop = $true
        } elseif ($processInfo.Name -eq "ffmpeg.exe") {
            foreach ($inputPathLower in $inputPathsLower) {
                if ($commandLineLower.Contains($inputPathLower)) {
                    $shouldStop = $true
                    break
                }
            }
        }

        if ($shouldStop) {
            [void]$matchedProcessIds.Add([int]$processInfo.ProcessId)
        }
    }

    $stoppedCount = 0
    foreach ($processId in $matchedProcessIds) {
        try {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            for ($attempt = 0; $attempt -lt 10; $attempt++) {
                if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
                    break
                }

                Start-Sleep -Milliseconds 200
            }
            $stoppedCount++
        } catch {
        }
    }

    return $stoppedCount
}

function Invoke-VideoCompassTaskRecovery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolderPath,

        [Parameter(Mandatory = $true)]
        [object]$TaskObject,

        [string]$EncoderForRecoveryLog = "-",
        [bool]$ReplaceOriginal = $false,
        [bool]$KeepBackup = $false
    )

    $resetProcessingCount = 0
    $removedTempFileCount = 0
    $removedParallelStateFileCount = 0
    $stoppedOrphanProcessCount = Stop-OrphanedEncodeProcessesForTask -TaskFolderPath $TaskFolderPath -TaskObject $TaskObject
    $staleTempFilesByPath = @{}

    foreach ($item in @($TaskObject.items | Where-Object { $_.status -ne "done" -and -not [string]::IsNullOrWhiteSpace($_.path) })) {
        foreach ($tempFile in @(Get-TemporaryOutputFilesForInput -InputPath $item.path)) {
            $tempKey = $tempFile.FullName.ToLowerInvariant()
            if (-not $staleTempFilesByPath.ContainsKey($tempKey)) {
                $staleTempFilesByPath[$tempKey] = $tempFile
            }
        }
    }

    foreach ($parallelStateFile in @(Get-ChildItem -LiteralPath $TaskFolderPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.parallel-progress-*.json' -or $_.Name -like '.parallel-result-*.json' })) {
        try {
            Remove-Item -LiteralPath $parallelStateFile.FullName -Force
            $removedParallelStateFileCount++
        } catch {
        }
    }

    foreach ($tempFile in $staleTempFilesByPath.Values) {
        try {
            Remove-Item -LiteralPath $tempFile.FullName -Force
            $removedTempFileCount++
        } catch {
        }
    }

    foreach ($item in @($TaskObject.items | Where-Object { $_.status -eq "processing" })) {
        $item.status = "pending"
        $item.lastAttemptAt = [DateTime]::UtcNow.ToString("o")
        $item.lastResult = "检测到上次执行中断，已在本次启动前重置为待处理。"
        $item.replacedOriginal = $false
        $resetProcessingCount++
    }

    if ($resetProcessingCount -gt 0 -or $removedTempFileCount -gt 0 -or $removedParallelStateFileCount -gt 0 -or $stoppedOrphanProcessCount -gt 0) {
        $TaskObject.updatedAt = [DateTime]::UtcNow.ToString("o")
        Save-TaskFile -TaskFolder $TaskFolderPath -Task $TaskObject
        Write-TaskSummary -TaskFolder $TaskFolderPath -Task $TaskObject
        Append-HistoryLine -TaskFolder $TaskFolderPath -Line ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [DateTime]::UtcNow.ToString("o"), "-", $EncoderForRecoveryLog, $TaskObject.targetKbps, "reset_processing", $ReplaceOriginal, $KeepBackup, ("恢复了 {0} 个中断项目，删除了 {1} 个临时文件，删除了 {2} 个并行状态文件，停止了 {3} 个遗留编码进程" -f $resetProcessingCount, $removedTempFileCount, $removedParallelStateFileCount, $stoppedOrphanProcessCount))

        if ($stoppedOrphanProcessCount -gt 0) {
            Start-Sleep -Milliseconds 800
        }
    }

    return [pscustomobject]@{
        ResetProcessingCount = $resetProcessingCount
        RemovedTempFileCount = $removedTempFileCount
        RemovedParallelStateFileCount = $removedParallelStateFileCount
        StoppedOrphanProcessCount = $stoppedOrphanProcessCount
    }
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

    $sourceDirectory = Split-Path -Path $SourcePath -Parent
    $sourceBaseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $outputExtension = [System.IO.Path]::GetExtension($OutputPath)
    $destinationPath = Join-Path -Path $sourceDirectory -ChildPath ("{0}{1}" -f $sourceBaseName, $outputExtension)

    if (($destinationPath -ne $SourcePath) -and (Test-Path -LiteralPath $destinationPath)) {
        throw "替换原文件失败，目标输出路径已存在: $destinationPath"
    }

    $backupPath = New-BackupPath -InputPath $SourcePath
    Move-Item -LiteralPath $SourcePath -Destination $backupPath

    try {
        Move-Item -LiteralPath $OutputPath -Destination $destinationPath
        if (-not $KeepBackup) {
            Remove-Item -LiteralPath $backupPath -Force
            return [pscustomobject]@{
                BackupPath = $null
                OutputPath = $destinationPath
            }
        }

        return [pscustomobject]@{
            BackupPath = $backupPath
            OutputPath = $destinationPath
        }
    } catch {
        if (Test-Path -LiteralPath $OutputPath) {
            Remove-Item -LiteralPath $OutputPath -Force
        }

        if (($destinationPath -ne $SourcePath) -and (Test-Path -LiteralPath $destinationPath)) {
            Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
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

function Get-BatchProgressSummaryText {
    param(
        [double]$TotalSizeBytes = 0.0,
        [double]$EstimatedSavedBytes = 0.0
    )

    $parts = New-Object System.Collections.Generic.List[string]
    if ($TotalSizeBytes -gt 0) {
        $parts.Add(("总量 {0}" -f (Format-Bytes -Bytes $TotalSizeBytes)))
    }

    if ($EstimatedSavedBytes -gt 0) {
        $parts.Add(("节省 {0}" -f (Format-Bytes -Bytes $EstimatedSavedBytes)))
    }

    return ($parts -join " | ")
}

function Test-EtaDisplayReady {
    param(
        [double]$PercentComplete = 0.0,
        [double]$ElapsedSec = 0.0,
        [double]$ProcessedSec = 0.0,
        [double]$MinimumPercent = 5.0,
        [double]$MinimumElapsedSec = 30.0,
        [double]$MinimumProcessedSec = 30.0
    )

    return (
        ($PercentComplete -ge $MinimumPercent) -and
        ($ElapsedSec -ge $MinimumElapsedSec) -and
        ($ProcessedSec -ge $MinimumProcessedSec)
    )
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

function Write-ParallelProgressSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Percent,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [string]$CurrentOperation = "",

        [double]$EtaSec = 0.0
    )

    $progressFile = $env:VIDEO_COMPASS_PARALLEL_PROGRESS_FILE
    if ([string]::IsNullOrWhiteSpace($progressFile)) {
        return
    }

    $payload = [pscustomobject]@{
        label = $env:VIDEO_COMPASS_PARALLEL_PROGRESS_LABEL
        percent = [Math]::Round($Percent, 2)
        status = $Status
        currentOperation = $CurrentOperation
        etaSec = [Math]::Round($EtaSec, 2)
        updatedAt = [DateTime]::UtcNow.ToString("o")
    }

    try {
        $json = $payload | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($progressFile, $json, [System.Text.Encoding]::UTF8)
    } catch {
    }
}

function Test-VideoCompassTextOnlyMainProgress {
    return ($env:VIDEO_COMPASS_TEXT_ONLY_MAIN_PROGRESS -eq "1")
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

    $currentEtaReady = Test-EtaDisplayReady -PercentComplete $currentPercent -ElapsedSec $currentElapsedSec -ProcessedSec $safeCurrentOutTime
    $currentStatus = if ($currentEtaReady) {
        "当前文件预计剩余 {0}" -f (Format-DurationClock -TotalSeconds $currentEtaSec)
    } else {
        "当前文件预计剩余估算中..."
    }
    $textOnlyMainProgress = Test-VideoCompassTextOnlyMainProgress
    $currentSnapshotEtaSec = if ($currentEtaReady) { $currentEtaSec } else { 0.0 }
    $currentOperation = ("已编码 {0:N1}%" -f $currentPercent)
    Write-VideoCompassProgress -Id 1 -Activity "正在压缩当前文件" -Status $currentStatus -CurrentOperation $currentOperation -PercentComplete $currentPercent -HideProgressBar:$textOnlyMainProgress
    Write-ParallelProgressSnapshot -Percent $currentPercent -Status $currentStatus -CurrentOperation $currentOperation -EtaSec $currentSnapshotEtaSec

    $batchTotalCount = [int](ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_TOTAL_COUNT)
    if ($batchTotalCount -le 0) {
        return
    }

    $batchCurrentIndex = [int](ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_CURRENT_INDEX)
    $batchTotalMediaSec = ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_TOTAL_MEDIA_SEC
    $batchCompletedMediaSec = ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_COMPLETED_MEDIA_SEC
    $batchTotalSizeBytes = ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_TOTAL_SIZE_BYTES
    $batchEstimatedSavedBytes = ConvertTo-DoubleOrZero -Value $env:VIDEO_COMPASS_BATCH_ESTIMATED_SAVED_BYTES
    $batchSummaryText = Get-BatchProgressSummaryText -TotalSizeBytes $batchTotalSizeBytes -EstimatedSavedBytes $batchEstimatedSavedBytes

    if ($batchTotalMediaSec -le 0) {
        $batchPercent = [Math]::Min((([Math]::Max($batchCurrentIndex - 1, 0) + ($currentPercent / 100.0)) / $batchTotalCount) * 100.0, 100.0)
        $batchStatus = "本轮预计剩余计算中..."
        $batchOperation = ("第 {0}/{1} 个" -f $batchCurrentIndex, $batchTotalCount)
        if (-not [string]::IsNullOrWhiteSpace($batchSummaryText)) {
            $batchOperation = ("{0} | {1}" -f $batchOperation, $batchSummaryText)
        }
        Write-VideoCompassProgress -Id 2 -Activity "批量压缩任务" -Status $batchStatus -CurrentOperation $batchOperation -PercentComplete $batchPercent -HideProgressBar:$textOnlyMainProgress
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
    $batchElapsedSec = 0.0
    if ($batchStartedAtUtc) {
        $batchElapsedSec = [Math]::Max(([DateTime]::UtcNow - $batchStartedAtUtc).TotalSeconds, 0.001)
        if ($processedMediaSec -gt 0.1) {
            $batchRate = $processedMediaSec / $batchElapsedSec
            if ($batchRate -gt 0) {
                $batchEtaSec = [Math]::Max(($batchTotalMediaSec - $processedMediaSec) / $batchRate, 0.0)
            }
        }
    }

    $batchEtaReady = Test-EtaDisplayReady -PercentComplete $batchPercent -ElapsedSec $batchElapsedSec -ProcessedSec $processedMediaSec -MinimumElapsedSec 45.0 -MinimumProcessedSec 45.0
    $batchStatus = if ($batchEtaReady) {
        "本轮预计剩余 {0}" -f (Format-DurationClock -TotalSeconds $batchEtaSec)
    } else {
        "本轮预计剩余计算中..."
    }
    $batchOperation = ("第 {0}/{1} 个" -f $batchCurrentIndex, $batchTotalCount)
    if (-not [string]::IsNullOrWhiteSpace($batchSummaryText)) {
        $batchOperation = ("{0} | {1}" -f $batchOperation, $batchSummaryText)
    }
    Write-VideoCompassProgress -Id 2 -Activity "批量压缩任务" -Status $batchStatus -CurrentOperation $batchOperation -PercentComplete $batchPercent -HideProgressBar:$textOnlyMainProgress
}

function Show-EncodeFinalizationProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [string]$CurrentOperation = "正在收尾..."
    )

    $textOnlyMainProgress = Test-VideoCompassTextOnlyMainProgress
    Write-VideoCompassProgress -Id 1 -Activity "正在压缩当前文件" -Status $Status -CurrentOperation $CurrentOperation -PercentComplete 100 -HideProgressBar:$textOnlyMainProgress
    Write-ParallelProgressSnapshot -Percent 100 -Status $Status -CurrentOperation $CurrentOperation -EtaSec 0
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
    $jobHandle = [IntPtr]::Zero

    try {
        Initialize-VideoCompassExitHandling

        [void]$process.Start()
        $processStarted = $true
        $jobHandle = New-VideoCompassKillOnCloseJob
        Add-VideoCompassProcessToJob -JobHandle $jobHandle -Process $process
        Update-VideoCompassActiveEncodeProcessId -ProcessId $process.Id
        Update-VideoCompassActiveEncodeJobHandle -JobHandle $jobHandle
        Register-VideoCompassWatchdogProcess -ProcessId $process.Id

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
        Write-VideoCompassProgress -Id 1 -Activity "正在压缩当前文件" -Completed

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdErr = $stderr
        }
    } finally {
        Write-VideoCompassProgress -Id 1 -Activity "正在压缩当前文件" -Completed
        Unregister-VideoCompassWatchdogProcess
        if ($jobHandle -ne [IntPtr]::Zero) {
            try {
                Close-VideoCompassJobHandle -JobHandle $jobHandle
            } catch {
            }
        }
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

        [string[]]$InputArguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$DefaultSuffix,

        [int]$AudioBitrateKbps = 320,
        [int]$AudioSampleRate = 48000,
        [ValidateSet("aac", "libfdk_aac")]
        [string]$AudioCodec = "aac",
        [switch]$ReplaceOriginal,
        [switch]$KeepBackup,
        [double]$DurationToleranceSec = 2.0
    )

    $resolvedInputPath = (Resolve-Path -LiteralPath $InputPath).Path
    if ($ReplaceOriginal -and (-not (Test-ReplaceOriginalSupported -InputPath $resolvedInputPath))) {
        throw "当前输入文件不支持直接替换原文件。"
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

    Assert-AudioCodecSupported -FfmpegPath $FfmpegPath -AudioCodec $AudioCodec

    $extension = [System.IO.Path]::GetExtension($resolvedOutputPath).ToLowerInvariant()
    $arguments = @(
        "-hide_banner"
        "-v", "error"
        "-nostats"
        "-progress", "pipe:1"
        "-stats_period", "1"
        "-y"
    )

    if ($InputArguments -and $InputArguments.Count -gt 0) {
        $arguments += $InputArguments
    }

    $arguments += @(
        "-i", $resolvedInputPath
        "-af", "aresample=$AudioSampleRate`:resampler=soxr"
    )

    if ($extension -in @(".mp4", ".m4v")) {
        $arguments += @("-movflags", "+faststart+use_metadata_tags")
    }

    $arguments += $VideoArguments
    $arguments += @(
        "-fps_mode", "cfr"
        "-c:a", $AudioCodec
        "-b:a", ("{0}k" -f $AudioBitrateKbps)
        "-sn"
        $resolvedOutputPath
    )

    Write-Host "开始编码..." -ForegroundColor Cyan
    Write-Host ("输出位置: {0}" -f $resolvedOutputPath) -ForegroundColor DarkGray

    Initialize-VideoCompassExitHandling
    Set-VideoCompassActiveEncodeContext -ProcessId 0 -OutputPath $resolvedOutputPath -InputPath $resolvedInputPath -JobHandle ([IntPtr]::Zero)

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

        Show-EncodeFinalizationProgress -Status "编码已完成，正在校验输出文件..." -CurrentOperation "ffmpeg 已结束，正在做完整性检查"
        $validatedOutput = Test-OutputForReplacement -ProbePath $ProbePath -SourcePath $resolvedInputPath -OutputPath $resolvedOutputPath -DurationToleranceSec $DurationToleranceSec

        $backupPath = $null
        if ($ReplaceOriginal) {
            $replaceStatus = if ($KeepBackup) {
                "编码已完成，正在替换原文件并保留备份..."
            } else {
                "编码已完成，正在替换原文件..."
            }
            Show-EncodeFinalizationProgress -Status $replaceStatus -CurrentOperation "正在移动文件并完成收尾"
            $replaceResult = Replace-OriginalFile -SourcePath $resolvedInputPath -OutputPath $resolvedOutputPath -KeepBackup:$KeepBackup
            $backupPath = $replaceResult.BackupPath
            $resolvedOutputPath = $replaceResult.OutputPath
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
