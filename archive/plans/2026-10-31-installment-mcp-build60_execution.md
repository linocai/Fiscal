# Fiscal Build60：MCP 分期查询与转分期

日期：2026-10-31（Asia/Shanghai）｜tag `v2.4.0-build60` → `4088936`｜状态：HZ MCP/Web 已上线，NB 不变｜基线 `92d01a1`（上一线上 `v2.4.0-build59` → `5287051`）

## 来源与决定

- 记账 Agent 报告：27 个工具里没有分期，3 期免息分期（AI 眼镜，每期 630.98，总价 1,892.94）只能每月按信用消费补记。
- 后端已有完整分期 HTTP 路由（`api/routes/installments.py`），本次只改 MCP 与 Agent 文档，**不改后端、无迁移**。
- 用户决定：只开放“已入账信用消费转分期”（消费照常走批次）；不开放新建消费同时分期、提前结清、取消、修改。AI 眼镜第 1 期所在的 10 月账单已出，后端拒绝转换（保护已出账单，不放宽），11、12 月仍按信用消费补记。
- 口径（用户已知悉）：转分期后整笔消费按购买日计入当月消费，分期只决定各期账单应还金额。

## 改动

- 新工具（共 30）：`fiscal_list_installment_plans`（列表或传 `plan_id` 查单个）、`fiscal_check_installment`（eligibility + 可选起始账单日）、`fiscal_convert_to_installment`（写入窗口，覆盖 13→14；`transaction_id`→`purchase_transaction_id`，幂等 key 经 `backend_idempotency_uuid` 转 UUID）。网关只做形状校验（期数 2–60、日期、手续费三字段一致性），资格与拆分全由后端决定。
- `SERVER_VERSION` `0.1.0+build60`；discovery 与 `/agent/` 说明页同步。

## 验证

- MCP unittest 50/50；ruff check / format --check 结果与基线 `92d01a1` 相同（既有 1 个 F401、15 个文件格式差异，未新增）；discovery JSON 可解析。
- 真实 Backend app + MCP service + 一次性 PostgreSQL（TOTP Session + 写入窗口，批次暂存→校验→提交）：
  - 账单日 1 日、还款日 10 日的信用账户；10-30 消费 189,294 可转，起始账单日首个为 11-01；09-15 消费（10-01 已出账）不可转，转换返回 `purchase_not_eligible`。
  - 3 期：11-01/11-10、12-01/12-10、2027-01-01/01-10，每期 63,098，无手续费交易；原样重试返回同一计划；同 key 改期数 409 `idempotency_key_reused`；新 key 再转 `installment_plan_in_use`；期数 1 在网关被拒、不调后端。
  - 账本搜索显示 `installment_relation`（role purchase）；账期应还 11/12/1 月各 63,098；月报 10 月净收支 −189,294、11 月 0；审计记录 `transaction_id` 与 `plan_id`。
- 未审查：已建议 review，用户决定直接上线。

## 上线

- 2026-10-31 18:40 CST：HZ MCP `releases/20261031-build60-4088936`（Python 3.12 venv，preflight 通过，`0.1.0+build60`，30 工具），Web `releases/20261031-web-build60-4088936`（`runtime-config.production.js`）；`current` 原子切换并重启 `fiscal-mcp`（现有 Session/窗口已清空）。NB、Nginx 未变。
- 公网：`/health`、首页、`/agent/`、`/agent/approve/`、`runtime-config.js` 200；discovery 30 工具、写入窗口覆盖 14；无 Session 与伪造 Session 的 `/mcp` 均 401；防嵌入头仍在。
- 回退：HZ 指回 `20261017-build59-5287051` / `20261017-web-build59-5287051` 并重启 `fiscal-mcp`。
- 资源：第一次 Web 包混入 macOS `._*` 文件，该暂存目录未切换上线，已移到 HZ `/home/deploy/fiscal-web-build60-appledouble-unused`；它与 Build58 两个 release、上传包 `~/mcp-build60.tar.gz`、`~/web-build60.tar.gz` 待用户同意后删除（工具删除命令被拒）。打包须用 `COPYFILE_DISABLE=1 tar --no-xattrs`。
