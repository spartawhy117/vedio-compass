# Video Compass

<p align="center">Windows 下的视频扫描与批量压缩 PowerShell 工具</p>

<p align="center">
  基于 FFmpeg，支持 <code>qsv</code> / <code>nvenc</code> / <code>amf</code> / <code>cpu</code> 四种编码路径
</p>

<p align="center">
  先扫描，再生成任务，再按任务批量压缩
</p>

---

## Overview

Video Compass 适合这类使用场景：

- 你想先按码率筛出候选文件，再决定是否压缩
- 你想批量处理视频，而不是一个个手动点 GUI
- 你希望压缩成功后自动替换原文件，或者保留备份
- 你想保留任务状态、摘要和历史记录，方便中断后继续处理

文档中的示例路径统一使用 `xxxx` 作为占位目录，实际使用时请替换成自己的路径。

---

## Why This Tool

相比常见的 GUI 压缩软件，这套脚本更偏向“整理视频库”的工作流：

| 能力 | 说明 |
| --- | --- |
| 扫描筛选 | 先按阈值扫描目录，只处理真正需要压缩的文件 |
| 批量任务 | 扫描结果会写入 `task.json`，后续可分批继续跑 |
| 多编码路径 | 支持 `qsv` / `nvenc` / `amf` / `cpu` |
| 原位替换 | 可在压缩成功后替换原文件，也可保留备份 |
| 中断恢复 | 脚本退出后会尽量回收临时文件并恢复任务状态 |

---

## Recommended Setup

如果你的机器同时有独显和 Intel 核显，默认推荐下面这套组合：

| 场景 | 推荐 |
| --- | --- |
| 后台慢慢压缩 | `qsv` |
| 并发数量 | `ParallelCount = 1` |
| 日常办公同时进行 | 优先让压缩任务使用核显 |

原因很简单：

- 独显同时承担桌面渲染、浏览器和视频编码时，更容易影响前台体验
- QSV 更适合在后台长期跑批量任务
- 并发设为 `1` 时，通常更稳，也更不容易把显示和系统响应拖慢

如果你的目标不是极限速度，而是尽量不影响日常使用，那么“开启核显 + 使用 QSV + 并发设为 1”通常是最稳妥的默认方案。

---

## Encoder Paths

| 编码路径 | 适用硬件 | 说明 |
| --- | --- | --- |
| `qsv` | Intel 核显 / Intel 媒体引擎 | 适合后台批量压缩 |
| `nvenc` | NVIDIA 独显 | 编码速度通常较高 |
| `amf` | AMD 独显 / AMD APU | 适合 AMD 平台 |
| `cpu` | 任意 CPU | 兼容性最高，但通常最慢 |

如果你希望压缩时尽量不影响浏览器或桌面体验，优先选择不和当前前台渲染显卡冲突的编码路径。

---

## Requirements

- Windows
- PowerShell 5.1 或 PowerShell 7+
- `ffmpeg.exe`
- `ffprobe.exe`

脚本会优先从 `PATH` 查找 `ffmpeg.exe` 和 `ffprobe.exe`。

建议首次使用前先执行：

右键 [check-video-compass-env.ps1](./check-video-compass-env.ps1)，选择“使用 PowerShell 运行”。

如果缺少 FFmpeg，可执行：

先打开 PowerShell，再手动执行：

```powershell
.\check-video-compass-env.ps1 -InstallFfmpeg
```

---

## Quick Start

### 1. 扫描目录

右键 [analyze-video-bitrate.ps1](./analyze-video-bitrate.ps1)，选择“使用 PowerShell 运行”。
根据提示填写参数，或直接回车使用默认值。

运行结束后会生成一个任务目录，例如：

```text
tasks/<目录名>__scan-4500__target-3500/
  task.json
  summary.txt
  history.log
```

这三个文件分别用于：

| 文件 | 作用 |
| --- | --- |
| `task.json` | 当前任务状态源 |
| `summary.txt` | 本次扫描摘要和预计节省空间 |
| `history.log` | 处理历史记录 |

### 2. 按任务批量压缩

右键 [compress-from-task.ps1](./compress-from-task.ps1)，选择“使用 PowerShell 运行”。
根据提示填写参数，或直接回车使用默认值。

### 3. 单文件压缩

右键任意一个单文件编码脚本，例如 [encode-hevc-nvenc-ffmpeg.ps1](./encode-hevc-nvenc-ffmpeg.ps1)，选择“使用 PowerShell 运行”。
根据提示填写参数，或直接回车使用默认值。

### 4. 修复 Windows 码率为 0 的元数据

右键 [repair-zero-system-bitrate.ps1](./repair-zero-system-bitrate.ps1)，选择“使用 PowerShell 运行”。
根据提示填写参数，或直接回车使用默认值。

当前主要对 `.mp4 / .mov / .m4v` 的 Windows 码率元数据修复更可靠。

---

## Workflow

### 扫描阶段

如果不带参数运行 [analyze-video-bitrate.ps1](./analyze-video-bitrate.ps1)，脚本会依次询问：

- 扫描目录
- 扫描阈值码率
- 目标压缩码率

当前扫描阶段会显示：

- 当前扫描到第几个文件
- 整体百分比

当前扫描阶段不显示剩余预计时间。

### 压缩阶段

如果不带参数运行 [compress-from-task.ps1](./compress-from-task.ps1)，脚本会依次询问：

- 任务目录
- 本次处理数量
- 并行任务数
- 编码器编号：`1=qsv` / `2=nvenc` / `3=amf` / `4=cpu`
- 音频编码器：`aac` / `libfdk_aac`
- 是否替换原文件
- 是否保留备份

压缩阶段当前会显示：

- 当前文件状态
- 本轮总进度
- 本轮 ETA
- 并行模式下的槽位百分比

总进度按照“本轮待处理文件的总时长”估算，不按文件数量平均。

---

## Parameters

### `compress-from-task.ps1`

| 参数 | 说明 |
| --- | --- |
| `TaskFolder` | 扫描后生成的任务目录 |
| `Count` | 本次要处理多少个视频 |
| `ParallelCount` | 并行任务数，当前支持 `1` 或 `2` |
| `Encoder` | `qsv` / `nvenc` / `amf` / `cpu` |
| `AudioCodec` | `aac` 或 `libfdk_aac` |
| `ReplaceOriginalMode` | 压缩成功后是否替换原文件 |
| `KeepBackupMode` | 替换原文件时是否保留备份 |

补充规则：

- 不带 `-Count` 时，默认值会显示为剩余 `pending` 文件总数
- 如果输入数量大于剩余待处理总数，脚本会自动按剩余数量执行
- `ParallelCount = 2` 时，会为每个 worker 单独生成状态文件
- 启用替换原文件时，会使用唯一的 `.codex-temp-*` 临时输出，避免并行任务互相覆盖

### 支持的输入格式

- `.mp4`
- `.mkv`
- `.avi`
- `.mov`
- `.wmv`
- `.flv`
- `.webm`
- `.m4v`
- `.ts`
- `.mts`
- `.m2ts`

输出规则：

- 只有 `.mkv` 会保留 `.mkv`
- 其余格式压缩输出时统一转成 `.mp4`
- 如果启用原位替换，最终会由新输出文件接管原路径语义

---

## Interrupt Recovery

正常关闭脚本、`Ctrl+C`、PowerShell 正常退出时，脚本会尽力：

- 停掉当前 `ffmpeg`
- 删除当前 `.codex-temp-*` 临时输出
- 把当前项目写回 `pending`
- 在 `history.log` 中追加 `interrupted` 记录

如果是强杀进程、直接结束终端树、断电这类极端中断，脚本当时未必来得及回写状态。

下次启动 [compress-from-task.ps1](./compress-from-task.ps1) 时，脚本会自动恢复：

- 把 `processing` 项重置回 `pending`
- 清理遗留 `.codex-temp-*` 临时文件
- 清理遗留 `.parallel-progress-*` / `.parallel-result-*` 状态文件
- 停掉与当前任务相关的遗留 `invoke-encode-worker.ps1` / `ffmpeg.exe`

通常不需要手动修改 `task.json`。

---

## Core Scripts

| 脚本 | 用途 |
| --- | --- |
| [analyze-video-bitrate.ps1](./analyze-video-bitrate.ps1) | 扫描目录并生成任务 |
| [compress-from-task.ps1](./compress-from-task.ps1) | 从任务目录中按顺序压缩前 `N` 个 `pending` 文件 |
| [encode-hevc-qsv-ffmpeg.ps1](./encode-hevc-qsv-ffmpeg.ps1) | Intel QSV 单文件压缩 |
| [encode-hevc-nvenc-ffmpeg.ps1](./encode-hevc-nvenc-ffmpeg.ps1) | NVIDIA NVENC 单文件压缩 |
| [encode-hevc-amf-ffmpeg.ps1](./encode-hevc-amf-ffmpeg.ps1) | AMD AMF 单文件压缩 |
| [encode-hevc-cpu-ffmpeg.ps1](./encode-hevc-cpu-ffmpeg.ps1) | CPU 单文件压缩 |
| [repair-zero-system-bitrate.ps1](./repair-zero-system-bitrate.ps1) | 修复 Windows 码率为 0 的元数据 |
| [build/package-scripts.ps1](./build/package-scripts.ps1) | 打包脚本 |

---

## Usage Notes

- 任务目录默认按 `estimatedSavedBytes` 从高到低排序
- 批量脚本每次只处理前 `N` 个 `pending` 文件
- 原位替换只会在输出文件校验通过后执行
- 当前仓库主流程只维护 FFmpeg 方案
- 如果你先做验证，建议从 `Count 1` 开始

---

## Single-File Scripts

四个单文件编码脚本统一支持：

- `-InputPath`
- `-OutputPath`
- `-VideoBitrateKbps`
- `-AudioBitrateKbps`
- `-AudioSampleRate`
- `-AudioCodec`
- `-ReplaceOriginal`
- `-KeepBackup`

如何选择：

- `encode-hevc-qsv-ffmpeg.ps1`：Intel 核显或 Intel 媒体单元可用时
- `encode-hevc-nvenc-ffmpeg.ps1`：NVIDIA 编码器可用时
- `encode-hevc-amf-ffmpeg.ps1`：AMD 编码器可用时
- `encode-hevc-cpu-ffmpeg.ps1`：没有可用硬件编码器时

---

## Practical Advice

- 先用 `Count 1` 做验证
- 确认效果后，再逐步放大到 `Count 3`、`Count 5`
- 如果浏览器或播放器已经占用某块显卡，尽量不要再让同一块显卡同时承担编码
