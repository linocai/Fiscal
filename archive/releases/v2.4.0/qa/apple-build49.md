# Apple Build49 验收（2026-09-26）

基线 `main` / `2d5cc840c4a558ced3fa5753606a9542c0f92618`。全部 Apple 测试经 `scripts/test_artifacts.py run` 串行执行，使用既有 DerivedData；iOS 目的地为 iPhone 18 Pro／iOS 27「主模拟器」，macOS 为 macOS 27。本轮未安装真机、替换正式 App、签名发布或导出 IPA。

| 范围 | 最终结果包 | 实绩 |
| --- | --- | --- |
| FiscalKit 全量 | `build/test-runs/v240-fiscalkit-final-second/tests.xcresult` | 329/329，通过，0 skip。P9 合成 PNG 字节实际经 `VisionOCRService` 识别为文字，再以 `source=ocr` 创建提案；未知响应复用同一幂等键，人工编辑确认后 execute 恰一笔。F2A 旧 Today 有效 facts/scope/分页/409/generation 断言已迁入当前 Model 测试。 |
| iOS 正式 RootSmoke | `build/test-runs/v240-rootsmoke-ios-build49-acceptance/tests.xcresult` | 3/3：原子录入呈现修复后的三主空间及分析、账户信用/分期直达、OCR 来源设置保存。 |
| iOS 冷热草稿路由 | `build/test-runs/v240-rootsmoke-ios-deeplink-verified/tests.xcresult` | 2/2：隔离 `fiscal-qa` QA bundle 经正式 `IOSRootView`；冷启动鉴权后打开既有 OCR 草稿；热启动依次打开第一、第二、第一草稿，无效目标显示告警，fixture 禁止 POST。正式 App 仅注册 `fiscal`，QA 编译产物仅注册 `fiscal-qa`。 |
| macOS 正式 RootSmoke | `build/test-runs/v240-rootsmoke-macos-final/tests.xcresult` | 4/4：三空间、账户信用/分期、最近交易精确详情、宽屏浅/深色整窗画布。像素比较保持三点与 ±1 RGB 容差。 |
| iOS Gallery 正式组件 | `build/test-runs/v240-gallery-ios-build49-acceptance/tests.xcresult` | 5/5：未来来源、多费用报销 300.00/20.00 独立提交且成功回执可见、AI 人工确认、稳定重试、CSV 导出。 |
| macOS Gallery 正式组件 | `build/test-runs/v240-gallery-macos-final/tests.xcresult` | 3/3：报销详情/编辑、CSV revision 绑定导出、保存取消与重试。 |

最终源码下 FiscaliOS generic iOS Simulator 与 FiscalmacOS App target、双端 Gallery、双端 RootSmoke 和 `V15GallerySnapshotTool` 均 BUILD SUCCEEDED。最终正式 App 日志为 `build/v240/ios-deeplink-final-build.log`、`build/v240/macos-build49-last.log`；测试支持模块只供 Gallery/QA/测试，不在正式 FiscalKit 源目标。Xcode 27.0；双端 Debug/Release 生效 `MARKETING_VERSION=2.4.0`、`CURRENT_PROJECT_VERSION=49`、最低 OS 27.0、SDK 27.0。最新 `xcodegen` 后 `AGENTS.md` 与六份用户 scheme 7/7 SHA-256/字节数匹配实施前快照。

测试中发现并闭环四个具体问题：旧宽屏断言中央取样落在卡片而非空白画布，改到相同空白高度且未放宽容差；iOS 报销成功后回执被滚出 sheet，正式 View 对成功/未知/失败/冲突自动滚到反馈；多费用 UI 测试原焦点 helper 被 sheet 顶栏与嵌套滚动影响，改按真实可视表单滚动；通知 URL 已到 Workspace 但独立 `recordProposalID`/`recordPresented` 状态使编辑器退回手工模式，合为单个带 ID 的 presentation item 后冷/热路由通过。旧失败的结果摘要保留在对应运行目录，测试包由资源计划精确退役。

未覆盖：真机照片库权限弹窗/系统选择器、快捷指令实际安装与通知系统横幅权限；设备支持只读审计在 `qa/device-support.json`，`pending_devices=[]`。本地 QA 证明设备端 OCR 文本链与正式路由，不能等同真机安装验收。
