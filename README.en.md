# Video Compass

[中文](./README.md) | [English](./README.en.md)

A Windows-first tool for scanning and batch-compressing video libraries.

After extracting the zip, run `start.cmd` and manage everything from the current folder:

- create scan tasks
- resume existing compression tasks
- clean interrupted leftovers
- run environment checks

## Highlights

- Single entry: no need to launch multiple `.ps1` files manually
- Task-based: scan results are stored under `tasks/`
- Recoverable: interrupted jobs can be resumed
- Multiple encoders: `qsv` / `nvenc` / `amf` / `cpu`

## Requirements

- Windows
- PowerShell 5.1 or PowerShell 7+
- `ffmpeg.exe`
- `ffprobe.exe`

The tool looks for `ffmpeg.exe` and `ffprobe.exe` in `PATH` first.

To verify your environment:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\app\commands\check-video-compass-env.ps1
```

## Quick Start

### 1. Launch

Double-click:

```text
start.cmd
```

Or run manually:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\video-compass.ps1
```

### 2. Choose an action

The main menu includes:

1. Start a new task
2. Manage existing tasks
3. Clean and recover
4. Environment check
5. Exit

### 3. Create a task

The scan flow asks for:

- source folder
- scan bitrate threshold
- target bitrate

After scanning, a task folder will be created, for example:

```text
tasks/<folder>__scan-4500__target-3500/
  task.json
  summary.txt
  history.log
```

### 4. Resume compression

From the task list, you can:

- view the summary
- resume pending items
- reset interrupted states
- clean temp files and parallel state files
- delete a task folder

## Interrupt Handling

Compression runs in a dedicated execution process with a watchdog.

If the script is closed during compression, the tool will try to:

- stop the related `ffmpeg`
- remove leftover temp output
- move the task back into a resumable state

On the next launch, it will also run recovery again for:

- `processing -> pending`
- leftover `.codex-temp-*`
- leftover `.parallel-progress-*` / `.parallel-result-*`
- leftover `ffmpeg` / worker processes

## Directory Layout

The main user-facing structure is:

```text
video-compass/
  start.cmd
  video-compass.ps1
  tasks/
  app/
  README.md
  README.en.md
```

Notes:

- `tasks/`: task data
- `app/`: internal scripts
- `app/core/`: shared logic
- `app/commands/`: feature commands
- `app/runtime/`: execution session and watchdog

## Task Files

Each task folder contains:

- `task.json`: task state
- `summary.txt`: task summary
- `history.log`: processing history

## Notes

- Windows only
- No cross-platform support promise for now
- `e2e/` is for development validation only and is not included in the final release package
