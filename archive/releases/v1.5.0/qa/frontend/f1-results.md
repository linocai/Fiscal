# F1-A — Independent Review Verified

日期：2026-08-15（Asia/Shanghai）

## 范围与决策

- clean-room Bootstrap/Record 只经 typed `auth/session`、`auth/status`、`system/status`、活动账户/分类、`POST /transactions`；还款新增最小只读 `GET /credit-accounts/{account_id}/cycles`，供选择已存在账期，不含 F3 credit schedule mutation。
- 各 kind 明确定义 source/destination predicate；切换时实际清除不兼容账户/分类/账期引用，合法的现金/借记来源可保留。还款账期对 kind、destination、请求账户与 generation 四重守卫，success/failure/cancel 的旧请求均不得回写。
- 业务日交互与可访问性值固定为 `zh_CN` / `Asia/Shanghai` 中文语义；金额只经 `CNYAmountParser` 转 CNY `Int64` 分。
- create 幂等键绑定 canonical payload identity：response-unknown 原样重试；任一输入变更、确定性 server failure、409、成功、dismiss/下一笔均释放旧 key。成功态只插值服务端 transaction id/version/postings。

## 三轮独立审查与修复

- **首轮：5 项 findings 已修复。** create key 改为 payload identity 绑定；还款补正式 typed 账期只读；成功态改为插值服务端 id/version/postings；kind 切换清不兼容引用；业务日期改为 `zh_CN` / `Asia/Shanghai` 语义，并补五类录入的可审 UI 证据。
- **二轮：3 项 findings 已修复。** kind 改变实际清空 stale source/destination；账期加载在 success/failure/cancel 同时以 generation、kind、destination、请求账户守卫；替换中文日期 disabled 证据，并以真实还款路径覆盖人类可读账期、启用保存、服务端凭证及 AX5 可达。
- **三审：0 findings。** Independent Review 确认上述修复、typed 边界、fixture 合理性、测试/截图证据与 clean-room 约束；F1-A 终审通过。

## Builder 验证

- `F1ATests` 5/5：真实 backend JSON/path/header、CNY/溢出、Shanghai 月底、kind/reference 收敛、账期 delayed success/failure/cancel race、field error/409/offline、payload-bound idempotency（unknown→同 key、edit/422/409/success next→新 key）。
- `F1AGalleryUITests` 6/6：真实点击五类 Picker、sheet 内 disabled reasons、成功 id/version/posting count、中文日期 AX 值、真实还款（现金/借记来源→信用目标→可读账期→启用保存→服务端凭证）及 AX5 滚动可达。
- 全量 `FiscalKitTests`：163 tests / 25 suites 通过；正式 iOS/macOS、Gallery iOS/macOS 与 SnapshotTool build 均成功。所有构建串行且使用独立 `DerivedData`。
- clean-room `rg`：F1-A Bootstrap/Record/fixtures 不引用正式 root、旧 `TransactionEditorModel` / Screens、raw `APITransport` 或 `FiscalDesign`；`git diff --check` 通过。

## Independent Review 验证

- 三轮复核已完成；三审按 F1-A 的契约、竞态、真实交互/凭证、视觉与 clean-room 退出门复查，结论为 **0 findings**。

## 视觉证据（已人工检查）

- iOS 展开录入表单：[light](screenshots/f1a/f1a-ios-record-sheet-light.png) · [dark](screenshots/f1a/f1a-ios-record-sheet-dark.png) · [AX5](screenshots/f1a/f1a-ios-record-sheet-ax5.png) · [disabled reasons（中文日期）](screenshots/f1a/f1a-ios-record-sheet-disabled.png) · [还款有效路径](screenshots/f1a/f1a-ios-record-repayment-valid.png)
- macOS editor：[light](screenshots/f1a/f1a-macos-record-light.png) · [dark](screenshots/f1a/f1a-macos-record-dark.png)

截图不含账户尾号或其他敏感值。AX5 曾暴露系统日期 picker 横向撑宽，现只对该控件限制至可容纳的 accessibility size，其余表单文本保持 AX5。

## 关键命令

```text
cd App && xcodegen generate
xcodebuild ... FiscalmacOS ... -derivedDataPath /tmp/fiscal-f1a-r2-full-kit test -only-testing:FiscalKitTests
xcodebuild ... V15GalleryiOS ... -derivedDataPath /tmp/fiscal-f1a-r2-final-ui test -only-testing:V15GalleryUITests/F1AGalleryUITests
xcodebuild ... FiscaliOS ... -derivedDataPath /tmp/fiscal-f1a-r2-formal-ios-verify build
xcodebuild ... FiscalmacOS ... -derivedDataPath /tmp/fiscal-f1a-r2-formal-mac build
xcodebuild ... V15GallerymacOS ... -derivedDataPath /tmp/fiscal-f1a-r2-gallery-mac build
xcodebuild ... V15GallerySnapshotTool ... -derivedDataPath /tmp/fiscal-f1a-r2-snapshot build
```

## 残余风险与交接

- F1-A 已 **Independent Review Verified**；下一步为 F1-B Builder。F1-C、F2–F5 和正式 root 继续锁定。
- 账期 picker 当前仅覆盖首次读取结果；多账期分页的选择/继续加载仍是后续扩展风险，不能据此臆造或静默漏选账期。
- Gallery 仅为 fixture 并行入口，正式 root 未接入，符合 F1-A 范围；真实设备 VoiceOver 仍是发布门。

---

# F1-B — Independent Review Verified

日期：2026-08-15（Asia/Shanghai）

## 后端契约与范围收口

- 实现了 typed `/transactions` keyset list（完整 query、opaque cursor）、get、replace、void、restore、`/revisions` 与 `/provenance`；replace/void/restore 按真实 schema 提交完整 draft/`expected_version`。
- 列表、筛选、刷新、下一页、详情和 mutation 全有 generation 归属；旧页不会 append 至新筛选，旧请求不会清除新分页状态。response-unknown 不重写：先 `GET` + revisions 读回事实，保留“重新决定”状态。
- 发现并已写入主计划的后端事实：`available_actions` 当前仅返回 `void`（已作废时为 disabled void），不返回 edit/restore。因此 UI 只显示服务端授权的作废或逐项禁用原因；不会从 `voided_at` 推导恢复，亦不伪造编辑按钮。replace/restore 仅在 typed contract/reconciliation 覆盖，待后端将 capability 加入契约后才可成为 UI 操作。
- iOS 为搜索优先账目库与详情 sheet；macOS 为过去事实脊柱+检查器。无 Today/future/root/旧 View 接入。
- 首审整改：离线模型公开真实 snapshot 时间且所有 mutation 给出只读原因；下一页失败独立保留已读首页并局部重试；详情以 `requestedDetailID` 重试、不会回退旧选中项；筛选覆盖搜索、类型、账户、分类、日期、归类、来源、CNY 区间、作废范围；详情只显示账户昵称/分类/账期与格式化分录金额，绝不显示 UUID 前缀或账户尾号。

## Builder 验证

- F1-B 二审定向 `F1BTests` **10/10**：独立 read kind/source 的完整后端枚举与精确 query；void/restore 八类未知结果的单 POST→readback，以及确定性 request-encode/field/409 不读回。
- `F1BGalleryUITests` **4/4**：原生 kind/source Menu 使用稳定 identifier 实际选择 `installment_fee` 与 `system` 后刷新；其余列表/详情/离线/分页 UI 回归通过。
- 全量 `FiscalKitTests`：**173 tests / 26 suites** 通过；正式 iOS（Release generic Simulator）、正式 macOS、Gallery iOS/macOS 与 SnapshotTool build 均成功，全部串行独立 DerivedData。
- SnapshotTool 已实际运行；人工目检 macOS light/dark selected spine + inspector（含 history/provenance/void）、AX5、长中文和极端金额，无 UUID 前缀、账户尾号或金额截断。F1-B 目录内的 F0/F1-A/通用 state 图已清理。
- iOS 文件证据（均从本轮 UI xcresult 附件导出并目检）：[list light](screenshots/f1b/f1b-ios-list-light.png) · [detail light / history / provenance](screenshots/f1b/f1b-ios-detail-light-history-provenance.png) · [detail dark AX5 / void action](screenshots/f1b/f1b-ios-detail-dark-ax5-history-provenance.png) · [offline snapshot](screenshots/f1b/f1b-ios-offline-snapshot.png) · [pagination partial error](screenshots/f1b/f1b-ios-pagination-partial-error.png)。macOS：[selected light](screenshots/f1b/f1b-macos-ledger-detail-light.png) · [selected dark](screenshots/f1b/f1b-macos-ledger-detail-dark.png) · [AX5](screenshots/f1b/f1b-macos-ledger-ax5.png)。夹具不含账户尾号或真实数据。

## 已知限制与下一步

- **首审：7 项 P2/P3 均已修复。** 离线快照、局部分页失败、requested detail ID、完整筛选、可读命名、lastAction 与未知写入读回均已收口。
- **二审：2×P2 均已修复。** 读筛选使用后端全量 kind/source 枚举；void/restore 的真实 transport unknown/deterministic 序列均由模型级测试覆盖。
- **三审：仅 P3 文档修正；实施 0 P0–P2。** F1-B 已 **Independent Review Verified**；F1-C 已解锁，F2–F5 与正式 root 继续锁定。
- 后端尚未以 `available_actions` 授权 edit/restore；此为有意的 UI 收窄，不是客户端缺漏。若以后端契约扩展，此项须重新审查 UI 能力与禁用原因。

---

# F1-C — 四审修复 Builder Verified，待第五次 Independent Review

- 契约/模型：账户、分类、商户与 mapping 使用后端 typed schema；无 DELETE/merchant archive。未知非幂等写入仅读回或整表刷新，不重发；排序 409 重读 order-state；merge/split 与 mapping 重试保持 payload-bound key。
- 验证：F1CTests **15/15**；FiscalKitTests **188/188**；F1C Gallery UI **2/2**。正式 iOS/macOS Release、Gallery iOS/macOS、SnapshotTool build 均成功；SnapshotTool 实际运行 **exit 0**。
- 截图：iOS light editor/long merchant、dark AX5 offline 与 macOS light/dark/layout snapshots 位于 `screenshots/f1c/`；iOS AX5 已目检（中文 Shanghai 时间、禁用新建无裁切）。macOS `ax5` 仅为布局快照，非 Dynamic Type 验收。
- 静态检查：xcodegen、clean-room/root 搜索、`git diff --check` 通过；F2–F5 与正式 root 继续锁定。

## 首审修复 Builder 验证（待第二次 Independent Review）

- 修复归档账户的全量行数据与仅恢复动作；排序只使用 active order-state。账户/分类写入与后端 patch 字段对齐，归档对象在模型与双端 UI 均不可编辑；信用账户校验额度、账单日、还款日。
- 商户分页使用独立 generation，刷新不会遗留 loading；split 新 preview 清除旧 receipt，失败不会沿用旧成功关闭 sheet。
- 回归：F1CTests **15/15**、FiscalKitTests **188/188**、F1C Gallery UI **2/2**。F2–F5/root 仍锁定，等待第二次独立审查。

## 第二次审查修复（Builder Verified，待第三次 Independent Review）

- 信用账户仅提交后端 `statement_day_cutoff` / `previous_calendar_month`；正期初要求并提交上海业务日期。既有账户类型收敛为只读，避免以 Optional 伪造 JSON null。
- unknown readback 比较覆盖账户本次可提交的全部字段；商户搜索分离 draft/committed query，未提交新查询时不发送旧 cursor；分类方向重新开放给活跃分类，macOS 排序使用 Command-Option-Up。
- 回归：F1CTests **17/17**、FiscalKitTests **190/190**、F1C Gallery UI **2/2**；正式 iOS/macOS Release、Gallery iOS/macOS 与 SnapshotTool build 通过，SnapshotTool 实跑 **exit 0**。F2–F5/root 仍锁定，待第三次独立审查。

## 第三次审查修复（Builder Verified，待第四次 Independent Review）

- macOS 合并/拆分 sheet 与 iOS 同级挂载；仅 preview 成功才开启合并 sheet。merge/split commit 返回本次结果，成功后才关 sheet 并清 preview，失败保留 sheet、field/conflict/receipt 错误可见，避免旧 receipt 误关。
- 信用账户正期初清零采用强类型可空 patch 编码，精确发送两个业务日期 JSON `null`；账户、分类、商户保存均在 await 前捕获本次输入，读回判定不受随后编辑/选中变化影响。归档分类拒绝排序；账户和分类都提供基于 active sibling 的上/下移动与 Command-Option-Arrow 快捷键。
- 商户整表刷新清分页错误、旧分页仍按 generation 归属；保留 draft/committed query 边界，不把旧 cursor 带到新搜索。
- 最新源码回归：F1CTests **18/18**、FiscalKitTests **191/191**、F1C Gallery UI **2/2**。`xcodegen generate`、正式 iOS/macOS Release、Gallery iOS（由 UI test build）、Gallery macOS、SnapshotTool build 均通过；SnapshotTool 实跑 **exit 0**。已目检 macOS 深浅/布局快照；macOS `ax5` 仍只作布局快照，非 Dynamic Type 验收。`git diff --check`、clean-room/root 搜索、截图目录命名和 Plan 尺寸检查均通过。F2–F5/root 继续锁定，待第四次独立审查。

## 第四次审查修复（Builder Verified，待第五次 Independent Review）

- account/category create、patch、archive、restore 和排序的 409 现在单次写后实际重读；只有重读成功才说明已重读。重读失败保持显式 reload-required 状态，双端写入控件显示原因并在模型层拒绝继续写入，绝不重放原请求。
- merge/split 使用独立 `transformMessage`/failure/field-issues 状态，和通用 receipt/conflict/field issues 隔离；409 会立即作废 preview token、mapping/assignment，重读后仍要求重新 preview，提交不会使用旧 token。受控测试覆盖 save/archive/restore、merge/split 的单写、重读、失败锁定和 fresh-preview 解锁。
- 账户与分类的排序 hint 按当前可用性动态表达：可移动时读出 `⌘⌥↑/↓` 与一步方向，首尾时才读出边界原因；两端共用同一纯 spec。
- 最新源码回归：F1CTests **22/22**、FiscalKitTests **195/195**、F1C Gallery UI **2/2**。`xcodegen generate`、正式 iOS/macOS Release、Gallery iOS（由 UI test build）/macOS、SnapshotTool build 与实际运行 **exit 0** 全部通过。已目检最新 macOS AX5 布局截图（仍仅布局快照，非 Dynamic Type 验收）；`git diff --check`、clean-room/root、截图命名与 Plan 尺寸检查通过。F2–F5/root 继续锁定，待第五次独立审查。

## 第五次审查修复（Builder Verified，待第六次 Independent Review）

- merge preview 现在为每条 child mapping requirement 立即写入首个服务器 target，UI picker 直接绑定这份 payload 状态；多子分类无需触碰 picker 也可提交。任何 requirement 没有 target 都会保留可见原因并阻止提交。
- merge/split preview 的离线、传输和 409 均使用 transform 专属错误状态。409 只发起一次 preview，实际重读后作废旧 token/version/mapping 并要求 fresh preview；重读失败保持诚实错误与禁用提交，绝不重发旧 preview 或 commit。两端 merge sheet 都会在 preview 失败时打开并显示该错误。
- 最新源码回归：F1CTests **25/25**、FiscalKitTests **198/198**、F1C Gallery UI **2/2**。`xcodegen generate`、正式 iOS/macOS Release、Gallery iOS/macOS、SnapshotTool build 均通过，SnapshotTool 实际运行 **exit 0**；已目检本轮 macOS 深色、浅色和布局快照（macOS `ax5` 仍仅为布局快照，不作为 Dynamic Type 验收）。`screenshots/f1c/` 仅含 F1-C 文件；`git diff --check`、clean-room/root 搜索和 Plan 尺寸检查通过。F2–F5/root 继续锁定，待第六次独立审查。

## 第六次审查修复（Builder Verified，待第七次 Independent Review）

- account/category/merchant 无幂等 create 的 response-unknown 现在以完整实际 payload identity 锁定同一草稿；自动整表读取仅供事实参考，绝不确认或解锁同草稿。编辑器显示未确认原因与“重新读取后再确认”动作；只有显式读取成功后用户再次决定，或草稿真实改变为新的 wire payload 才可再 POST。读取失败保持全写锁，不能声称已刷新。
- 新建账户的最终 wire body 以 captured `kind` 派生：切换信用→现金/借记会清理 UI 信用字段，且编码层仍强制省略 credit limit、账单/还款日、cycle mode 与两项期开日期，满足后端 non-credit configuration 约束。
- 最新源码回归：F1CTests **29/29**、FiscalKitTests **202/202**、F1C Gallery UI **2/2**。`xcodegen generate`、正式 iOS/macOS Release、Gallery iOS/macOS、SnapshotTool build 均通过，SnapshotTool 实际运行 **exit 0**；已目检本轮 macOS 深色、浅色和布局快照（macOS `ax5` 仍仅为布局快照，不作为 Dynamic Type 验收）。`screenshots/f1c/` 仅含 F1-C 文件；`git diff --check`、clean-room/root 搜索和 Plan 尺寸检查通过。F2–F5/root 继续锁定，待第七次独立审查。

## 第七次 Independent Review（Verified，0 findings）

- 独立审查结论：**0 findings**；F1-C 已 **Independent Review Verified**，连同 F1-A/B 构成的 F1 总体亦已 Verified。前六轮 findings/fix chain 保留于本记录，未因本轮审查改动实现或测试。
- 已核验证据：F1CTests **29/29**、F1C Gallery UI **2/2**；正式 iOS/macOS Release、Gallery iOS/macOS、SnapshotTool build 均通过，SnapshotTool 实际运行 **exit 0**。
- 残余真实风险：仍需在后续发布门以真实后端环境核验网络/权限/数据状态；真机 VoiceOver 仍是发布验收项，不能由 macOS 布局快照替代。F2 仅解锁 Planner 规划；F3–F5 与正式 root 继续锁定。
