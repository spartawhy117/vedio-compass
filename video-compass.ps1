Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "app\core\video-compass-common.ps1")

function Clear-VideoCompassScreen {
    try {
        Clear-Host
    } catch {
    }
}

function Wait-ForMenuReturn {
    Write-Host ""
    Write-Host "按回车返回菜单..." -ForegroundColor DarkGray
    [void](Read-Host)
}

function Invoke-ExecutionOperation {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("scan", "compress", "repair-metadata", "env-check")]
        [string]$Operation,

        [hashtable]$Parameters = @{}
    )

    Clear-VideoCompassScreen
    $executionScript = Get-VideoCompassRuntimePath -FileName "invoke-execution-session.ps1"
    $powerShellPath = Resolve-WorkerPowerShellPath
    $argumentList = New-Object System.Collections.Generic.List[string]
    $argumentList.Add("-NoProfile")
    $argumentList.Add("-ExecutionPolicy")
    $argumentList.Add("Bypass")
    $argumentList.Add("-File")
    $argumentList.Add($executionScript)
    $argumentList.Add("-Operation")
    $argumentList.Add($Operation)

    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $argumentList.Add("-$key")
            }
            continue
        }

        if ($null -eq $value) {
            continue
        }

        $argumentList.Add("-$key")
        $argumentList.Add([string]$value)
    }

    & $powerShellPath @argumentList
    return $LASTEXITCODE
}

function Show-TaskSummaryText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder
    )

    $summaryPath = Join-Path -Path $TaskFolder -ChildPath "summary.txt"
    if (Test-Path -LiteralPath $summaryPath) {
        Get-Content -LiteralPath $summaryPath
    } else {
        $summary = Get-VideoCompassTaskSummary -TaskFolder $TaskFolder
        @(
            "任务名称: $($summary.TaskName)"
            "源目录: $($summary.SourceRoot)"
            "待处理: $($summary.PendingCount)"
            "处理中: $($summary.ProcessingCount)"
            "已完成: $($summary.DoneCount)"
            "失败: $($summary.FailedCount)"
        )
    }
}

function Select-TaskFolder {
    $taskDirectories = @(Get-VideoCompassTaskDirectories)
    if ($taskDirectories.Count -eq 0) {
        Write-Host "当前没有可管理的任务目录。" -ForegroundColor Yellow
        return $null
    }

    Write-Host "可管理的任务:" -ForegroundColor Cyan
    for ($index = 0; $index -lt $taskDirectories.Count; $index++) {
        $summary = Get-VideoCompassTaskSummary -TaskFolder $taskDirectories[$index].FullName
        Write-Host ("  {0}. {1} | pending {2} | done {3} | failed {4}" -f ($index + 1), $summary.TaskName, $summary.PendingCount, $summary.DoneCount, $summary.FailedCount)
    }

    while ($true) {
        $inputValue = Read-Host "输入任务编号（直接回车返回）"
        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            return $null
        }

        $parsed = 0
        if ([int]::TryParse($inputValue, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $taskDirectories.Count) {
            return $taskDirectories[$parsed - 1].FullName
        }

        Write-Host "编号无效，请重新输入。" -ForegroundColor Yellow
    }
}

function Invoke-CompressTaskInteractive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder
    )

    $task = Read-TaskFile -TaskFolder $TaskFolder
    $pendingCount = @($task.items | Where-Object { $_.status -eq "pending" }).Count
    if ($pendingCount -le 0) {
        Write-Host "当前任务没有待处理项目。" -ForegroundColor Yellow
        Wait-ForMenuReturn
        return
    }

    $count = Read-IntOrDefault -Prompt "本次要处理多少个文件" -DefaultValue $pendingCount
    $parallelCount = Read-IntOrDefault -Prompt "并行任务数（当前支持 1 或 2）" -DefaultValue 1
    if ($parallelCount -notin @(1, 2)) {
        Write-Host "并行任务数当前只支持 1 或 2。" -ForegroundColor Yellow
        Wait-ForMenuReturn
        return
    }

    Write-Host "请选择编码器：" -ForegroundColor Cyan
    $encoder = Read-MenuChoiceOrDefault -Prompt "输入编号" -Options @{
        "1" = "qsv"
        "2" = "nvenc"
        "3" = "amf"
        "4" = "cpu"
    } -DefaultKey "1"
    $audioCodec = Read-ChoiceOrDefault -Prompt "音频编码器" -Choices @("aac", "libfdk_aac") -DefaultValue "aac"
    $replaceOriginal = if (Read-YesNoOrDefault -Prompt "压缩成功后是否替换原文件" -DefaultValue $true) { "yes" } else { "no" }
    $keepBackup = if (Read-YesNoOrDefault -Prompt "替换原文件时是否保留备份" -DefaultValue $false) { "yes" } else { "no" }

    [void](Invoke-ExecutionOperation -Operation "compress" -Parameters @{
        TaskFolder = $TaskFolder
        Count = $count
        ParallelCount = $parallelCount
        Encoder = $encoder
        AudioCodec = $audioCodec
        ReplaceOriginalMode = $replaceOriginal
        KeepBackupMode = $keepBackup
    })
    Wait-ForMenuReturn
}

function Invoke-RecoverTaskInteractive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder
    )

    $task = Read-TaskFile -TaskFolder $TaskFolder
    $result = Invoke-VideoCompassTaskRecovery -TaskFolderPath $TaskFolder -TaskObject $task
    Write-Host ("已重置 processing: {0}" -f $result.ResetProcessingCount)
    Write-Host ("已删除临时文件: {0}" -f $result.RemovedTempFileCount)
    Write-Host ("已删除并行状态文件: {0}" -f $result.RemovedParallelStateFileCount)
    Write-Host ("已停止遗留进程: {0}" -f $result.StoppedOrphanProcessCount)
    Wait-ForMenuReturn
}

function Remove-TaskFolderInteractive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder
    )

    if (-not (Read-YesNoOrDefault -Prompt ("确认删除任务目录 {0}" -f (Split-Path -Path $TaskFolder -Leaf)) -DefaultValue $false)) {
        return
    }

    Remove-Item -LiteralPath $TaskFolder -Recurse -Force
    Write-Host "任务目录已删除。" -ForegroundColor Yellow
    Wait-ForMenuReturn
}

function Show-TaskManagementMenu {
    while ($true) {
        Clear-VideoCompassScreen
        $taskFolder = Select-TaskFolder
        if (-not $taskFolder) {
            return
        }

        while ($true) {
            Clear-VideoCompassScreen
            Show-TaskSummaryText -TaskFolder $taskFolder
            Write-Host ""
            Write-Host "1. 继续压缩"
            Write-Host "2. 清理并恢复"
            Write-Host "3. 删除任务目录"
            Write-Host "4. 返回任务列表"
            $choice = Read-Host "选择操作"
            switch ($choice) {
                "1" { Invoke-CompressTaskInteractive -TaskFolder $taskFolder; break }
                "2" { Invoke-RecoverTaskInteractive -TaskFolder $taskFolder; break }
                "3" { Remove-TaskFolderInteractive -TaskFolder $taskFolder; break }
                "4" { break }
                default {
                    Write-Host "输入无效。" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 700
                }
            }
        }
    }
}

function Start-NewTaskInteractive {
    Clear-VideoCompassScreen
    $rootPath = Read-RequiredInput -Prompt "扫描目录"
    $thresholdKbps = Read-IntOrDefault -Prompt "扫描基准线码率（kbps）" -DefaultValue 4500
    $targetKbps = Read-IntOrDefault -Prompt "目标压缩码率（kbps）" -DefaultValue 3500

    [void](Invoke-ExecutionOperation -Operation "scan" -Parameters @{
        RootPath = $rootPath
        ThresholdKbps = $thresholdKbps
        TargetKbps = $targetKbps
    })

    $resolvedRootPath = (Resolve-Path -LiteralPath $rootPath).Path
    $taskFolder = Get-TaskFolderPath -SourceRoot $resolvedRootPath -ThresholdKbps $thresholdKbps -TargetKbps $targetKbps
    if (Test-Path -LiteralPath $taskFolder) {
        Write-Host ""
        Show-TaskSummaryText -TaskFolder $taskFolder
        Write-Host ""
        if (Read-YesNoOrDefault -Prompt "是否立即压缩这个任务" -DefaultValue $true) {
            Invoke-CompressTaskInteractive -TaskFolder $taskFolder
            return
        }
    }

    Wait-ForMenuReturn
}

function Show-RecoveryMenu {
    while ($true) {
        Clear-VideoCompassScreen
        Write-Host "清理与恢复" -ForegroundColor Cyan
        Write-Host "1. 恢复全部任务"
        Write-Host "2. 恢复指定任务"
        Write-Host "3. 返回"
        $choice = Read-Host "选择操作"

        switch ($choice) {
            "1" {
                $taskDirs = @(Get-VideoCompassTaskDirectories)
                foreach ($dir in $taskDirs) {
                    $task = Read-TaskFile -TaskFolder $dir.FullName
                    [void](Invoke-VideoCompassTaskRecovery -TaskFolderPath $dir.FullName -TaskObject $task)
                }
                Write-Host "已完成全部任务的恢复扫描。" -ForegroundColor Green
                Wait-ForMenuReturn
            }
            "2" {
                $taskFolder = Select-TaskFolder
                if ($taskFolder) {
                    Invoke-RecoverTaskInteractive -TaskFolder $taskFolder
                }
            }
            "3" { return }
            default {
                Write-Host "输入无效。" -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

while ($true) {
    Clear-VideoCompassScreen
    Write-Host "Video Compass" -ForegroundColor Cyan
    Write-Host "1. 开始新任务"
    Write-Host "2. 管理已有任务"
    Write-Host "3. 清理与恢复"
    Write-Host "4. 环境检查"
    Write-Host "5. 退出"

    $mainChoice = Read-Host "选择操作"
    switch ($mainChoice) {
        "1" { Start-NewTaskInteractive }
        "2" { Show-TaskManagementMenu }
        "3" { Show-RecoveryMenu }
        "4" {
            [void](Invoke-ExecutionOperation -Operation "env-check")
            Wait-ForMenuReturn
        }
        "5" { break }
        default {
            Write-Host "输入无效。" -ForegroundColor Yellow
            Start-Sleep -Milliseconds 700
        }
    }
}
