# Backend Build49 验收（2026-09-26）

审查基线 `2d5cc840c4a558ced3fa5753606a9542c0f92618`；目标版本 2.4.0、迁移 head `20260926_0042`。本轮只在本机合成 PostgreSQL 库验证，未提交、推送、部署或访问生产数据。

## 实现与路由

退役活跃 PDF 导入链及 16 张空表、多人报销 party 表/矩阵、旧月年报与 PDF 报表、分类 split、独立商户写管理、AI 自动策略/quality/shadow 运行管理。保留手机截图 OCR 所需的 AI 来源设置、provider、人工 proposal/action、识别规则，以及 CSV v2 报表、交易、账户、信用、分期、车贷和新单对象报销。OpenAPI 从 188 减至 142 个 operation，净删 46、无新增；快照 `build/v240/backend/routes-after.json`。

## 数据证据

- `uv run python -m fiscal_api.cli.v240_preflight` 对 0041 做只读预检，报告各退役 PDF 表数量、报销 party 计数、费用/回款金额和 override 数量；空库报告在 `backend-preflight-empty.json`。升级本身复用同一守卫。
- `tests/test_v240_simplification_migration_postgres.py` 7 项通过：合成 0041 单对象、两费用、两笔部分回款及 override 升到 0042，保留原 claim/expense/receipt/allocation ID、postings 总额 `-500` 分、revision JSON、预计日及对象名；override 从 party ID 映射到 claim ID。迁移中解决了旧版延迟触发器待执行事件与 ALTER TABLE 的冲突。
- 多 party、非空 PDF、override 冲突、override 孤儿、费用容量异常、回款分配异常六种情况，预检和迁移均拒绝；失败后 0041 revision、原表行数、postings 总额、归档 revision snapshot、费用/回款分配金额指纹逐项相同，无半迁移。
- 同一测试用基线 0041 工具生成真实加密归档；新代码验证并转换后在全新 0042 schema 恢复，和直接迁移的财务身份、postings、snapshot、override 对账一致。`sha256(原归档文件)` 在转换前后相等；多 party 归档拒绝而原文件不变。原 0038 工具恢复→升级与当前恢复路径的回归在 `test_v221_archive_compat_postgres.py`；0038–0041 entity shape 正向及非空 PDF 归档拒绝在 `test_v230_archive.py`。
- `test_p6_api_postgres.py` 真实 HTTP 流程消费 `-30000` 分、两笔回款 `+12000/+8000` 分、同 key 重试只保留两笔到账交易、第二回款撤销/恢复、最终 outstanding=0、postings 净额 `-10000` 分和 v2 CSV 可读；P6 服务测试还覆盖超额、预览失效、版本/并发、作废与恢复容量。

## 门禁与资源

- `FISCAL_TEST_DATABASE_URL=<本轮隔离库> uv run pytest -q --disable-warnings`：436 passed、0 failed、0 skipped，92.35 秒。唯一 warning 为已安装 Starlette TestClient 对 httpx 的第三方弃用提示，不影响结果。
- `uv run ruff check .`、`uv run ruff format --check .`、`uv run pyright`（0 error/0 warning）、`git diff --check -- Backend` 全部通过。相关报表重命名后另跑 70 项针对性测试和完整套件。
- 测试库 `fiscal_v240_archive41` 与 `fiscal_v240_build49` 删除前分别 12,422,491 与 29,901,315 bytes，连接数均 0；已逐库删除，随后查询库名均不存在。旧工具提取使用自动清理的临时目录；后端中间失败日志与 codemod 脚本已回收，只保留最终路由快照供集成比对。

生产当前是否存在非空 PDF 或多人报销记录未经读取；将来发布必须先在备份后运行 0041 预检，拒绝时按旧工具隔离恢复，不绕过守卫。0042 不支持 downgrade，回退依赖可验证的 0041 整库快照。本轮 Build 止于本地验证，未 Review、未发布。
