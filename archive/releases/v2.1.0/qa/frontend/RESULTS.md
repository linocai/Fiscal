# V2.1.0 build 39 · 前端施工与本地验收

2026-09-05，Asia/Shanghai。状态：**实现与本地验证完成，未提交、未发布、未替换正式 App**。当前计划仍以仓库根 `PROJECT_PLAN.md` 为准。

2026-09-06 补充：独立审查发现的两项交互问题已修复，405 项单测、相关 UI 回归与最终双端构建通过，详见 [审查与修复记录](REVIEW.md)。最新源码指纹见 [review-fix-source-manifest.json](review-fix-source-manifest.json)；以下保留 09-05 首次验收事实与边界。

## 实现范围

- 从图标明黄与深青建立品牌色、浅深色阅读表面和独立财务状态色；黄色承载品牌与创建动作，预计、待确认、结果未知和危险使用各自语义。
- iOS 记一笔采用金额优先的轻量录入，类型、账户和分类紧凑选择，备注按需展开；保留系统输入、动态字体与粘贴能力。正常字体、真实软件键盘开启时，日期与保存操作均完整可见。
- iOS 今日减少嵌套容器；账目使用日期分组、平面流水与对齐金额。沿用今日/账目两 Tab 和中央创建动作。
- Mac 时间线增加双行流水与稳定金额列，无选择时让出检查器宽度，选择后恢复详情；分析取消空白右列。Mac 录入限制阅读宽度并突出金额。
- 信用、现金流、分期、报销、导入、AI 复核、数据安全、治理及共享反馈继承新组件；修改涉及视图、设计系统、版本和 QA。没有更改后端、领域模型、金额算法、API 或迁移。

## 自动验证

| 验证 | 结果 |
| --- | --- |
| FiscalKitTests | 两轮完整回归均 405 tests / 39 suites 通过；最近一次 46.888 秒 |
| 正式 FiscaliOS App | 最终 Debug / arm64 / generic iOS Simulator 构建通过 |
| 正式 FiscalmacOS App | 最终 Debug / arm64 / macOS 构建通过 |
| iOS F1A 录入 UI | 7/7 通过：初始中性校验、真实软件键盘、普通保存、五种类型、深色/AX5、还款预览确认、AX5 还款可达性 |
| iOS 正式根 UI | 6/6 通过：冷启动、录入返回、长金额、浅深色/AX5、账目范围/账户/未来/现金流返回、治理入口；最终日期与颜色修正后相关 2 项复测通过 |
| Mac 正式根 UI | 冷启动和选择→分析→返回 2/2 通过；增加 Cmd-N、金额输入和录入返回断言后复测通过 |
| Mac 分析 UI | 四种分析视角与安全下钻测试通过 |
| 版本与工程 | 双端生成 App 的版本均为 2.1.0 / 39；最低系统均 26.0；6 个用户 scheme 与施工前逐字节一致；git diff --check 通过 |

共 16 项不同 UI 用例，不将重复运行计为新增覆盖。原始执行摘要见 [verification.log](verification.log)，源码 SHA-256 见 [source-manifest.json](source-manifest.json)，受保护 scheme 哈希见 [protected-schemes.json](protected-schemes.json)。

## 视觉与交互证据

使用真实 SwiftUI View、正式 workspace 和隔离的合成数据；没有另写演示 UI。

- [iOS 记一笔 + 软件键盘](screenshots/v210-ios-record-keyboard.png)、[深色录入](screenshots/v210-ios-record-dark.png)、[还款预览前](screenshots/v210-ios-repayment-preview-ready.png)。
- [iOS 今日](screenshots/v210-ios-today-light.png)、[深色今日](screenshots/v210-ios-today-dark.png)、[账目](screenshots/v210-ios-ledger-light.png)、[超长金额](screenshots/v210-ios-long-amount.png)、[最大动态字体滚动状态](screenshots/v210-ios-today-ax5.png)。
- [Mac 时间线](screenshots/v210-mac-timeline-light.png)、[深色时间线](screenshots/v210-mac-timeline-dark.png)、[1000 pt 窄窗口](screenshots/v210-mac-timeline-compact.png)、[选中交易](screenshots/v210-mac-timeline-selected.png)。
- [Mac 分析](screenshots/v210-mac-analysis-light.png)、[深色分析](screenshots/v210-mac-analysis-dark.png)、[正式工作区录入](screenshots/v210-mac-formal-record.png)。

人工检查覆盖上述核心页面。收口中修复了日期挤压、正式导航栏下日期被遮挡、账期 AX value 缺失、深色输入提示与黄色按钮图标对比不足。AX5 还款测试原先整屏/整 ScrollView 手势落入固定按钮或键盘，现按实际可见内容范围滑动，保留全部可达断言，最终通过。正式 Mac fixture 补齐已有合成未来事项和选中交易详情读取，避免把 fixture 缺失当成产品错误。

## 验证边界

本轮没有连接生产服务、进行真实后端写入或实体 iPhone 安装；保存/还款由隔离 fixture 和既有领域回归验证。iPhone 17 Pro / iOS 26.5 作为 iPhone 16+ 的代表设备，未逐型号测试；专项页面以共享组件迁移、状态语义和已有单测覆盖为主，没有穷举每个业务状态截图。没有执行独立 Reviewer 审查，也未做发布签名与部署验收。

## 资源与环境

- 全程仅复用 `ICTW-v170-iPhone17Pro`，UUID `211DD03C-812D-4A42-97EF-F693D7DF924C`。没有新建/克隆模拟器或下载 runtime；原 iPhone 13 未使用。结束后两个既有设备均 Shutdown。
- 为实际显示软件键盘，测试时暂时断开硬件键盘；结束后 `ConnectHardwareKeyboard` 已恢复为原值 1。
- 复用既有 Fiscal DerivedData，构建串行、2 jobs、关闭 parallel testing。后续显式 Debug / arm64，`MODULE_CACHE_DIR` 与 `CLANG_MODULE_CACHE_PATH` 均指向既有共享缓存。
- 清理本任务新建的重复 ModuleCache、原始结果包和重复导出约 530 MB；保留日志与 scheme 原始备份。既有 Release 中间目录创建于前一天，未删除；未清理其他项目缓存。
- 收口约数：Fiscal DerivedData **1.8G → 2.0G**；共享 ModuleCache **1.9G → 2.0G**；总 DerivedData **4.4G → 4.8G**；CoreSimulator **9.2G → 8.9G**。文件系统剩余约 **28 GiB**，不把系统全盘变化全部归因于本任务。
- 仓库验收证据约 **3.9 MB**。原始日志和 scheme 备份保留在 `/var/folders/_v/s6hfcbrj5v3fyxk8jzwh7ft00000gn/T/fiscal-v210-s2uwky1l`（约 3.3 MB）；大结果包已删除，复现应使用下述配置。

## 复现入口

工程：`App/Fiscal.xcodeproj`。沿用 scheme `FiscalmacOS`、`FiscaliOS`、`V15GalleryiOS`、`V15RootSmokeiOS`、`V15RootSmokemacOS`、`V15GallerymacOS`。UI 仅运行上表的指定用例；iOS 根测试的两个 localhost 服务用例没有在本轮运行，不应在未启动隔离 QA 后端时运行。

Mac 小范围截图使用 `V15GallerySnapshotTool`，环境 `FISCAL_V15_SNAPSHOT_SCOPE=v210`，输出目录由 `FISCAL_V15_GALLERY_SCREENSHOT_DIR` 指定；运行工具时 `DYLD_FRAMEWORK_PATH` 指向已有 `Build/Products/Debug`。只渲染 6 个指定场景，可用 `FISCAL_V210_SNAPSHOT_SCENE` 限定单场景。iOS 键盘测试运行前须在这台既有模拟器显示软件键盘，测试后恢复原设置。
