# P29-A · iOS statement import flow

状态：**Automated Verification Complete；Kurisu synthetic main chain verified**。没有真实账单、真实 Provider、生产请求、迁移、tag 或 push；物理方向、内存压力与完整 VoiceOver 朗读顺序仍按下方边界单列，不能由构建或截图替代。

- Attention 只读派生 `statement_import_review` 与 `statement_import_failed`；不返回文件名、金额、证据或 Provider 内容，且不允许忽略。
- Kurisu/iOS More 已接入 Files PDF 选择、既有 security-scoped temporary intake、consent、masked evidence、response-unknown 显式恢复和 evidence-only review。P28-C 的 versioned resolution/final-draft/preview/confirm/receipt repositories 被注入同一 review model；不含 LocalAuthentication/Face ID。duplicate 只按已保存状态恢复：可审核批次直接进入 review，失败批次只允许用户明确 restart，处理中批次只可查询。
- iOS review 现已展示当前行 masked evidence、冻结状态与可选择的五种 resolution（match 菜单只枚举既有 existing-transaction candidates，intentional ignore 需非空理由）；confirmation 只在 preview 后展示最终 tap，响应未知只显示显式 receipt lookup。evidence-only 从不显示编辑动作。
- `create_new` 先持久化明确 resolution，再打开最终草稿表单。类型、标题、正金额、发生时间、活动账户和活动分类均须用户显式选择；归档账户/分类不显示，也不把证据推断为任何默认值。workbench 分页用服务端 next cursor 加载，续页 batch version 改变时拒绝合并并提示 Reload。
- Swift model/URLProtocol tests 覆盖 masked-only cache-free route、fresh expected versions、two-client stale 409→explicit reload/no overwrite/no resend、exact preview→single UUID confirm、response-loss 后仅显式 receipt lookup（unknown 后第二 confirm 为零 POST），以及 frozen row 不可进入 confirmation。start 返回 v2 后的 local extraction failure 断言 fail=v2；可控 scene/background cancellation 释放本地工作、清 source/package/preview，且仅已有 `register/start`，不发送 evidence 或 `fail`。P25 temporary-workspace 测试覆盖成功、失败和取消时删除 synthetic PDF/image 临时目录。
- backend ruff/pyright → 0 errors；P24/P28 PostgreSQL targeted → **8 passed**；fresh PostgreSQL full JUnit → **270 tests, 0 failures, 0 errors, 0 skipped**。macOS Swift tests → **126 tests / 21 suites passed**；macOS+iOS Simulator Debug builds 均通过。
- P2 follow-up：submit response unknown 时，iOS/macOS 不显示会远端变更的 Cancel；model Cancel 是保留脱敏包的本地 no-op，明确 Retry 才可再发 evidence。scene/disappear 仅清内存且不发 fail。Swift 自动覆盖 remote-unknown cancel=zero fail+explicit retry，以及 extracting cancel=one v2 fail；macOS Swift **127 tests / 21 suites** 与 iOS Simulator Debug build 通过。后端未改，本轮复用上一轮 fresh PG targeted **8 passed**、full **270 passed** 与 Ruff/Pyright 证据。

## Kurisu synthetic physical verification · 2026-08-13

- 使用与正式 App 隔离的签名 QA bundle `1.3.1 (22)` 和一次性本地 PostgreSQL `20260813_0029`；QA Keychain policy 已验证不能读取正式 bundle 的访问密钥。Kurisu 上既有正式 Fiscal 包和生产服务均未修改。
- Files 选择器只暴露 QA App 的受控 Documents 范围。用户选择一份 **2 页全合成 fixture**（一页文本层、一页栅格扫描）后，consent 先显示本地页数/hash 与将发送的脱敏字段；确认前无 API 调用，确认后仅传固定显示名、大小、页数、hash 与脱敏 JSON，不传 PDF/image/path/bookmark/原名/正文。提取后设备临时工作目录实测为 `0` 文件。
- 前台链路实际完成 `register → start → local PDFKit/Vision evidence → synthetic provider → validation → review`。服务端持久化 2 页、53 条脱敏证据行；首个故意错误的 synthetic source-ref 被 validation 拒绝且 ledger 仍为 0，修正为证据内 source-ref 后进入 review。再次选择同一 fixture 只恢复既有审核，不新建 batch、不重复提取。
- 真机发现 SwiftUI `List` 整行 tap gesture 会吞掉行内按钮；`c2b9f55` 将选择手势缩到 evidence text，并为行内动作使用 borderless button style。随后用户在 Kurisu 上明确选择一行、填写完整 create-new draft、查看“1 行将正式写入”的 preview，再点最终确认；结果行被冻结并显示 partial receipt。
- 一次性数据库确认：transaction/posting/provenance/confirmation operation=`1/1/1/1`，orphan posting=`0`，data revision=`11`，confirmed row=`1`。按原 Idempotency-Key 只读查询 receipt 返回同一结果且没有第二份 posting/provenance；证据不记录 key、金额、标题或 fixture 文件名。
- Attention API 派生 `statement_import_review` 与批次 deep link。真机最初暴露 iOS 未处理 `statement-imports` host；`c2b9f55` 增加 Attention/URL 的只读 `openExistingBatch`，一次 GET 后直接恢复审核，不重启 extraction/evidence/provider/confirm。修复后的签名 QA 包已在 Kurisu 冷启动该 deep link；数据库守恒不变。
- 最大辅助字号实际启动审核页：证据和长文本自然换行，行号、选择开关、resolution 动作与确认入口保持可见且可滚动。VoiceOver 已在真机实际开启并由 deep link 启动审核页；最终源码还为选择开关和四类行动作添加逐行 accessibility labels。受 iPhone Mirroring 限制，没有把逐项朗读顺序标为已验证。
- CoreDevice 在该真机明确不提供 remote orientation capability；同时 `sendMemoryWarning` 对存活 QA PID 返回设备侧 `ENOENT`。两次都没有触及数据库，进程/账本守恒随后复核通过。构建时发现 iOS 未声明 supported orientations，`c2b9f55` 已补齐 iPhone portrait/landscape 与 iPad 四方向，重建不再出现 Xcode orientation warning；实际手持旋转和内存警告投递仍不得伪称由工具完成。
- XCTest runner 在 UI 启动前由设备 `testmanagerd` session 返回 code 74；同一签名 QA App 的普通 CoreDevice 安装/启动和完整手工链路均成功，因此记录为设备测试运行器限制，不作产品通过依据。
- 最终代码门：macOS 完整 Swift **129 tests / 21 suites**；独立 iOS generic-device Debug build 成功，`codesign --verify --deep --strict` 通过，bundle Info 含声明的三个 iPhone 方向且无 Xcode orientation warning。

仍未完成：真实账单版式、真实 Provider 调用、真实 production backup/shadow/migration/deploy、macOS 真实账单链路、CoreDevice 无法投递的 memory warning，以及完整 VoiceOver 顺序观察。以上任何一项都不能由本次 synthetic/isolated 证据替代；未创建 tag、未 push。
