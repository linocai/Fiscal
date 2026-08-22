# v1.5.0 · F4 前端 QA

## F4-A — Reports facts + same-revision drill-down

**状态：F4-A Independent Review Verified（第二轮 0 findings）。** 审查链已收口为 `1×P1 + 3×P2 + 1×P3 → Builder remediation/reverify → Independent Review 0 findings`。后续 F4-B Backend revision-binding 与 Apple export UI 均已终审 verified；现只解锁 F4-C Builder，F5 和正式 root 仍锁定。

### 交付与边界

- 将 P34 月/年报告、summary/meta 和所有 server rows 收为 typed read seam；金额保持 CNY `Int64` minor units，未知 enum 只读显示。drill request 始终携带 exact period、`expected_data_revision`、opaque cursor 与 `limit 1...100`；409 用 ignore-cache fresh reload 接管。
- `ReportOwner(period, revision, filter, generation)` 绑定读取、drill 与分页。只有 non-nil category/merchant stable ID、account ID 或 known source 能下钻；nullable category/merchant、completeness、unknown source 明示原因且 transport 断言 0 次 drill request，绝不省略 filter 回退为全 period。
- completeness-only 报告以四项非零 completeness 计数进入 loaded（不误显为空）；换 lens 或 dismiss 会递增 generation 并清 drill/page/selection。首次 drill 与 append 分别建模，前者用捕获的 exact owner `retryCurrentDrill()` 重试；`offlineSnapshotAt` 每次从服务动态读取。unknown account kind 只读、禁用且带稳定原因，0 次 drill wire。
- 使用原生 SwiftUI 与既有 V15 DesignSystem，code/state-first；未引入 Web 或新库。iOS 为全屏报告与 sheet 内错误，macOS 为单窗口脊柱/报告/明细上下文；真实 `Button` 行保留可访问动作与命中区。

### 验证

- `cd App && xcodegen generate`：通过。
- FiscalKit：`xcodebuild ... -scheme FiscalmacOS ... -only-testing:FiscalKitTests`，**376 passed, 0 failed**（F4-A focused **7/0**）。
- 真实 iOS Gallery UI（booted `211DD03C-812D-4A42-97EF-F693D7DF924C`）：F4-A suite **3 passed, 0 failed**；覆盖 period/lens、completeness-only、enabled/disabled drill、首屏与分页失败/retry、conflict reload 与 return。
- 真实 macOS Gallery UI：F4-A suite **2 passed, 0 failed**；实际点击/动作断言报告行 drill、换 lens 清上下文、首屏/分页 retry、conflict reload 与 return。
- Release build：`FiscaliOS`、`FiscalmacOS`、`V15GalleryiOS`、`V15GallerymacOS` 均通过；SnapshotTool Release build/run 通过。
- `git diff --check`、cached diff check 与 F4 Reports clean-room/root/old-reporting search 均通过（Feature 未含 raw JSON、transport、旧 Reporting 或 root 依赖）。

### 审查链

- 首次 Independent Review：`1×P1 + 3×P2 + 1×P3`。
- Builder remediation/reverify：上述全量 Builder 证据，即 FiscalKit **376/0**、真实 iOS **3/0**、真实 macOS **2/0**、四个 Release/Gallery、SnapshotTool 与逐图 8 场景。
- 第二轮 Independent Review：独立 targeted **7/7**，**0 findings**。这是审查者的独立验证，不与 Builder 的 376/0 或 UI/build 证据混计。

### 场景图

SnapshotTool 最终生成、逐张检查并提升 8 张合成 F4-A macOS 场景：`report-light`、`report-dark`、`report-ax5`、`empty`、`loading`、`error`、`offline`、`unknown`，位于 [`screenshots/f4/`](screenshots/f4/)。检查确认深浅主题、AX5、长文本/金额、空/加载/错误/离线/未知状态均无裁切，并保留 disabled/read-only 语义。

### 已知限制与交接

F4-A 与 F4-B（Backend revision-binding、Apple export UI）均已终审；仅 F4-C Builder 解锁。F5/root 仍锁定，现有九个 macOS runtime deferred gates 不因本块关闭。

## F4-B Backend revision-binding

**状态：F4-B Backend revision-binding verified。** Independent Backend Review 终审 **0 findings**；F4-B Apple export UI 亦已第三轮 Independent Review 终审，现只解锁 F4-C Builder，F5/root 继续锁定。

- 四个 endpoint：`/reports/monthly/{period}/export.csv|pdf`、`/reports/yearly/{period}/export.csv|pdf`；缺省 query 保持旧客户端成功路径，提供 `expected_data_revision >= 0` 时在 P34 read boundary 前后确认 exact revision，不匹配或中途写入返回既有 409 `period_report_changed`（准确月/年 reload path）。
- 每次成功仅构造一个 canonical `PeriodReport`；CSV/PDF bytes、`fiscal-report-…-r{revision}` attachment 和 `X-Fiscal-Data-Revision` 都从该对象的 `meta.data_revision` 生成，避免路由层预比较后的 TOCTOU 或第二次读库。
- 新增 OpenAPI、legacy/bound success、四端 stale 409 和 interleaved formal write tests；并保留 P34 的 BOM/CRLF/formula guard、no-store/nosniff、PDF/CSV 安全字段边界。无 migration（纯 additive request/response contract）。
- Builder 证据：changed-file `ruff format/check`、Backend `ruff check .`、`pyright` 均通过；可执行 Backend full `pytest` 为 **147 passed, 241 skipped**（无失败）。Builder 本机未设置 `FISCAL_TEST_DATABASE_URL` 且 Docker daemon 不可用，故未把 PG skip 计为通过；全仓 `ruff format --check .` 仅被 `cash_flow.py` 与 `test_p13_cash_flow_postgres.py` 的既有格式差异阻挡，非 F4-B 路径。
- Independent Backend Review：本地 PostgreSQL 独立运行 `test_p34_reports_postgres.py + test_p34_schemas.py` **8/8**、scoped Ruff 通过，临时数据库已删除；终审 **0 findings**。这与 Builder 的无 PG 证据分列，不把 skipped 混入审查结果。

## F4-B Apple export UI Builder

**状态：F4-B Apple export UI Independent Review Verified（第三轮 0 findings）。** 本块只扩展 V15 typed artifact seam、Reports UI/fixtures/Gallery/tests 和 F4 QA；未改 Backend、F4-C、F5 或正式 root。

- Foundation 将月/年 × CSV/PDF 全部绑定当前报告 `expected_data_revision`；成功响应必须同时通过 content type、`Content-Disposition` 安全文件名、size 与 `X-Fiscal-Data-Revision == owner revision` 验证，否则 fail-closed、不落盘。`ExportOwner(period, format, expectedRevision, generation)` 在 period/reload/数据变更/dismiss 后失效；409/unknown 只要求 reload，不自动换 revision 重导。
- iOS 使用确认 sheet（含 sheet 内错误）；macOS 保持 single-window inspector 内联确认/传输/错误/success revision，真实 CSV/PDF 控件可达。离线、未读当前报告和传输中共享同一 disabled 原因；临时文件置于 app-controlled temporary directory，完成/取消/失效即清理。
- FiscalKit full runtime：**382 passed, 0 failed**；F4-B focused model：**6 passed, 0 failed**（含 409→dismiss→0 wire→fresh reload→new revision、temporary cleanup、save retry 0 GET 与 existing destination atomic overwrite）。真实 Gallery UI：iOS CSV verified-ready→ShareLink 可达→关闭清理且不显示 receipt，stale rejection **1 passed, 0 failed**；macOS inline PDF confirm→native handoff→success revision、Gallery save cancel/error→retry→success **2 passed, 0 failed**，无 macOS defer。
- 最终 Release build：`FiscaliOS`、`FiscalmacOS`、`V15GalleryiOS`、`V15GallerymacOS` 与 `V15GallerySnapshotTool` 均通过。SnapshotTool 用 F4-B-only scope 输出并逐张检查 3 张合成 macOS 图，且仅提升 `screenshots/f4/f4b-mac-export-controls-{light,dark}.png`、`f4b-mac-export-disabled-ax5.png`（正常 controls、dark、AX5 offline disabled）。
- `git diff --check`、cached diff check 通过；scoped Reports clean-room/root/old-reporting 搜索未见旧 `Data/`、`FiscalDesign`、旧 `ReportingModel/Repository`、root、raw transport 或 `JSONValue` import。F4-B 已终审，现只解锁 F4-C Builder；九个既有 macOS runtime deferred gates 保留为 F5/publish blockers。
- Second-review 2×P2 remediation：iOS ready 稳定标为 `v15.f4b.export.ready`，只说明服务器 artifact 已验证、可 ShareLink/存入 Files，关闭清临时副本且不伪造 receipt；macOS `NSSavePanel` 改为 staged atomic replace，已有同名目标覆盖成功，model 覆盖测试并保留 save error→retry 0 GET。传输口径固定为 `URLSession.data(for:)` 的真实 indeterminate transferring（5 MiB hard limit），不显示虚假百分比或逐字节回调。
- Apple Independent Review 链：**`3×P2 → 2×P2 → 0 findings`**。第三轮 reviewer 独立运行 F4BTests **6/0** 并给出 **0 findings**；此独立结果与 Builder 的 FiscalKit full **382/0**、真实 iOS **1/0**、真实 macOS **2/0**、四个 Release 与 SnapshotTool **3** 张逐图证据分列，不混计。Backend Independent Review 的 PostgreSQL **8/8**、scoped Ruff 与 **0 findings** 证据仍保留在上一节。

## F4-C — DataSecurity / encrypted Archive Builder handoff

**状态：Independent Review Verified。** 终审链为 **`3×P2 → 1×P3 → 0 findings`**；仅解锁 F5 Builder/audit，F5 formal root、publish、deploy、sign、tag 与 push 不解锁。本块只实现真实 Archive export 契约在 V15 Apple seam 与双端原生页面中的安全呈现；仅为 public false-only 边界改 Backend schema/route/tests，不改 reports、F1–F3、正式 root、部署、签名、tag 或 push。

- Backend contract audit：认证 `POST /api/v1/archives/export`、P22 body `{password, include_ai_raw:false}`、`application/vnd.fiscal.archive+json`、`fiscal-archive-v1.far`、`no-store/nosniff` 已存在。`ArchiveService` 采用 scrypt + AES-256-GCM，排除 credential/access key/provider secret，false 时替换 AI raw input；operator-only CLI 是 `open → dry-run → restore_empty_target`。无 contract 缺口，因此没有新增 live restore、history 或 progress endpoint。
- Apple seam/UI：新增 typed POST artifact response，并 fail-closed 验证 MIME、exact attachment、`no-store`、`nosniff`、nonempty 与 5 MiB 上界。请求始终带 `include_ai_raw:false`；Archive bytes 从不解码/显示/记录。`V15ArchiveModel` 以 generation/owner single-flight 管理 transfer，密码变更、cancel/dismiss/未知/保存取消均清理临时目录。iOS 只在原生 Files handoff 成功后显示 local success；macOS 使用 `NSSavePanel` 的 staged atomic replace。无 raw-AI 开关、无假百分比、无 server receipt/history、无 App restore。
- 首审 remediation：`ArchiveExportRequest.include_ai_raw` 收紧为 `Literal[False]`，route 也固定向 service 传 `False`；operator CLI `--include-ai-raw` 未改。成功写入 app-controlled temporary file 后，model 仅保留 `Metadata(filename)`，清空 password/password confirmation 并丢弃 `Data`；completed 同样仅 metadata。success/cancel/dismiss/reset 均清密码与 temporary artifact，failed/unknown 显示“重新输入并创建”和“关闭”；retry 只 reset，用户重新输入并确认后才发第二次 POST，绝不静默重试或伪成功。
- 测试：最终 `FiscalKitTests` **387 passed, 0 failed**，其中 F4-C focused Swift Testing **5/0** 覆盖 exact wire `include_ai_raw=false`、MIME/disposition/security/size fail-closed、offline 0 request、owner/cancel/unknown、temporary cleanup、save cancel 及 macOS overwrite。真实固定 iPhone 17 Pro simulator (`211DD03C-812D-4A42-97EF-F693D7DF924C`) 的 F4-C UI **2/0**，实际点击确认→validated-ready，验证 invalid metadata error、offline disable 与 disabled restore；最终 bundle 为 `/private/tmp/f4c-ios-ui-final4.xcresult`。
- 真实受控 PostgreSQL restore：仅使用新建临时 `fiscal_f4c_source_20260820` 与空 `fiscal_f4c_target_20260820`，均迁移至 revision `0035`；restore 前 target `accounts=0`。以 operator CLI 从 source export，随后 `open` 验证 encrypted archive、`include_ai_raw=false` 和 credential exclusion，CLI dry-run 的 relationship errors 为 0，再以 `--apply --confirm-empty-target` restore。fresh target readback 的 posting/revision fingerprint 与 source 一致，P34 monthly summary hash 一致；target `ai_settings=0`，不存在可启用 auto-execute 的设置。没有指向 current/dev/live DB。完成后精确删除临时 `.far` 与两个临时库，最终匹配临时库数为 0。
- Release/视觉：`xcodegen generate`、`FiscaliOS`、`FiscalmacOS`、`V15GalleryiOS`、`V15GallerymacOS` 和 `V15GallerySnapshotTool` Release 均通过。SnapshotTool 以 matching Release framework 实跑 F4-C scope，6 张图逐张目检并以 SHA-256/`cmp` 提升至 `screenshots/f4/`：`f4c-mac-{security-light,security-dark,creating,error,unknown,offline-ax5}.png`；覆盖浅/深、真实 indeterminate 阶段、error、unknown 与 AX5 offline，未见 raw payload、假进度或 restore affordance。
- clean-room：`git diff --check` 与 scoped DataSecurity 搜索通过；Feature 不直连 raw transport/`URLSession`、旧 repository/model/root 或 `FiscalDesign`。新增 Gallery 仅以合成 route 驱动同一 typed model/transfer，不是恢复成功替身。
- remediation verification：Backend schema/OpenAPI test 通过；独立临时 PostgreSQL `fiscal_f4c_api_gate_20260820` 迁移后 API `include_ai_raw:true` 为 422 且 service 未调用，false 返回真实 encrypted artifact、解封 manifest `includes_ai_raw=false`；2/0 后数据库精确删除并复查匹配数 0。scoped 与全量 Ruff/Pyright 通过，Backend full 无 PG 环境 **148 passed / 243 skipped**。Apple focused **6/0**（`/private/tmp/f4c-fiscalkit-remediation.xcresult`）、full FiscalKit **388/0**（`/private/tmp/f4c-fiscalkit-full-remediation.xcresult`）和真实 iOS **4/0**（`/private/tmp/f4c-ios-ui-remediation-rerun.xcresult`，failure→reset→new POST，unknown→close→new POST）通过；四 Release 重新构建通过。SnapshotTool remediation scope 6 图逐张目检（`/private/tmp/f4c-snapshots-remediation/`）：error/unknown 均真实显示 retry+close，无路径/raw payload/伪进度/restore 入口。macOS 仅 BFT/图证据，未重跑 runtime，也不称 runtime pass。
- second-review remediation verification：`writeTemporary` 的 production writer 保持 `.atomic`，但每次置于唯一 `FiscalV15Archive-<UUID>` 目录；任何 create/write throw 均删除该目录并 rethrow。受控 writer failure 测试断言 supplied root 为 **0 entries**、phase 为 failed，显式 reset/重新输入后才产生第二 POST 并 ready。F4-C focused **7/0**（`/private/tmp/f4c-fiscalkit-p3-rerun.xcresult`）、full FiscalKit **389/0**（`/private/tmp/f4c-fiscalkit-full-p3.xcresult`）和真实 iOS error/retry UI **4/0**（`/private/tmp/f4c-ios-ui-p3.xcresult`）通过；四 Release 重建通过。SnapshotTool F4-C scope 6 图逐张目检（`/private/tmp/f4c-snapshots-p3/`）：浅/深、creating、offline AX5、error 与 unknown 均正确，retry+close 可见，无路径/raw payload/伪进度/restore 入口。macOS runtime 仍只保留既有 deferred gate，未重跑也不称通过；Backend 未改、无需重跑。
- third-review evidence（与 Builder evidence 分列，不混计）：reviewer 独立运行 F4-C tests **7/0** 与 Backend no-PG **3/0**，结论 **0 findings**。Builder 的受控 PostgreSQL export→CLI validate/dry-run→fresh empty-target restore→fresh readback/cleanup 证据、Apple full FiscalKit **389/0**、真实 iOS UI **4/0**、四 Release 与 SnapshotTool 6 图均保留为实施验证，不计作 reviewer 结果。十个 macOS runtime blockers 全部保留，尤其 `F4C-MAC-UI-AUTOMATION` 仍为三次 activation `Running Background`、0-step 的 F5/publish blocker。

### Deferred gate — `F4C-MAC-UI-AUTOMATION`

三次独立 macOS XCUITest 运行均自然结束、**0 个业务步骤**，没有修改断言或用 BFT/快照代替：`/private/tmp/f4c-mac-ui-final.xcresult`、`/private/tmp/f4c-mac-ui-attempt2.xcresult`、`/private/tmp/f4c-mac-ui-attempt3.xcresult`。每次两个 F4-C 用例均在 activation 阶段失败为 `Failed to activate application ... (current state: Running Background)`。因此本 gate 加入既有九个 macOS runtime deferred gates，成为第十个 **F5/publish blocker**；环境恢复后先用该 target/scheme 重跑 `V15GallerymacOSUITests/F4CMacGalleryUITests`，通过前不得声称 macOS runtime 通过。
