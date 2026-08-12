# P29-A · iOS statement import flow

状态：**Partial Automated Verification**；没有真实账单、Provider、生产请求、迁移、tag 或 push。

- Attention 只读派生 `statement_import_review` 与 `statement_import_failed`；不返回文件名、金额、证据或 Provider 内容，且不允许忽略。
- Kurisu/iOS More 已接入 Files PDF 选择、既有 security-scoped temporary intake、consent、masked evidence、response-unknown 显式恢复和 evidence-only review。P28-C 的 versioned resolution/final-draft/preview/confirm/receipt repositories 被注入同一 review model；不含 LocalAuthentication/Face ID。
- iOS review 现已展示当前行 masked evidence、冻结状态与可选择的五种 resolution（match 菜单只枚举既有 existing-transaction candidates，intentional ignore 需非空理由）；confirmation 只在 preview 后展示最终 tap，响应未知只显示显式 receipt lookup。evidence-only 从不显示编辑动作。
- `create_new` 先持久化明确 resolution，再打开最终草稿表单。类型、标题、正金额、发生时间、活动账户和活动分类均须用户显式选择；归档账户/分类不显示，也不把证据推断为任何默认值。workbench 分页用服务端 next cursor 加载，续页 batch version 改变时拒绝合并并提示 Reload。
- Swift model/URLProtocol tests 覆盖 masked-only cache-free route、fresh expected versions、409 reload/no resend、exact preview→single UUID confirm、response-loss 后仅显式 receipt lookup，以及 frozen row 不可进入 confirmation；scene exit 对应 `intake.cleanup()`/`review.clear()` 清除内存包、preview 与 response-unknown key。
- backend ruff/pyright → 0 errors；Attention+P24/P27/P28 PostgreSQL targeted → **15 passed**；fresh PostgreSQL full JUnit → **269 tests, 0 failures, 0 errors, 0 skipped**。macOS Swift tests → **122 tests / 21 suites passed**；macOS+iOS Simulator Debug builds 均通过。

未完成 Automated 门：iOS URLProtocol/UI 的 Files scene interruption、two-device 409、partial/receipt interaction coverage尚未建立；Kurisu 真机合成 fixture、VoiceOver/Dynamic Type/rotation/memory 与所有 production 门也未运行。QA 仅声明上述 Automated command evidence，不将其替代 Physical Device 或 production 验收。
