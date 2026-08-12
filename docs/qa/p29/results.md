# P29-A · iOS statement import flow

状态：**Partial Automated Verification**；没有真实账单、Provider、生产请求、迁移、tag 或 push。

- Attention 只读派生 `statement_import_review` 与 `statement_import_failed`；不返回文件名、金额、证据或 Provider 内容，且不允许忽略。
- Kurisu/iOS More 已接入 Files PDF 选择、既有 security-scoped temporary intake、consent、masked evidence、response-unknown 显式恢复和 evidence-only review。P28-C 的 versioned resolution/final-draft/preview/confirm/receipt repositories 被注入同一 review model；不含 LocalAuthentication/Face ID。
- iOS review 现已展示当前行 masked evidence、冻结状态与可选择的五种 resolution（match 菜单只枚举既有 existing-transaction candidates，intentional ignore 需非空理由）；confirmation 只在 preview 后展示最终 tap，响应未知只显示显式 receipt lookup。evidence-only 从不显示编辑动作。
- backend ruff/pyright → 0 errors；Attention PostgreSQL contract → 1 passed；iOS Simulator Debug build 已通过。

未完成 Automated 门：iOS final-create-draft 显式字段与 active reference picker、分页选择、409/partial/receipt UI tests；fresh PG full、macOS regression、Kurisu 真机合成 fixture、VoiceOver/Dynamic Type/rotation/memory 与所有 production 门。
