# v1.5.0 · P34 Builder QA

日期：2026-08-15（Asia/Shanghai）
状态：**Independent Review Verified（五轮：初审 1×P1、2×P2、1×P3；二审 1×P1；三审 1×P2；四审 1×P3 均已修复；第五轮终审 0 findings）。**

## 交付

- 新增版本化 `GET /api/v1/reports/monthly/{YYYY-MM}` 与 `GET /api/v1/reports/yearly/{YYYY}`。两者返回同一 `PeriodReport` 读模型：业务期间、`Asia/Shanghai`、`CNY`、`as_of`、`data_revision`、`report_schema_version`、`generated_at`、收入/消费/退款/报销、外部现金流、内部转账、期末信用与报销、账户/分类/商户/来源及完整性事实。
- 新增受认证的 `GET /api/v1/reports/period-drill-down`。cursor 严格绑定 period kind/value、revision、category/account/merchant/source filter 与时间/ID keyset；正式写入后稳定 `409 period_report_changed`，篡改或跨 filter cursor 为 `422 invalid_period_report_cursor`。SQL 使用 `LIMIT + 1` 和页级 select-in postings，不做全量列表切片或逐项查询。
- 报告读取以正式 `DataRevision` 前后检查包围；读中变更先清 ORM identity map 重读一次，第二次仍变化则安全失败，JSON/PDF/CSV 绝不拼接不同 revision。
- 新增每月/年度 PDF 与报告 CSV。两者直接接收同一 canonical `PeriodReport`；CSV 带 UTF-8 BOM、CRLF、公式注入保护，PDF 用 deterministic Type0 `STSong-Light` CID text。报告导出仅包含聚合和稳定 ID；不输出 transaction title/note、完整账户标识、账单/Provider 原文、凭证或 token。所有报告文件带 attachment filename、正确 content-type、`Cache-Control: no-store`、`X-Content-Type-Options: nosniff`。
- 保留 `/transactions/export.csv` 为 legacy ledger export，显式不当作 report；仅补同等 no-store/nosniff 文件头。Archive 继续同步传输、无 job/history/progress 语义；仅补 no-store/nosniff 文件头。
- P34 不引入 migration、表、后台任务、外部依赖或 Apple/View 改动；Alembic head 继续为 P33 `20260814_0033`。

## 初审修复（1×P1、2×P2、1×P3）

- **期末报销（P1）**：不再读取当前全局 outstanding。以 period end 前的不可变 `ReimbursementClaimRevision` / `ReimbursementReceiptRevision` 最新正式快照重建；source/receipt ledger 还须在边界前发生，且在该边界前未作废。draft 与 submitted 按 P30 的 active reimbursable allocation 定义计入；cancelled/voided 快照为零。后续到账、allocation、取消或作废不会改写先前已关闭的报告。该口径严格是“在期末前已正式记录的状态 + 在期末前发生的正式流水”；没有历史状态记录的系统事实不被伪称为可重建。
- **PDF（P2）**：移除 `categories[:120]` 与单页限制，改为实际多页 Type0 中文 PDF；所有 canonical 分类、账户、商户、来源及完整性行均输出，每页重复 title/period/meta/页码。
- **period 上界（P2）**：全路径曾统一接受 `0001–9998`；第三审发现上海历史 UTC 边界使 `0001` 不安全，现已收窄见下节。`0000`、超范围年或无效月均在 JSON、CSV/PDF export 和 drill-down 以稳定 `422 invalid_report_month` / `invalid_report_year` 失败，不再触发 Python `date`/`monthrange` 溢出。
- **stale path（P3）**：报告读冲突按实际资源生成精确 reload path：月/年报告指回本报告，drill-down 指回绑定相同 period kind/value 的下钻入口。

## 第二次审查修复（1×P1）

- **交易历史权威性（P1）**：期末报销不再以 mutable `transactions` 行决定 source/receipt 的业务归属。按同一个 `recorded_before`（上海 period end 的 UTC exclusive boundary）批量选取每个 transaction 的最新 `TransactionRevision`；其 `kind`、`amount_minor`、`occurred_at`、`voided_at` 与 transaction identity 是唯一交易权威。claim revision 只提供 allocation，receipt revision 只提供 receipt→claim/allocation 关系；receipt 内嵌 transaction 不参与日期/金额/作废判定，避免两套快照漂移。
- **可审计 cutoff**：一笔状态必须同时满足：(1) claim/receipt/transaction revision 在 period end 前已正式记录（`created_at < recorded_before`），(2) 其 transaction revision 的 business `occurred_at < recorded_before`，且该 revision 未作废。读取仍被同一次 `DataRevision` 前后检查包围；读中任何正式写入会重读或 409，故 JSON/PDF/CSV 不混 revision。期后 transaction/receipt replace/void/restore 创建的新 revision 不会覆盖期末选择到的旧 revision。
- **无需 migration**：现有 `TransactionRevision.snapshot` 已包含本修复所需的 id、kind、amount、occurred_at、voided_at、postings；没有伪造字段或新增持久化状态。

## 第三次审查修复（1×P2）

- **上海 UTC 下界（P2）**：`Asia/Shanghai` 的 `0001-01-01 00:00` 具有正历史 offset，`zoneinfo` 转 UTC 会下溢到 year 0；程序化边界测试验证这一事实。因此 API 的唯一公开范围为 **`0002–9998`**，而不是错误地声称支持 `0001`。`0002` 的月/年半开 UTC bounds 均可构造，`9998` 保持安全，`9999` 继续拒绝。
- **统一可发现契约**：月报、年报及四个导出 path 的 OpenAPI parameter description 公开 `Supported report years: 0002-9998`；所有 `invalid_report_month` / `invalid_report_year` 422 都含 `minimum_year`、`maximum_year`、`supported_year_range` details。month/year JSON、PDF、CSV 与 period drill-down 对 `0000`/`0001` 均走相同稳定错误。

## 第四次审查修复（1×P3）

- **drill-down 可发现性（P3）**：`/reports/period-drill-down` 的 query `period` 现以 OpenAPI `Query` 明确公开与六个 report/export period 参数一致的 `Supported report years: 0002-9998`，并说明 `period_kind=month` 使用 `YYYY-MM`、`period_kind=year` 使用 `YYYY`。`period_kind` 也说明其决定该格式；仅补契约文字，不改运行时解析、范围或错误语义。

## 第五轮终审

- **0 findings；P34 Independent Review Verified。** 审查链已覆盖历史期末报销、PDF 分页、时区安全范围、stale reload path 与 OpenAPI 可发现性；本轮不再需要实现改动。

## 验证

| 命令 | 结果 |
| --- | --- |
| `uv run ruff check src tests && uv run ruff format --check src tests && uv run pyright src` | 通过；199 个文件格式正确；Pyright 0 errors / 0 warnings。 |
| `FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p34_review3_20260815 uv run pytest tests/test_p34_reports_postgres.py tests/test_p34_schemas.py -q` | 7 passed；上游 TestClient 弃用警告 1 条。 |
| 同一 fresh PostgreSQL 执行 `uv run pytest -q` | **387 passed**；现有 TestClient 弃用警告与 P33 Pydantic field metadata 警告各 1 条。 |
| `FISCAL_DATABASE_URL=postgresql+asyncpg:///fiscal_p34_review3_20260815 uv run alembic current && downgrade -1 && upgrade head && current` | 成功从 `20260814_0033` 到 `0032` 后重升；最终单一 head `20260814_0033`。 |
| 回升后 P34 targeted suite；随后 `ruff check src tests`、`ruff format --check src tests`、`pyright src` | 7 passed；199 文件格式正确；Pyright 0 errors / 0 warnings。 |
| 第四审 P3：`FISCAL_TEST_DATABASE_URL=postgresql+asyncpg:///fiscal_p34_review4_20260815 uv run pytest tests/test_p34_schemas.py tests/test_p34_reports_postgres.py -q`，随后全量静态检查 | 7 passed；199 文件格式正确；Pyright 0 errors / 0 warnings。 |

## 覆盖的不变式

- 2024 闰年 2 月 29 日 `23:59:59 +08:00` 仍计入 2 月；年报与月报同一 ledger 在同期间产生相同汇总。
- `income=2,000`、`gross/net consumption=1,200`、外部 cash net=`800`；500 分内部转账单列流入/流出，不扭曲外部现金流或净额；分类 net 行逐行复算为报告 summary。
- CSV 的 category rows 可复算 summary；测试解析真实 PDF content stream，核验 `net_consumption_minor: 1200` 和 PDF 结构/中文 CID font，而不是仅检查 HTTP 200。
- 含公式式 title、完整卡号式 note 的交易不会出现于报告 PDF/CSV；报告与 legacy ledger export 的 OpenAPI paths 分开，报告端点缺认证为 401。
- 下钻 keyset 续页无重复；cursor filter 变更为 422，正式 ledger 写入后旧 revision 为 409。
- 历史期末报销覆盖：2 月末 allocation=1,200；3 月部分到账后为 600；4 月后续全额到账不回写 3 月。另覆盖 2023 年末的 submitted outstanding=700、2024-01 cancellation=0，年报和月报均守住跨年边界。
- 121 个 canonical 分类真实输出到至少 4 页 PDF；解析 PDF content stream 验证首行、末行与总额均未截断。`0000`/`0001`/`9999` 在报告、导出和下钻稳定 422；`zoneinfo` 证明 year 1 上海→UTC 下溢，合法闰年、最小 `0002` 与 `9998` 上界均可读。
- source expense 在期后移出 2 月、receipt 在期后由 3 月 replace 到 5 月、receipt void→restore 后，2/3/4 月的 period-end outstanding 仍分别为 1,200/600/0；2024-03 报告在 fresh head Archive restore 后与源库保持一致。

## 风险与下一步

- 除期末报销字段按既有不可变 revision 重建外，报告其余字段按当前正式账本重算，`generated_at` 明确记录生成时刻；API 不把未保存历史状态的领域事实伪称为过去快照。复原相同 Archive revision 后会从相同正式 ledger 重建同额报告（P34 未引入任何额外持久化状态）。
- 完整性字段复用 P30 的正式当前完整性事实；Statement Import 的历史状态快照模型尚不存在，因此 API 不把它伪称为某个过去时点的不可变状态。
- P34 已 Independent Review Verified。残余边界不变：除期末报销字段按不可变 revision 重建外，其余报告字段仍按当前正式账本重算；完整性沿用当前 P30 正式事实。下一步为 **F0 Planner**，先规划 V15 DesignSystem / Foundation 状态基础；旧 v1.4 View 继续保留，F1–F5 仍严格按各自门禁进入。
