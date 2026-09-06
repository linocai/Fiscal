# V2.2.0（40）Review 核验记录

2026-09-06，Asia/Shanghai。审查基线为已发布实现 `353c381`，当前 HEAD `96d2f9a`，目标源码仍在 main 工作区。主报告见同目录 `REVIEW.md`；本文件只记录证据与局限。

## 源码与已有结果核验

- 本轮审查文件指纹见 `review-source-manifest.json`：51 个 App 改动文件，含新增 Swift 文件，排除六个受保护 scheme。
- 六个 scheme 与施工前 `build/v2.2.0-qa/protected-schemes/SHA256.json` **6/6 逐字一致**。
- `VALIDATION.json` 引用的 9 份 UI 日志哈希全部匹配；截图溯源文件的 **32/32** PNG 哈希匹配。
- 核对原始结果：完整 FiscalKit **408 tests / 39 suites** 通过；双端最终 App 构建日志成功。没有把这些既有结果称为本轮重新运行的测试。
- 核对实际产物：Mac Debug 与 iOS Simulator Release arm64 均为 **2.2.0 / 40，最低系统 26.0**，未使用旧配置目录中的 2.1.0 产物代替。
- `git diff --check` 通过；相对生产实现的 Backend 累计差异为空。

## Mac 账户浮层整窗补查

先尝试既有用例 `V15RootSmokemacOSUITests/testAccountHubAndSidebarPopoverKeepOverflowAccountsDiscoverable`。串行、`-jobs 2`、关闭并行测试，复用既有 DerivedData。日志 `build/v2.2.0-qa/review-mac-picker.log` 显示测试框架在启用 automation mode 时超时；**未进入用例，不能记为产品失败或自动测试通过**。

随后直接启动本轮构建的隔离 RootSmoke 测试宿主，注入正式工作区 fixture、多账户、浅色、1280 点宽窗口。通过 CUA 的原生按键完成以下完整路径：

1. 从总览进入账户页；现金与信用账户均可见。
2. 点击现金摘要卡，popover 打开，搜索框自动取得焦点。
3. 逐个原生按键输入 `no-such-account`，出现“没有匹配账户”，浮层保持打开。
4. Cmd+A、Backspace 清空查询，恢复四个现金账户；向下三次选中“测试账户5”（其余一户为信用账户）。
5. Return 关闭浮层并进入交易页；范围为“测试账户5”，账户 inspector 显示同一账户。
6. 打开信用摘要浮层，搜索框取得焦点；Escape 关闭，原账户范围与 inspector 保留。

这条路径为**整窗人工工具回放通过**，独立于既有离屏 AppKit 控件验证；不增加 35 项已通过 XCTest 的计数。CUA `typeText` 曾将文字写入背后的账户页搜索框；换用连续原生 `pressKey` 后整条路径通过，未据这一工具差异报告产品缺陷。

同一窗口还重现：选择测试账户5后回到总览，原有两条“最近交易”变为“当前范围暂无正式交易”，上方全账本金额不变。总览未来事项在所属接口读取失败时未显示错误或进度；本 fixture 没有提供对应账期详情接口，因此该操作只验证失败反馈，不能当作正常所属页打开验证。

测试宿主已关闭。没有启动或写入生产服务，没有替换用户安装的 App，没有新增模拟器、runtime、DerivedData，没有修改产品源码或六个 scheme。

## 视觉核验与验证边界

- 对照已确认 Mac 总览、iOS 导航参考与实际根截图，检查信息优先级、账户卡片、四个目的地、有字底部创建入口；另查看账户资料、安全、信用、分期、现金流表单、记录和分析等代表性专项截图。
- Mac 1280×820 实测首屏被净额卡和整宽月图占满，“接下来要处理”排在最近交易之后。此为信息优先级偏差，修正应依照计划的阅读顺序，不要求复刻参考图像素。
- 截图为隔离合成数据，跨模块 fixture 数值不同不直接归因为生产对账缺陷。离屏专项截图不能证明根窗口中的所有布局和焦点状态。
- 真实服务写入、实体设备和 OS 26.0 runtime 未在此次 Review 验证；沿用已有 iOS 26.5 验收材料。iPhone 重复导航等问题以明确源码路径归因，不能把单次入口用例当作重复进入覆盖。
- 本轮新增 XCTest 结果包约 118 MB；既有 DerivedData 约 2.7 GB、ModuleCache 约 2.4 GB、磁盘可用约 56 GiB。没有全局缓存清理。

## 修复后状态

原审查证据保留。用户授权后的 R1–R9/D1 修复与针对性回归已完成，当前以 [FIX_REPORT.md](FIX_REPORT.md) 和 [fix-source-manifest.json](fix-source-manifest.json) 为准；本文件中的未修复结论属于初次 Review 时点。
