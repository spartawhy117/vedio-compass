# Video Compass

[中文](./README.md) | [English](./README.en.md)

一个面向 Windows 的视频库扫描与批量压缩工具。

解压后直接运行 `start.cmd`，就可以在当前目录里：

- 新建扫描任务
- 继续已有压缩任务
- 清理中断残留
- 做环境检查

## 特点

- 单入口：不需要分别点多个 `.ps1`
- 任务化：扫描结果会写入 `tasks/`
- 可恢复：中断后可以继续处理
- 多编码器：支持 `qsv` / `nvenc` / `amf` / `cpu`

## 环境要求

- Windows
- PowerShell 5.1 或 PowerShell 7+
- `ffmpeg.exe`
- `ffprobe.exe`

工具会优先从 `PATH` 查找 `ffmpeg.exe` 和 `ffprobe.exe`。

如果想先检查环境：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\app\commands\check-video-compass-env.ps1
```

## 快速开始

### 1. 启动

直接双击：

```text
start.cmd
```

或手动执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\video-compass.ps1
```

### 2. 选择操作

启动后会进入统一菜单：

1. 开始新任务
2. 管理已有任务
3. 清理与恢复
4. 环境检查
5. 退出

### 3. 新建任务

扫描时会询问：

- 扫描目录
- 扫描阈值码率
- 目标压缩码率

扫描完成后会生成任务目录，例如：

```text
tasks/<目录名>__scan-4500__target-3500/
  task.json
  summary.txt
  history.log
```

### 4. 继续压缩

从任务列表中选择一个已有任务后，可以：

- 查看摘要
- 继续压缩待处理项
- 重置中断状态
- 清理临时文件和并行状态文件
- 删除任务目录

## 中断与恢复

压缩任务运行在独立执行进程中，并带有 watchdog。

如果压缩过程中脚本被关闭，工具会尽量：

- 停止对应 `ffmpeg`
- 删除遗留临时输出
- 把任务恢复为可继续状态

下次启动时还会再次做恢复扫描，处理：

- `processing -> pending`
- 遗留 `.codex-temp-*`
- 遗留 `.parallel-progress-*` / `.parallel-result-*`
- 遗留 `ffmpeg` / worker 进程

## 目录结构

用户最关心的目录通常只有这些：

```text
video-compass/
  start.cmd
  video-compass.ps1
  tasks/
  app/
  README.md
  README.en.md
```

说明：

- `tasks/`：任务数据目录
- `app/`：内部脚本目录
- `app/core/`：公共逻辑
- `app/commands/`：功能命令
- `app/runtime/`：执行会话与 watchdog

## 任务文件

每个任务目录包含：

- `task.json`：任务状态
- `summary.txt`：任务摘要
- `history.log`：处理历史

## 说明

- 当前只支持 Windows
- 当前不提供跨平台支持承诺
- `e2e/` 仅用于开发验证，不属于最终 release 发包内容
