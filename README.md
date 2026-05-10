# Video Compass

Windows 下的视频扫描、任务管理与批量压缩工具。

当前版本的目标不是“提供一堆分散脚本”，而是提供一个 **解压即用、单入口管理** 的工作流：

- 新建扫描任务
- 继续已有任务
- 清理和恢复中断任务
- 环境检查

## 快速开始

### 1. 准备环境

要求：

- Windows
- PowerShell 5.1 或 PowerShell 7+
- `ffmpeg.exe`
- `ffprobe.exe`

工具会优先从 `PATH` 查找 `ffmpeg.exe` 和 `ffprobe.exe`。

如果想先检查环境：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\app\commands\check-video-compass-env.ps1
```

### 2. 启动工具

推荐直接双击：

```text
start.cmd
```

或手动执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\video-compass.ps1
```

启动后会进入统一菜单。

## 统一入口包含什么

当前入口支持：

1. 开始新任务
2. 管理已有任务
3. 清理与恢复
4. 环境检查
5. 退出

其中“管理已有任务”支持：

- 查看任务摘要
- 继续压缩
- 重置中断状态
- 清理临时文件和并行状态文件
- 删除任务目录

## 工作流

### 新建任务

统一入口会收集：

- 扫描目录
- 扫描阈值码率
- 目标压缩码率

扫描完成后会在 `tasks/` 下生成任务目录，例如：

```text
tasks/<目录名>__scan-4500__target-3500/
  task.json
  summary.txt
  history.log
```

### 继续压缩

从任务列表里选择已有任务后，可以继续压缩待处理项。  
压缩时仍支持：

- `qsv`
- `nvenc`
- `amf`
- `cpu`

## 中断与恢复

当前版本针对“脚本被关掉但 `ffmpeg` 还在跑”的问题做了专门治理：

- 长任务在独立执行子进程中运行
- 压缩链路配有独立 watchdog
- 如果执行子进程被强杀，watchdog 会尝试回收对应 `ffmpeg`
- 下次启动时仍会做任务恢复和临时文件清理

恢复时会处理：

- `processing -> pending`
- 遗留 `.codex-temp-*`
- 遗留 `.parallel-progress-*` / `.parallel-result-*`
- 遗留 `ffmpeg` / worker 进程

## 目录结构

最终用户可见的核心结构：

```text
video-compass/
  start.cmd
  video-compass.ps1
  tasks/
  app/
  README.md
```

内部脚本已经下沉到：

```text
app/
  core/
  commands/
  runtime/
```

## 任务文件

每个任务目录包含：

- `task.json`：任务状态源
- `summary.txt`：摘要
- `history.log`：历史记录

当前实现仍保持旧任务格式兼容。

## 开发验证

仓库中包含 `e2e/` 目录，用于开发期端到端验证。

注意：

- `e2e/` 不属于最终 release 发包内容
- `e2e/workspace/` 是测试工作区，不应手动提交

已提供的验证脚本包括：

- `e2e/fixtures/reset-test-workspace.ps1`
- `e2e/scripts/test-watchdog-kill.ps1`
- `e2e/scripts/test-task-recovery.ps1`
- `e2e/scripts/test-repeated-execution.ps1`

## 说明

- 当前只支持 Windows
- 当前不做跨平台支持承诺
- 当前首页采用菜单式 PowerShell 交互，不做重型全屏 TUI
