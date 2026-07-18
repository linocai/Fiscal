# P18 / v1.2.3（Build 12）QA 结果

日期：2026-07-18  
状态：代码、静态检查和签名构建通过；生产部署、实体设备安装与真实 API 截图待完成。

## 已验证契约

- `GET /api/v1/reports/overview` 保留既有字段并新增 `credit_due_events`：仅聚合 Asia/Shanghai 当天起 30 天内、未结清的信用账期，分组键为账户和还款日，金额为成员 `remaining_minor` 之和，排序为还款日、账户名、账户 ID。
- overview 最近流水服务端上限为 10；`account_value_minor` 仍是现金与借记卡余额的唯一来源。
- 消费根/子分类均按 `personal_realized_minor` 降序，稳定分类顺序只用于并列时打破平局。
- iOS/macOS 均展示现金余额、4 条内联信用应还和超过 4 条的完整列表；信用应还进入相应信用账户。报表仅消费口径，支持月份、分类金额/占比/笔数和流水下钻。
- 写入后由共享 `ReportingInvalidationCoordinator` 同时刷新总览与消费报表；消费选月不因总览刷新改变。

## 自动门禁

| 检查 | 结果 |
| --- | --- |
| `uv lock --check && uv sync --frozen --offline && ruff format --check && ruff check && pyright` | 通过（0 pyright error） |
| `env -u FISCAL_TEST_DATABASE_URL uv run --frozen pytest -q` | 136 passed, 99 skipped |
| P7/P17/P18 PostgreSQL 定向报告组 | 12 passed |
| `uv run --frozen alembic upgrade head --sql` | 通过；P18 无新增 migration/head |
| PostgreSQL 全量（fresh DB） | 未通过：222 passed, 13 failed；不可标为全 PG 通过 |
| PostgreSQL 失败隔离 | 7 个单例在 fresh DB/head 下失败；其余 6 个全量失败单例通过，属于共享 DB 的迁移测试顺序污染 |
| v1.2.1 tag 对照 | 上述 7 个 fresh DB/head 单例 7/7 同样失败，确认为已发布基线契约债务，不由 P18 改动引入 |
| `xcodegen generate` | 通过 |
| `FiscalKitTests` | 通过（83 项；仅既有 Swift concurrency warning） |
| macOS/iOS Debug build | 通过 |
| macOS/iOS Release build | 通过 |
| `codesign --verify --deep --strict` | macOS 与 iOS Release `.app` 通过 |
| Release bundle 版本 | macOS：`1.2.3 (12)`；iOS：`1.2.3 (12)` |
| HZ 部署 dry run / apply | 通过：服务器以 revision `0be5165f4eec450d7833c4d5165e4ed114993ce3` 创建 release、备份、校验 Alembic head `20260718_0015`、切换并重启服务 |
| HZ 冒烟 | 通过：服务器 readiness、公开 `/api/v1/health/live`、已授权 overview（10 条流水、4 条 `credit_due_events`）与消费分类 drill-down |
| iPhone 设备检查 | 两台均为 available/paired。Caeieo（iPhone 16）已安装 `com.linotsai.fiscal`；Kurisu（iPhone Air）的 Build 12 安装两次失败（远程安装服务超时/IXRemoteError 5），其既有 bundle 的启动也因锁屏被系统拒绝，故不能作为 Build 12 验收。 |
| macOS 替换与视觉 | `/Applications/Fiscal-build11-backup.app` 已由 1.2.1 (11) 备份；`/Applications/Fiscal.app` 已替换为签名 1.2.3 (12) 并启动。重启旧进程后，生产总览截图见 [`screenshots/macos-overview.png`](screenshots/macos-overview.png)：现金余额、10 条流水与 4 条信用应还均可见且未裁切。 |

## 已知基线债务

全 PostgreSQL 组合测试不能作为发布绿灯。v1.2.1 tag 在相同的 fresh DB、`alembic upgrade head`、单例命令下复现以下 7 项失败：P10 API/migration/postgres、P11 API、P12 migration、P8 API 两项。共同症状是旧 P10 未分类流水构造与当前 posting shape 约束不一致，以及迁移保护断言的历史契约冲突。P18 未改交易写入、posting 或 migration；本期保留该风险，不在报表范围内修改。

## 发布前仍需人工证据

- 使用生产等价数据完成 iOS Simulator/macOS 总览、消费、分类下钻、4 条与超过 4 条应还、空/加载/错误和归档账户深链截图，并验证 1040×700、1280×820 Mac 窗口。
- revision `0be5165f4eec450d7833c4d5165e4ed114993ce3` 已推送并部署至 HZ；备份、Alembic head、readiness、公开 liveness、已授权 overview 与消费下钻真实 API 均已验证。
- macOS 1.2.3 (12) 已安装并能启动，保留 `/Applications/Fiscal-build11-backup.app` 作为 Build 11 回退；生产总览截图已留存。两台已配对 iPhone 的 Build 12 启动和核心流程验收仍未完成：两台最新启动尝试均因锁屏被系统拒绝；Kurisu 此前的 Build 12 远程安装还受安装协调服务不可用阻塞。请解锁两台 iPhone、保持与此 Mac 的可用连接后重试 Caeieo 启动及 Kurisu Build 12 安装/启动，并将截图追加至本文件；此前不得创建 tag。
- 以上完成后才创建并推送 `v1.2.3` tag。

## 回退位置

应用回退使用 `/Applications/Fiscal-build11-backup.app`；仅在数据库 Alembic head 与目标 revision 一致时可走既有 `infra/production/scripts/rollback.sh`。否则按生产 runbook 从已验证备份恢复到新库，禁止盲目 downgrade。
