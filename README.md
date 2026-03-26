# Video Compass

用于在 Windows 上管理“先扫描高码率视频，再按批次压缩”的 PowerShell 工作流。

当前主流程统一由 FFmpeg 驱动，支持 `qsv / nvenc / amf / cpu` 四条编码路径。项目重点是把“扫描、落盘任务、分批执行、原位替换”拆成可恢复、可重复的步骤。

## 依赖

- Windows PowerShell 5.1 或 PowerShell 7+
- `ffmpeg.exe`
- `ffprobe.exe`

脚本会优先从 `PATH` 查找 `ffmpeg.exe` 和 `ffprobe.exe`，找不到时再尝试从脚本同目录读取。

## 主流程

### 1. 扫描目录

使用 [analyze-video-bitrate.ps1](./analyze-video-bitrate.ps1) 扫描目录，找出视频码率高于阈值的候选文件。

特点：

- 无参数时走交互模式。
- 有参数时可静默执行。
- 扫描结果写入 `tasks/<目录名>__scan-<阈值>__target-<目标>/`。
- 只把超过阈值的候选文件写入 `task.json`。
- 如果同名任务已存在，默认复用原任务状态。
- 加上 `-ResetTask` 可强制重建该任务。

当前扫描支持的扩展名：

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

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\analyze-video-bitrate.ps1 `
  -RootPath 'E:\entertament\hx\onlyfans' `
  -ThresholdKbps 4500 `
  -TargetKbps 3500
```

参数：

- `-RootPath`：扫描目录。
- `-ThresholdKbps`：扫描阈值码率，只有高于它的文件才进入任务。
- `-TargetKbps`：目标压缩视频码率。
- `-ResetTask`：重置同名任务目录中的任务状态。

输出结构：

```text
tasks/<source-folder-name>__scan-4500__target-3500/
  task.json
  summary.txt
  history.log
```

`task.json` 是唯一状态源，`summary.txt` 供人工查看，`history.log` 保存每次处理记录。

### 2. 按任务批量压缩

使用 [compress-from-task.ps1](./compress-from-task.ps1) 从任务目录中取出前 `N` 个 `pending` 文件压缩。

特点：

- 无参数时交互询问任务目录、处理数量、编码器、是否替换原文件、是否保留备份。
- 有参数时可直接自动执行。
- 每处理完一个文件就回写 `task.json`、`summary.txt`、`history.log`。
- 批处理只消费任务目录里当前顺序的前 `N` 个 `pending` 条目，不会重新排序。

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\compress-from-task.ps1 `
  -TaskFolder 'D:\study\Proj\vedio-compass\tasks\onlyfans__scan-4500__target-3500' `
  -Count 1 `
  -Encoder qsv `
  -ReplaceOriginalMode yes `
  -KeepBackupMode no
```

参数：

- `-TaskFolder`：任务目录路径。
- `-Count`：本次执行要处理的数量。
- `-Encoder`：`qsv`、`nvenc`、`amf`、`cpu`。
- `-ReplaceOriginalMode`：`yes` 或 `no`。
- `-KeepBackupMode`：`yes` 或 `no`。

## 单文件编码脚本

四个主编码脚本都复用 [video-compass-common.ps1](./video-compass-common.ps1) 中的统一编码工作流：

- [encode-hevc-qsv-ffmpeg.ps1](./encode-hevc-qsv-ffmpeg.ps1)
- [encode-hevc-nvenc-ffmpeg.ps1](./encode-hevc-nvenc-ffmpeg.ps1)
- [encode-hevc-amf-ffmpeg.ps1](./encode-hevc-amf-ffmpeg.ps1)
- [encode-hevc-cpu-ffmpeg.ps1](./encode-hevc-cpu-ffmpeg.ps1)

统一参数：

- `-InputPath`：输入文件。
- `-OutputPath`：输出文件，可省略。
- `-VideoBitrateKbps`：默认 `3500`。
- `-AudioBitrateKbps`：默认 `320`。
- `-AudioSampleRate`：默认 `48000`。
- `-ReplaceOriginal`：成功后原位替换。
- `-KeepBackup`：原位替换时保留备份。
- `-DurationToleranceSec`：默认 `2.0`。

统一行为：

- 音频统一转为 AAC。
- 默认输出文件名会自动加后缀：
  - `_ffmpeg_qsv`
  - `_ffmpeg_nvenc`
  - `_ffmpeg_amf`
  - `_ffmpeg_cpu`
- 当输入扩展名不是 `.mp4/.m4v/.mov/.mkv` 时，默认输出回退为 `.mp4`。
- `-ReplaceOriginal` 只支持 `.mp4/.m4v/.mov/.mkv` 输入。
- 原位替换时会先输出到临时文件，校验成功后再替换原文件。

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\encode-hevc-nvenc-ffmpeg.ps1 `
  -InputPath 'E:\videos\demo.mp4' `
  -VideoBitrateKbps 3500 `
  -ReplaceOriginal `
  -KeepBackup
```

各编码器对应的实际 FFmpeg 视频参数：

- `qsv`：`hevc_qsv` + `-preset:v veryfast` + `-look_ahead 0` + `-low_power 1`
- `nvenc`：`hevc_nvenc` + `-rc:v vbr` + `-preset:v p5`
- `amf`：`hevc_amf` + `-rc:v vbr_peak` + `-quality speed`
- `cpu`：`libx265` + `-preset fast`

## 元数据修复脚本

[repair-zero-system-bitrate.ps1](./repair-zero-system-bitrate.ps1) 用于修复 Windows 资源管理器里 `System.Video.TotalBitrate` 为 `0` 的文件。

特点：

- 扫描目录下常见视频文件。
- 优先检查 Windows Shell 的系统码率字段。
- 对可修复的容器执行无损 remux。
- 默认原位修复，不保留备份。

当前修复行为：

- 可扫描：`.mp4/.mov/.m4v/.mkv/.webm/.avi/.wmv`
- 实际可自动回填的容器：`.mp4/.mov/.m4v`
- `.mkv` 等其他容器会被列为 unsupported，而不是强行回写

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\repair-zero-system-bitrate.ps1 `
  -RootPath 'E:\entertament\hx\onlyfans'
```

参数：

- `-RootPath`：待扫描目录。
- `-KeepBackup`：修复时保留原文件备份。

## 任务目录说明

任务目录命名会带上扫描阈值和目标压缩码率，例如：

```text
tasks\onlyfans__scan-4500__target-3500
```

这样做的好处：

- 一眼能看出当前任务采用的码率策略。
- 后续压缩只需要指定任务目录，不需要重复输入长参数。
- 任务可以中断后续跑。

`task.json` 中每个候选项会保留：

- 原路径
- 估算视频码率
- 音频码率
- 时长
- 原文件大小
- 预估可节省空间
- 当前状态
- 最近一次执行时间
- 最近一次执行结果
- 是否已替换原文件

状态值：

- `pending`
- `processing`
- `done`
- `failed`
- `skipped`

## 打包脚本

[package-scripts.ps1](./build/package-scripts.ps1) 会把项目根目录下的 `.ps1` 脚本打包成 zip，默认输出固定文件：

- `build\vedio-compass-scripts.zip`

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\build\package-scripts.ps1
```

如果要把 `README.md` 一起打包：

```powershell
powershell -ExecutionPolicy Bypass -File .\build\package-scripts.ps1 -IncludeDocs
```

参数：

- `-OutputZipPath`：自定义输出 zip 路径。
- `-IncludeDocs`：额外打包 `README.md`。

## 兼容性说明

- 批处理主路径统一由 FFmpeg 驱动。
- 当前仓库只维护 `qsv / nvenc / amf / cpu` 四条 FFmpeg 编码路径。

## 已验证样例

当前已对目录 `E:\entertament\hx\onlyfans` 完成一次任务流验证：

- 扫描阈值：`4500 kbps`
- 目标压缩：`3500 kbps`
- 替换原文件：`yes`
- 保留备份：`no`
- 已实测执行 `qsv` 1 部、`nvenc` 1 部

这部分验证主要用于确认：

- 扫描能正确生成任务目录。
- 批量脚本能正确读取任务并消费 `pending` 项。
- 原位替换流程可用。
- `task.json`、`summary.txt`、`history.log` 会按执行结果更新。
