# Video Compass E2E 验证目录

该目录用于保存开发期端到端验证说明、实验脚本和回归记录。

## 作用

- 验证统一入口主流程
- 验证强杀 PowerShell 后 `ffmpeg` 的回收行为
- 验证 watchdog 是否生效
- 验证任务恢复与清理
- 验证控制台输出是否重复污染

## 约束

- `e2e/` 仅用于开发和回归
- `e2e/` 不进入最终 release 发包目录
- 临时样本和实验脚本应尽量限制在该目录或临时目录内

## 首批 E2E 用例

1. 新建扫描任务并生成 `task.json`
2. 从统一入口继续已有任务
3. 压缩进行中强杀执行子进程，确认 `ffmpeg` 被回收
4. 强杀后重新启动，确认任务恢复逻辑正确
5. 连续多次执行压缩，确认控制台输出不持续累积污染

## 目录约定

```text
e2e/
  README.md
  fixtures/
    reset-test-workspace.ps1
  scripts/
    run-all.ps1
    test-watchdog-kill.ps1
    test-task-recovery.ps1
    test-repeated-execution.ps1
```

## 重置脚本要求

`fixtures/reset-test-workspace.ps1` 必须满足：

- 可重复执行
- 会清空并重建专用测试目录
- 会清理测试期间残留的 `ffmpeg` / `pwsh` / 临时文件
- 既能被自动化调用，也能被手动测试者单独运行

## 用例通过标准

- 每个脚本输出明确的 `PASS` / `FAIL`
- 测试失败时输出失败原因
- 所有脚本默认使用专用测试目录，不直接污染真实 `tasks/`
