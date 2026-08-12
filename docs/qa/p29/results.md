# P29-A · iOS statement import flow

状态：**Partial Automated Verification**；没有真实账单、Provider、生产请求、迁移、tag 或 push。

- Attention 只读派生 `statement_import_review` 与 `statement_import_failed`；不返回文件名、金额、证据或 Provider 内容，且不允许忽略。
- Kurisu/iOS More 已接入 Files PDF 选择、既有 security-scoped temporary intake、consent、masked evidence、response-unknown 显式恢复和 evidence-only review。P28-C 的 versioned resolution/final-draft/preview/confirm/receipt repositories 被注入同一 review model；不含 LocalAuthentication/Face ID。
- backend ruff/pyright → 0 errors；Attention PostgreSQL contract → 1 passed；iOS Simulator Debug build 已通过。

未完成 Automated 门：iOS 五种 resolution/final-draft/confirmation UI、分页选择、409/partial/receipt UI tests；fresh PG full、macOS regression、Kurisu 真机合成 fixture、VoiceOver/Dynamic Type/rotation/memory 与所有 production 门。
