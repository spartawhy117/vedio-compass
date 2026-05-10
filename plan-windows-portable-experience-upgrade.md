# Video Compass Windows 便携式体验改造计划

## 1. 计划定位

这不是项目架构白皮书，而是一份 **驱动后续改造执行的单文件 harness 计划**。  
它的职责是约束目标、边界、实施顺序、验证方式和中断恢复策略，避免后续实现跑偏。

## 2. 任务目标

### 2.1 总目标

把当前“分散运行多个 PowerShell 脚本”的工具，改造成一个 **Windows 单目录、解压即用、单入口管理** 的视频库压缩工具。

用户解压 zip 后，应能在当前目录完成：

- 启动统一入口
- 新建扫描任务
- 继续已有任务
- 查看任务摘要
- 执行清理和恢复
- 做环境检查

### 2.2 成功标准

- 根目录只保留用户会直接接触的入口和 `tasks/`
- 用户双击 `start.cmd` 即可进入统一入口
- 统一入口覆盖扫描、压缩、任务管理、清理、环境检查
- 现有 `task.json`、`summary.txt`、`history.log` 保持兼容
- 中途关闭 PowerShell 脚本后，压缩进程不会持续失控运行

### 2.3 非目标

- 不做跨平台支持
- 不做重型全屏 TUI 框架重写
- 不重写 FFmpeg 编码核心逻辑
- 不改动现有任务文件格式
- 不引入 `config/`、`logs/` 目录
- 不把 `e2e/` 放入最终 release 发包目录

## 3. 固定约束

### 3.1 平台约束

- 仅支持 Windows
- 继续使用 PowerShell 作为运行时
- 继续依赖 `ffmpeg` / `ffprobe`

### 3.2 体验约束

- 用户只认一个入口
- 菜单优先于命令记忆
- 先解决流程断裂，再考虑界面花哨
- 首页采用普通 PowerShell 菜单式交互，不做首版全屏 TUI
- 长时间任务必须切换到独立执行视图，不与主菜单共享同一套控制台输出

### 3.3 兼容约束

- `tasks/` 继续作为唯一任务数据目录
- 原有任务状态、恢复逻辑、临时文件清理逻辑必须保留
- 单文件编码脚本仍然作为内部命令存在

## 4. 目标结构

### 4.1 仓库内结构

```text
video-compass/
  start.cmd
  video-compass.ps1
  tasks/
  app/
    core/
      video-compass-common.ps1
    commands/
      analyze-video-bitrate.ps1
      compress-from-task.ps1
      repair-zero-system-bitrate.ps1
      check-video-compass-env.ps1
      invoke-encode-worker.ps1
      encode-hevc-qsv-ffmpeg.ps1
      encode-hevc-nvenc-ffmpeg.ps1
      encode-hevc-amf-ffmpeg.ps1
      encode-hevc-cpu-ffmpeg.ps1
    runtime/
      invoke-execution-session.ps1
      invoke-watchdog.ps1
  e2e/
    README.md
  README.md
```

### 4.2 最终 release 发包结构

```text
video-compass/
  start.cmd
  video-compass.ps1
  tasks/
  app/
  README.md
```

release 发包 **明确排除**：

- `e2e/`
- 开发阶段临时测试资产
- 仅供内部验证的辅助脚本

## 5. 统一入口方案

### 5.1 交互模型

统一入口采用两段式交互：

1. 菜单阶段
2. 执行阶段

菜单阶段负责：

- 展示主菜单
- 收集参数
- 列出任务
- 选择清理动作

执行阶段负责：

- 扫描
- 批量压缩
- 单文件压缩
- 修复元数据
- 环境检查

一旦进入执行阶段，统一入口应启动独立子 PowerShell 进程承载本次操作。任务结束后再返回菜单。

### 5.2 首版菜单范围

1. 开始新任务
2. 管理已有任务
3. 清理与恢复
4. 环境检查
5. 退出

“管理已有任务”至少支持：

- 查看摘要
- 继续压缩
- 重置 `processing` 为 `pending`
- 清理并行状态文件
- 清理 `.codex-temp-*`
- 删除任务目录

## 6. 进程治理方案

### 6.1 现有问题

当前实测结果已经确认：

- 强制结束承载压缩的父 `pwsh`
- `ffmpeg` 仍会持续存活至少 20 秒

这说明不能只依赖“父脚本退出后子进程自然结束”的假设。

### 6.2 目标行为

无论以下哪种情况发生：

- 用户直接关闭 PowerShell 窗口
- 用户强制结束 `pwsh` / `powershell`
- 执行脚本异常退出

都要尽量做到：

- 停止对应 `ffmpeg`
- 删除临时输出
- 让任务状态可恢复

### 6.3 实施方案

采用四层治理：

1. **菜单进程**
   只负责调度，不直接运行长任务。

2. **执行子进程**
   专门运行扫描、压缩、修复等任务。

3. **主动 watchdog**
   独立 sidecar 进程，监听执行子进程和 `ffmpeg`。  
   如果执行子进程消失但 `ffmpeg` 仍存活，watchdog 立即：
   - 杀掉对应 `ffmpeg`
   - 删除临时输出
   - 写入中断标记或恢复线索

4. **启动时恢复**
   作为最终兜底，统一入口启动时：
   - 回收遗留 `ffmpeg` / worker
   - 重置 `processing`
   - 清理遗留状态文件和临时文件

### 6.4 设计原则

- 不把“下次启动再清理”当成主方案，只当兜底
- 不把单纯的 PowerShell `try/finally` 当成可靠退出机制
- 每次修改进程治理逻辑后，都必须重新做强杀父进程实验

## 7. 实施步骤

## Phase 1: 方案冻结

### Objective

冻结本轮范围，只做 Windows 单入口体验升级，不做跨平台和重写核心。

### Tasks

- 冻结最终目录结构
- 冻结菜单阶段与执行阶段分离模型
- 冻结 watchdog 进程治理方案
- 冻结 release 发包排除规则

### Exit Criteria

- 已确认最终目录结构
- 已确认统一入口产品形态
- 已确认 `watchdog` 是必选方案，不再只依赖父子进程自然退出

## Phase 2: 目录重组

### Objective

把项目从“根目录脚本集合”整理成“可被统一入口调度的应用结构”。

### Tasks

- 新增 `app/core`
- 新增 `app/commands`
- 新增 `app/runtime`
- 迁移现有脚本到对应目录
- 修正所有相对路径和公共模块引用
- 保证现有命令在新结构下仍可独立运行

### Exit Criteria

- 根目录只保留入口、`tasks/`、`README.md`
- 功能脚本全部完成下沉
- 路径引用验证通过

## Phase 3: 单入口落地

### Objective

实现 `start.cmd` 和 `video-compass.ps1`，让用户只通过一个入口使用工具。

### Tasks

- 新增 `start.cmd`
- 新增 `video-compass.ps1`
- 实现主菜单
- 实现新任务向导
- 实现任务列表和摘要展示
- 实现清理与恢复入口

### Exit Criteria

- 双击 `start.cmd` 可进入统一菜单
- 用户无需直接点任何内部 `.ps1`

## Phase 4: 执行子进程与 watchdog

### Objective

把长任务执行从菜单会话里剥离，并解决关闭脚本后 `ffmpeg` 残留问题。

### Tasks

- 新增 `app/runtime/invoke-execution-session.ps1`
- 新增 `app/runtime/invoke-watchdog.ps1`
- 让扫描、压缩、修复都通过执行子进程运行
- 为压缩执行链传递 worker PID、`ffmpeg` PID、临时输出路径、任务标识
- watchdog 实现父进程消失后的主动回收
- 保留启动时恢复作为兜底

### Exit Criteria

- 强制关闭执行子进程后，对应 `ffmpeg` 能被主动回收
- 中断后任务仍可恢复

### 实施子步骤

1. 先实现执行子进程入口，只负责承接菜单层参数并运行目标命令。
2. 在压缩链路内把 `ffmpeg` PID、临时输出路径、任务标识写入 watchdog 可消费的上下文。
3. 实现独立 watchdog 轮询父执行进程状态。
4. 当父执行进程消失且 `ffmpeg` 仍存活时，watchdog 主动杀进程并清理临时输出。
5. 为被 watchdog 中断的任务写入恢复线索，让下次启动能完成状态回滚。
6. 用 E2E 强杀实验回归验证该链路。

### 运行时接口约定

执行子进程至少要向 watchdog 提供：

- `ExecutionPid`
- `FfmpegPid`
- `TaskFolder`
- `TaskItemPath` 或唯一任务项标识
- `TemporaryOutputPath`
- `ProgressFilePath` / `ResultFilePath`（如适用）

watchdog 至少要输出：

- 是否检测到父进程消失
- 是否成功回收 `ffmpeg`
- 是否成功删除临时输出
- 是否写入中断标记

## Phase 5: 控制台体验收敛

### Objective

解决多次执行后进度条和固定文本重复污染的问题。

### Tasks

- 菜单与执行会话彻底分离
- 执行前清屏
- 执行结束后显示摘要并等待返回
- 返回菜单前重新整理控制台状态
- 避免菜单层和底层脚本混写同一轮输出

### Exit Criteria

- 多次执行后控制台仍可读
- 不再出现明显的进度条残留污染

## Phase 6: 任务管理与恢复

### Objective

把历史任务管理、清理和恢复做成统一入口的一等能力。

### Tasks

- 枚举 `tasks/*/task.json`
- 展示任务状态与摘要
- 实现继续压缩
- 实现重置 `processing` / `failed`
- 实现并行状态文件清理
- 实现遗留 `ffmpeg` / worker 回收
- 实现任务目录删除确认流程

### Exit Criteria

- 用户能在当前目录管理历史任务
- 清理动作可从统一入口完成

## Phase 7: 文档、验证与发包

### Objective

完成文档更新、E2E 验证和最终发包约束。

### Tasks

- 更新 README
- 明确 zip 使用方式
- 明确升级覆盖方式
- 明确 release 发包排除 `e2e/`
- 补齐 E2E 验证说明

### Exit Criteria

- README 与新入口一致
- E2E 验证范围明确
- release 发包内容明确

## 8. E2E 验证目录

仓库内新增 `e2e/`，用于保存开发期端到端验证说明和脚本。  
该目录不属于最终用户发包目录。

### 8.1 当前计划中的 E2E 重点

- `强杀父 PowerShell 后 ffmpeg 是否残留`
- `watchdog 是否能主动回收 ffmpeg`
- `压缩中断后 task 状态是否可恢复`
- `多次进入压缩后控制台是否出现明显进度污染`
- `统一入口是否能列出并继续已有任务`

### 8.2 E2E 目录约定

```text
e2e/
  README.md
  fixtures/
    reset-test-workspace.ps1
  scripts/
    test-watchdog-kill.ps1
    test-task-recovery.ps1
    test-repeated-execution.ps1
```

说明：

- `fixtures/reset-test-workspace.ps1` 用于清空并重建测试目录，供自动化和手动测试共用
- `scripts/` 中的脚本负责执行单项 E2E 场景
- 所有 E2E 脚本应默认在仓库内临时测试目录运行，不污染真实 `tasks/`

### 8.3 E2E 通过标准

- 测试脚本可以一键重置测试目录
- 手动测试者可以先运行重置脚本，再执行单项场景
- 自动化执行时不依赖人工输入
- 每个 E2E 脚本至少输出明确的通过/失败结论

## 9. 风险与缓解

### R1 路径迁移风险

- 风险: 目录重构后 `$PSScriptRoot` 和内部引用失效
- 缓解: 先完成根目录解析统一，再迁移脚本

### R2 输出污染风险

- 风险: 菜单层和执行层共用会话时输出混乱
- 缓解: 菜单与执行分会话；执行层独占控制台

### R3 孤儿 ffmpeg 风险

- 风险: 父脚本退出后 `ffmpeg` 继续运行
- 缓解: watchdog 主动回收 + 启动时兜底恢复

### R4 清理误删风险

- 风险: 清理逻辑误删有效文件
- 缓解: 仅按明确命名规则处理，并增加确认步骤

### R5 错误依赖单一退出机制

- 风险: 过度相信 Job Object 或 PowerShell hook
- 缓解: 以实测为准，保留多层治理

## 10. 决策记录

### 已确认

- 当前版本只做 Windows
- 当前版本不做跨平台
- 当前版本首页采用普通 PowerShell 菜单，不做全屏 TUI
- 当前版本保留 PowerShell 后端
- 当前版本采用“单入口 + 菜单式向导”方案
- 当前版本长任务通过独立执行子进程运行
- 当前版本必须增加主动 watchdog
- 当前版本根目录保留入口与 `tasks/`
- 功能脚本下沉到 `app/`
- 当前版本不引入 `config/` 和 `logs/`
- 当前版本不保留 `build/`
- `e2e/` 仅用于开发验证，不进入最终 release

### 待确认

- `video-compass.ps1` 是否保留命令行参数模式
- 首版是否开放“删除任务目录”
- watchdog 是否复用 PowerShell 实现，还是改用更轻量的宿主

## 11. 进度账本

### Current Phase

Phase 1

### Last Completed

- 方向已从跨平台收敛到 Windows 便携式体验升级
- 已确认首页不做全屏 TUI
- 已确认最终目录不保留 `build/`
- 已完成“强杀父 `pwsh` 后 `ffmpeg` 是否残留”的实测
- 已确认仅靠当前第二层方案不够，需要主动 watchdog

### Next Action

开始按新结构重组目录，并为 `e2e/` 建立验证说明与后续脚本入口。

## 12. 完成定义

### 功能完成

- 扫描、压缩、恢复、清理、环境检查都可从统一入口触发

### 体验完成

- 用户不需要手动点不同脚本
- 用户能在当前项目目录管理历史任务
- 多次执行后控制台仍可读

### 稳定性完成

- 关闭 PowerShell 压缩脚本后，对应 `ffmpeg` 不会持续失控运行
- 中断后任务可恢复

### 发包完成

- 项目可直接打包为 zip
- 用户解压后可通过 `start.cmd` 直接使用
- `e2e/` 不进入最终 release
