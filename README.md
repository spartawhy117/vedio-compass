# Video Compass

Windows 下的视频扫描与批量压缩 PowerShell 工具。主流程基于 FFmpeg，支持 `qsv / nvenc / amf / cpu` 四种编码路径。

文档中的示例路径统一用 `xxxx` 表示占位目录，使用时请替换成你自己的实际路径。

## 编码路径与硬件要求

- `qsv`
  适合带 Intel 核显或 Intel 媒体引擎的机器。要求驱动正常、FFmpeg 构建包含 QSV 编码支持。
- `nvenc`
  适合带 NVIDIA 独显且驱动正常的机器。要求显卡本身提供 NVENC 硬件编码单元。
- `amf`
  适合带 AMD 独显，或带 AMD 核显的 APU 机器。要求驱动正常、FFmpeg 构建包含 AMF 编码支持。
- `cpu`
  不依赖硬件编码器，只要 CPU 能跑 FFmpeg 即可。兼容性最高，但通常也是最慢的一条路径。

如果你希望压缩时尽量不影响浏览器，通常优先选择不和浏览器当前渲染显卡冲突的编码路径。

## 适用场景

适合以下情况：

- 你有一批视频文件，想先筛出码率偏高的文件，再分批压缩。
- 你不想每次都重新扫描目录，希望扫描一次后反复接着压缩。
- 你希望每次只处理少量文件，例如一次压 1 部、3 部、5 部。
- 你希望在 `qsv / nvenc / amf / cpu` 之间按机器环境选择编码方式。
- 你希望压缩成功后直接替换原文件，或者保留备份。
- 你需要顺手修复 Windows 资源管理器里“码率为 0”的视频元数据。

不适合的情况：

- 你只想临时压一个文件，不关心任务目录和批处理。
这种情况直接使用单文件编码脚本更简单。
- 你的机器没有 `ffmpeg` 和 `ffprobe`。
这种情况需要先准备依赖。

## 依赖

- PowerShell 5.1 或 PowerShell 7+
- `ffmpeg.exe`
- `ffprobe.exe`

脚本会优先从 `PATH` 查找 `ffmpeg.exe` 和 `ffprobe.exe`。

首次使用前，建议先执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\check-video-compass-env.ps1
```

如果缺少 FFmpeg，可执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\check-video-compass-env.ps1 -InstallFfmpeg
```

## 核心脚本

- [analyze-video-bitrate.ps1](./analyze-video-bitrate.ps1)
  - 扫描目录，生成任务目录
- [compress-from-task.ps1](./compress-from-task.ps1)
  - 从任务目录中按顺序压缩前 `N` 个 `pending` 文件
- [encode-hevc-qsv-ffmpeg.ps1](./encode-hevc-qsv-ffmpeg.ps1)
- [encode-hevc-nvenc-ffmpeg.ps1](./encode-hevc-nvenc-ffmpeg.ps1)
- [encode-hevc-amf-ffmpeg.ps1](./encode-hevc-amf-ffmpeg.ps1)
- [encode-hevc-cpu-ffmpeg.ps1](./encode-hevc-cpu-ffmpeg.ps1)
  - 四个单文件编码脚本，可单独使用
- [repair-zero-system-bitrate.ps1](./repair-zero-system-bitrate.ps1)
  - 修复 Windows 资源管理器里码率为 0 的文件元数据
- [build/package-scripts.ps1](./build/package-scripts.ps1)
  - 打包脚本

## 使用步骤

推荐按下面顺序使用。

### 1. 扫描目录

目的：

- 找出高于阈值码率的视频。
- 生成后续批量压缩要使用的任务目录。

执行命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\analyze-video-bitrate.ps1 `
  -RootPath 'xxxx\source-folder' `
  -ThresholdKbps 4500 `
  -TargetKbps 3500
```

如果不带参数运行，脚本会依次询问：

- 扫描目录
- 扫描阈值码率
- 目标压缩码率

说明：

- 现在不再内置默认扫描目录。
- 不同用户首次使用时，需要自己输入实际要扫描的目录。

执行完成后会生成一个任务目录，例如：

```text
tasks/<目录名>__scan-4500__target-3500/
  task.json
  summary.txt
  history.log
```

这三个文件的作用：

- `task.json`：任务状态源
- `summary.txt`：摘要
- `history.log`：处理历史

建议：

- `ThresholdKbps` 用来决定“哪些视频需要进入任务”。
- `TargetKbps` 用来决定“进入任务后要压到多少码率”。
- 如果你第一次只是想保守测试，可以先从 `4500 -> 3500` 这类差值不太大的方案开始。

当前进度显示：

- 扫描阶段有 PowerShell 进度条。
- 会显示当前扫描到第几个文件，以及整体百分比。
- 当前不显示扫描剩余预计时间。

### 2. 按任务批量压缩

目的：

- 不重新扫描，直接从现有任务里取出前 `N` 个待处理文件。
- 可以一次只处理少量文件，避免长时间占满机器。

执行命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\compress-from-task.ps1 `
  -TaskFolder 'xxxx\tasks\source-folder__scan-4500__target-3500' `
  -Count 1 `
  -Encoder qsv `
  -ReplaceOriginalMode yes `
  -KeepBackupMode no
```

如果不带参数运行，脚本会依次询问：

- 任务目录
- 本次处理数量
- 编码器：`qsv` / `nvenc` / `amf` / `cpu`
- 是否替换原文件
- 是否保留备份

参数怎么理解：

- `TaskFolder`：上一步生成的任务目录。
- `Count`：这次要处理多少个视频。
- `Encoder`：选择使用哪条编码路径。
- `ReplaceOriginalMode yes`：压缩成功后替换原文件。
- `KeepBackupMode no`：替换后不保留备份。

数量规则：

- 不带 `-Count` 时，默认值会显示为当前 `task.json` 中剩余的待处理总数。
- 如果输入数量大于剩余待处理总数，脚本会自动按剩余待处理总数执行。
- 压缩过程中如果用户正常关闭脚本，脚本会尽力停止当前 ffmpeg、删除当前临时输出，并把当前项目写回 `pending`。
- 中断时会在 `history.log` 追加一条 `interrupted` 记录，便于后续排查。
- 如果是强杀进程、断电这类极端中断，Windows 不一定会给脚本回调时间，仍由下次启动时的恢复逻辑清理遗留 temp 并重置状态。

处理完成后会自动更新：

- `task.json`
- `summary.txt`
- `history.log`

当前进度显示：

- 批量脚本会显示当前文件进度条。
- 批量脚本会显示本轮总进度条。
- 批量脚本会根据当前编码速度，实时估算本轮剩余时间。
- 当前总进度按“本轮待处理文件的总时长”计算，不是按文件数量平均。
- 每个文件完成后，脚本会输出：
  - 本次完成数量
  - 剩余待处理数量

中断恢复行为：

- 如果用户上次在压缩中途直接关闭窗口、按 `Ctrl+C`，或 PowerShell 正常退出，脚本会尽力：
  - 停掉当前 `ffmpeg`
  - 删除当前 `.codex-temp-*` 临时输出
  - 把当前项目立即写回 `pending`
  - 在 `history.log` 中追加 `interrupted` 记录
- 如果用户上次是强杀进程、直接结束终端树、断电，脚本当时未必来得及回写状态。
- 下次启动 [compress-from-task.ps1](./compress-from-task.ps1) 时，脚本会自动检查所有未完成项目。
- 检测到残留状态后，会默认：
  - 把 `processing` 项重置回 `pending`
  - 清理同目录下遗留的 `.codex-temp-*` 临时文件
  - 然后从头开始重新压缩该文件
- 不需要用户手动改 `task.json`。

常见用法：

- 先用 `Count 1` 做验证。
- 确认效果可以接受后，再逐步放大到 `Count 3`、`Count 5`。
- 如果你浏览器或其他程序已经占用某块显卡，批处理时就尽量不要再让同一块显卡同时承担编码。

### 3. 单文件压缩

适用情况：

- 你只想临时压一个文件。
- 你不需要任务目录、批处理、历史状态。

示例命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\encode-hevc-nvenc-ffmpeg.ps1 `
  -InputPath 'xxxx\demo.mp4' `
  -VideoBitrateKbps 3500 `
  -ReplaceOriginal
```

四个编码脚本统一支持：

- `-InputPath`
- `-OutputPath`
- `-VideoBitrateKbps`
- `-AudioBitrateKbps`
- `-AudioSampleRate`
- `-ReplaceOriginal`
- `-KeepBackup`

如何选择：

- `encode-hevc-qsv-ffmpeg.ps1`：Intel 核显或 Intel 媒体单元可用时。
- `encode-hevc-nvenc-ffmpeg.ps1`：NVIDIA 编码器可用时。
- `encode-hevc-amf-ffmpeg.ps1`：AMD 编码器可用时。
- `encode-hevc-cpu-ffmpeg.ps1`：没有可用硬件编码器时。

### 4. 修复码率为 0 的元数据

适用情况：

- 文件本身能播放，但 Windows 资源管理器里显示码率为 `0`。

执行命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\repair-zero-system-bitrate.ps1 `
  -RootPath 'xxxx\source-folder'
```

当前主要对 `.mp4 / .mov / .m4v` 的 Windows 码率元数据修复更可靠。

## 常用说明

- 任务目录按 `estimatedSavedBytes` 从高到低排序。
- 批量脚本每次只处理前 `N` 个 `pending` 文件。
- 原位替换只会在输出文件校验通过后执行。
- 当前仓库主路径只维护 FFmpeg 方案。
