# Fiscal V2.2.0（40）界面与验收

Swift / SwiftUI 实现的 Build 候选，覆盖 macOS、iPhone 的主空间、专项页面、表单和状态。Review 发现已修复，408 项单测与新增 8 个回归用例通过，双端构建通过；[修复与回归记录](FIX_REPORT.md)。尚未发布。

## 主界面

| macOS：总览与账户概览 | iPhone：总览与系统悬浮导航 |
| --- | --- |
| [查看原图](screenshots/fix-mac-overview-dark.png) | [查看原图](screenshots/fix-ios-overview-light.png) |

![macOS 总览](screenshots/fix-mac-overview-dark.png)

## 各页面与状态

| 范围 | 截图 |
| --- | --- |
| iPhone 四页 | [总览](screenshots/fix-ios-overview-light.png) · [交易](screenshots/ios-transactions.png) · [账户](screenshots/ios-accounts.png) · [分析](screenshots/ios-analysis.png) |
| 记一笔 | [iPhone](screenshots/ios-record.png) · [Mac](screenshots/mac-record.png) |
| 多账户 | [Mac 搜索和键盘选择](screenshots/mac-account-picker-native.png) · [Mac 窄窗口](screenshots/fix-mac-overview-narrow.png) |
| 信用账期 | [Mac 账期](screenshots/mac-credit.png) · [Mac 调整规则](screenshots/mac-credit-rules.png) · [iPhone 冲突反馈](screenshots/ios-credit-rules-conflict.png) |
| 分期 | [Mac 创建](screenshots/mac-installment-editor.png) · [iPhone 修改成功](screenshots/ios-installment-update-success.png) |
| 报销 | [Mac 新建](screenshots/mac-claim-editor.png) · [iPhone 回款预览失效](screenshots/ios-receipt-preview-invalidated.png) |
| 现金流与未来 | [Mac 编辑](screenshots/mac-cash-flow-editor.png) · [未来安排](screenshots/mac-future.png) · [iPhone 编辑](screenshots/ios-cash-flow-editor.png) · [字段错误](screenshots/ios-cash-flow-field-error.png) |
| AI 与导入 | [Mac 核对](screenshots/mac-ai-review.png) · [iPhone 人工确认](screenshots/ios-ai-confirmation.png) · [导入确认](screenshots/mac-import-confirmation.png) |
| 主数据与安全 | [Mac 账户资料](screenshots/mac-master-data.png) · [iPhone 账户编辑](screenshots/ios-account-editor.png) · [Mac 数据与安全](screenshots/mac-security.png) |
| 报表空态 | [Mac 无每日数据](screenshots/mac-analysis.png) |
| 深色与辅助功能 | [iPhone 深色](screenshots/ios-overview-dark.png) · [大字体](screenshots/fix-ios-recent-ax5.png) · [降低动态与透明度](screenshots/ios-reduced-effects.png) · [离线只读](screenshots/ios-credit-offline-ax5.png) |

截图来自正式工作区的隔离测试宿主及专项 Gallery，均为合成数据，不是用户账本。不同模块的 fixture 数值独立，截图用于界面、边界状态和操作验证，不作为跨模块对账证据。数据与安全图中的服务错误来自该 Gallery 未提供系统状态接口。

Mac 主界面采用真实窗口截图；专项页和账户输入补充了离屏原生视图验证。离屏截图不包含系统窗口边框与最终激活态材质，不代替整窗交互回放。

完整结果与限制见 [覆盖记录](UI_COVERAGE.md)，每张截图的来源见 [截图溯源](screenshots/PROVENANCE.json)。
