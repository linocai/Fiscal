# P29-A · iOS statement import flow

状态：**Automated Verification Complete**；没有真实账单、Provider、生产请求、迁移、tag 或 push。

- Attention 只读派生 `statement_import_review` 与 `statement_import_failed`；不返回文件名、金额、证据或 Provider 内容，且不允许忽略。
- Kurisu/iOS More 已接入 Files PDF 选择、既有 security-scoped temporary intake、consent、masked evidence、response-unknown 显式恢复和 evidence-only review。P28-C 的 versioned resolution/final-draft/preview/confirm/receipt repositories 被注入同一 review model；不含 LocalAuthentication/Face ID。duplicate 只按已保存状态恢复：可审核批次直接进入 review，失败批次只允许用户明确 restart，处理中批次只可查询。
- iOS review 现已展示当前行 masked evidence、冻结状态与可选择的五种 resolution（match 菜单只枚举既有 existing-transaction candidates，intentional ignore 需非空理由）；confirmation 只在 preview 后展示最终 tap，响应未知只显示显式 receipt lookup。evidence-only 从不显示编辑动作。
- `create_new` 先持久化明确 resolution，再打开最终草稿表单。类型、标题、正金额、发生时间、活动账户和活动分类均须用户显式选择；归档账户/分类不显示，也不把证据推断为任何默认值。workbench 分页用服务端 next cursor 加载，续页 batch version 改变时拒绝合并并提示 Reload。
- Swift model/URLProtocol tests 覆盖 masked-only cache-free route、fresh expected versions、two-client stale 409→explicit reload/no overwrite/no resend、exact preview→single UUID confirm、response-loss 后仅显式 receipt lookup（unknown 后第二 confirm 为零 POST），以及 frozen row 不可进入 confirmation。start 返回 v2 后的 local extraction failure 断言 fail=v2；可控 scene/background cancellation 释放本地工作、清 source/package/preview，且仅已有 `register/start`，不发送 evidence 或 `fail`。P25 temporary-workspace 测试覆盖成功、失败和取消时删除 synthetic PDF/image 临时目录。
- backend ruff/pyright → 0 errors；P24/P28 PostgreSQL targeted → **8 passed**；fresh PostgreSQL full JUnit → **270 tests, 0 failures, 0 errors, 0 skipped**。macOS Swift tests → **126 tests / 21 suites passed**；macOS+iOS Simulator Debug builds 均通过。
- P2 follow-up：submit response unknown 时，iOS/macOS 不显示会远端变更的 Cancel；model Cancel 是保留脱敏包的本地 no-op，明确 Retry 才可再发 evidence。scene/disappear 仅清内存且不发 fail。Swift 自动覆盖 remote-unknown cancel=zero fail+explicit retry，以及 extracting cancel=one v2 fail；macOS Swift **127 tests / 21 suites** 与 iOS Simulator Debug build 通过。后端未改，本轮复用上一轮 fresh PG targeted **8 passed**、full **270 passed** 与 Ruff/Pyright 证据。

未完成门：Kurisu 真机合成 fixture、VoiceOver/Dynamic Type/rotation/memory、真实 security-scoped Documents provider 行为，以及所有 production 门均未运行。QA 仅声明上述 Automated command evidence，不将其替代 Physical Device 或 production 验收。
