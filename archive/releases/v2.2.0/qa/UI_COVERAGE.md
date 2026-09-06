# V2.2.0（40）全界面施工与验证

权威入口为根 `PROJECT_PLAN.md`。完整 Review 的 **R1–R9 与 D1 已修复并针对性验证**，详见 [FIX_REPORT.md](FIX_REPORT.md)。本轮完整单测 408 项与新增 8 个回归用例通过，累计 43 个不同 UI 用例有通过证据；下表保留施工阶段记录。未提交、推送、发布或替换已安装 App。

## 全应用覆盖

| 页面家族 | 实施内容 | 已取得的验证 |
| --- | --- | --- |
| 主空间、总览、交易、账户、分析 | Mac 深青侧栏和统一账户摘要；双端四目的地；当月收支、真实 daily 和近期交易；多账户搜索 | iOS 正式工作区 8 条通过；Mac 冷启动、四空间、交易上下文往返、深色/1000 点窄窗口 4 条通过 |
| 记一笔与交易上下文 | 金额优先；iOS 原生底部创建和全屏编辑；Mac 总览/交易主动作与 Cmd+N，返回原空间 | iOS 键盘、日期、保存可达；Mac 总览/交易的记录往返通过 |
| Mac 账户选择 | 现金/信用共用受限高度 popover；原生文本输入、搜索、上下/回车/Escape | 离屏 AppKit 验证通过；Review 补查真实根窗口的连续按键、空结果、第五账户及进入上下文/信用浮层 Escape 通过；XCTest 框架限制见下文 |
| 信用及分期 | 阅读层次、分区编辑、预览步骤和确认状态 | Mac 账期/分期详情和创建 sheet；iOS 账期非法输入/预览失效/确认/冲突，以及新消费、已有消费转分期、正手续费和修改计划通过 |
| 报销与到账 | 金额、对象、分配、预览与反馈分区；Mac 三列工作区 | iOS 新报销单、非法/合法金额、回款预览失效及确认通过；Mac 两个编辑入口通过 |
| 现金流与未来 | 顶部筛选、Mac 双列阅读、计划/入账分区 | iOS 创建及 sheet 内字段错误通过；Mac 列表/详情/编辑和恢复入口通过；未来列表、长标题与大金额截图核对 |
| 导入与 AI | 三阶段导入、逐笔核对；AI 描述、金额核对与独立人工确认 | 两端脱敏导入/确认、AI 编辑/核对/人工确认通过 |
| 主数据、设置和安全 | 账户/分类/商户资料、管理入口、归档/密码分区；安全页双列顶端对齐 | iOS 账户/商户、离线和返回通过；两端归档确认与原生文件交接通过 |
| 报表明细和导出 | 四透镜、真实日金额图、整行点击下钻、导出反馈；无 daily 时明确空态 | 两端下钻/分页重试/返回及 revision 绑定导出通过 |
| 连接与共享状态 | 品牌入口、独立解锁、错误/离线/冲突/未知/预览/只读等统一容器 | 两端首次连接、完整模型测试；iOS 深浅色、AX5 和真实 Reduce Motion/Reduce Transparency 通过 |

## 门禁结果

原始日志与结果包在 `build/v2.2.0-qa/`。按独立 XCTest 方法去重，共 **35 项 UI 用例取得通过结果**，另有原生账户输入专项验证；不把受干扰失败的整窗用例计入通过数。逐项来源和日志哈希见 `VALIDATION.json`。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| FiscalKit 全量 | **408 / 408，39 组通过** | `full-fiscalkit-tests-final.log`，46.989 秒 |
| iOS RootSmoke | **7 条常规 + 1 条真实辅助功能通过** | `ios-root-r3`、`ios-reduced-effects` |
| Mac RootSmoke | **4 条独立用例通过** | `mac-root-final`、`mac-root-r3/r4` 的通过项 |
| iOS Gallery | **14 条独立用例通过** | `ios-gallery-final`、`ios-gallery-r2/r3`；早期 2 个定位问题已修正复测，报表整行点击实际缺陷也已修正复测 |
| Mac Gallery | **9 / 9 通过** | `mac-gallery-final` |
| Mac 原生账户输入 | **通过** | `mac-picker-native.log`；实际 NSHostingView / NSTextField / NSTextView，不向系统前台注入按键 |
| iOS App target | **构建通过，2.2.0 / 40、最低 26.0、仅 iPhone** | `ios-app-final-build-r2.log`；generic iOS Simulator，arm64，既有 scheme 使用 Release 配置 |
| macOS App target | **构建通过，2.2.0 / 40、最低 26.0** | `mac-app-final-build.log`；macOS arm64，既有 scheme 使用 Debug 配置 |
| 工程/工作区 | **通过** | `git diff --check`；六个 scheme 原始 SHA-256 一致；无 Backend diff |

完整单测之后仅补充每日空态与两处界面说明文案，没有修改金额/写入/模型逻辑；最终双端 App 构建已覆盖这些改动。已核验两个最终 App 的 Info.plist，不以旧缓存的同名 App 代替产物。

## 验收修正

- 现金净额保留负号；分组合计与差值溢出时明确不可汇总；信用溢缴明确标注，原始金额仍可访问。
- 正式总览/分析进入上海当前月份，刷新支持跨月；Gallery 明确注入固定月份。补充上海月末跨日测试。
- 总览 facts 和月报只在同 revision 下组合，缺 daily 不造曲线；空 daily 显示真实空态。
- Mac 金额卡片填满列；窄窗口保持可用导航；总览记账返回总览。
- 账户 popover 单一 presenter、稳定高度与子控件标记；文本焦点和按键由 AppKit 处理。
- iOS 报表分类/账户行补齐点击区域，对照 Mac 保持一致；报销候选去掉字段代码，账户编辑器沿用品牌色。
- Mac 数据与安全两列顶端对齐，空间不足时转单列；面向用户的记账/分析说明去掉工程表述。

## 验证限制与后续

1. **Mac 整窗人工工具回放已通过，XCTest 仍未取得通过结果。** Build 阶段曾受前台切换干扰；Review 本轮重跑在 automation mode 初始化时超时，未进入用例。随后在本轮构建的隔离根窗口用 CUA 连续原生按键走通搜索自动焦点、空结果、清空、选择第五账户、Return 进入对应账户范围和 inspector、信用浮层 Escape。此为真实窗口回放，不再只依赖离屏验证；不增加 XCTest 通过计数。见 [REVIEW_EVIDENCE.md](REVIEW_EVIDENCE.md)。
2. 使用既有 iPhone 17 Pro / iOS 26.5（211DD03C-812D-4A42-97EF-F693D7DF924C），没有新增模拟器或 runtime。未在 26.0 runtime 和物理设备逐项实测；26.0 的编译可用性由部署目标保证。
3. UI 操作和截图来自隔离 fixture，未访问或写入生产账本。需要本地种子服务器的 RootSmoke 未运行。不同模块 fixture 数值独立，不作为跨模块对账证据。
4. 真实辅助功能测试前记录 `ReduceMotionEnabled=0`、`EnhancedBackgroundContrastEnabled` 原本不存在；测试实际断言两项环境值均为 true，结束后逐项恢复并回读确认。未改变 Mac 系统设置。

## 资源与交付

- 继续使用既有 DerivedData 与 ModuleCache，全部构建 `-jobs 2`，关闭并行测试；单次仅有一个 xcodebuild。
- 收口占用约 DerivedData **2.7 GB**、ModuleCache **2.4 GB**、临时 QA **897 MB**，磁盘可用约 **56 GiB**。已删除本轮重复诊断包/录像约 **1.03 GiB**，保留文字日志；没有做全局 clean。
- 六个 scheme 的逐字备份与哈希在 `build/v2.2.0-qa/protected-schemes/`，从未暂存或回滚这些用户文件。
- [32 张代表性截图与导航](README.md)，归档共约 9.3 MB；截图来源见 `screenshots/PROVENANCE.json`。Mac 主空间使用真实窗口截图，丢弃离屏渲染中缺失合成侧栏的主空间图片。
- 状态仍在 main 工作区。R1–R9 与 D1 已修复并针对性验证，修复候选已收口；发布、签名分发、提交/推送和本机换包尚未执行。
