# Fiscal v2.3.0 build 43 release state

2026-09-12, Asia/Shanghai. **RELEASED** — 用户授权的一条龙发布已完成：后端0040已上线，Mac已换装并读取生产；iOS已完成签名真机构建，由用户通过Xcode安装，无IPA。

## Source and cumulative audit

- 发布源码 `fa4181f02025da25b15053eee12075ffe1a84bd4` 与不可变标签 `v2.3.0-build43` 已推送main；tag object `b2e97a85986dc44cc0592824a8b7f8b4f3b9a2dc`。既有标签未移动，收口文档提交在标签之后。
- 实际生产及旧客户端基线 `60efa4b3c7e932967e1754ad9fd42b5cbf8a5882` / 2.2.1（42）/ 0039，到实施基线 `0dab1386` 的App/Backend差异为空。本轮累计102个App/Backend文件，全部覆盖初审和修复复查。
- 独立复查最终目标 `92a630778ae2c0e5cd231232499dd054d6b5c86e` 至发布源的App/Backend差异为空；311个后端文件与469项全量验证时的指纹一致。上传源码及实际部署目录逐个核验一致。见 [累计审查证明](qa/cumulative-audit.json)、[部署文件核验](qa/deployed-source-verification.json)。
- 原B01–B07、R1–R5及追加两个账户保存边界全部闭环，契约和验证见 [execution.md](execution.md)。六个用户scheme逐字节保留且未提交，正式App从标签导出的canonical schemes构建。

## Verification

- 修复阶段Backend完整469项、FiscalKit完整460项/44 suites通过；Ruff/270文件格式/Pyright通过；双端App target构建通过。
- 发布服务器再次执行独立门禁：177 passed、292 skipped、1 warning，Ruff/格式通过、Pyright 0 errors。部署门禁不连接生产数据库；292个数据库用例已经在本轮本地隔离PG全量验证中通过。见 [服务器门禁](qa/server-gates.json)。
- 三组串行Release构建全部通过：iOS Simulator arm64、Mac arm64/x86_64、iOS device arm64；实际2.3.0（43）、系统26.0、生产API、架构和iPhone device family已核验。见 [build-state](qa/build-state.json)。
- Mac Developer ID、hardened runtime与secure timestamp；iOS Apple Development、有效设备profile及application/team/Keychain/get-task-allow entitlements；App/framework严格验签、dSYM UUID匹配、Mac ZIP完整性及解压后签名/hash一致。见 [verification](qa/verification.json)。
- Mac安装后单实例运行；真实总览的30天预测、预计入账/流出可见且无错误，交易顶部账户按钮可直接切换，再恢复全部账户并回到总览。实际截图已目视核验，未将私人界面归档，未创建生产财务账目。
- 本轮修复的长流程Mac create/payoff/reverse UI受桌面空间切换干扰，未获稳定全流程通过；真实HTTP回执显示通过，写入/撤销由真实HTTP及隔离PG用例覆盖。本次生产UI只读验收不冒充完整写入端到端验收。真实AI供应商外发和iOS最终设备安装未执行。

## Production

- NB `114.66.2.205`，当前 `/opt/fiscal/releases/fa4181f02025`；revision `fa4181f02025da25b15053eee12075ffe1a84bd4`，Alembic `20260912_0040`。
- 20:11:11 CST停止Fiscal API写入并保留备份；0039→0040迁移后20:12:11左右服务恢复，20:12:14整链通过。仅Fiscal服务短暂停写，未改其他项目、NPM、防火墙或杭州实例。
- 账户、交易、分录、现金流事项及修订的条数和完整内容指纹迁移前后一致。3条既有现金流关联按历史精确补全，无歧义、无差异、无新增结清操作或账目。
- 独立迁移前备份：`/var/lib/fiscal/backups/releases/v2.3.0-build43/pre/fiscal-20260912T121111Z.dump`，SHA-256 `45a572410e449ddcecf8e8af9fc8f4ed6f33089c7ff9992a5eccba3111140d47`。
- 独立迁移后备份：`/var/lib/fiscal/backups/releases/v2.3.0-build43/post/fiscal-20260912T121207Z.dump`，SHA-256 `800f6f09dd39987f9b1a3343f6902a1cb8234b6025bca1e4dd5b3a6b746f2101`。两份均通过manifest和pg_restore list校验；20:12:13正式隔离恢复演练通过，无孤立分录。releases子目录备份不受日常平铺14天清理影响。
- API与backup/restore-verify/health-check/disk-check四个timer均active + enabled；数据库ready、磁盘healthy。
- 公网TLS/live 200、ready 403、无鉴权accounts 401，带鉴权operations-status 200。当前与历史月报的as-of-v1响应通过；旧历史月报明确409 historical_balance_unavailable；不存在receipt为404 + no-store。
- 30天预测API的上海起止日期、现金＋流入−流出公式及缺口字段通过；全部信用账户summary和结清历史读取通过。详见 [preflight](qa/production-preflight.json)、[deployment](qa/production-deployment.json)、[postflight](qa/production-postflight.json)。

## Delivery and recovery

- 已安装且运行：`/Applications/Fiscal.app`，2.3.0（43），二进制SHA-256 `51ec5adf68990340067385f4579f894d20095994b7b9d5a7905b8cc579523d6c`。
- 已验签旧版：`/Applications/Fiscal-v2.2.1-build42-backup-20260912-201236.app`，2.2.1（42），SHA-256 `69534bdff1b77a2a661d9064b230018248b6cf2362965daf64ed19c40d42eb97`。数据与既有凭据保留。
- iOS已签名真机App：`/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou/Build/Products/Release-iphoneos/Fiscal.app`。项目 `App/Fiscal.xcodeproj` / `FiscaliOS` 的版本、build与既有签名配置已就绪；用户通过Xcode安装。没有IPA、TestFlight、App Store或公证提交。
- 安装包、符号和说明：`build/release-v2.3.0-43/artifacts/`，见 [installation](qa/installation.json) 与 [checksums](qa/SHA256SUMS)。

| File | SHA-256 |
| --- | --- |
| `Fiscal-iOS-v2.3.0-build43-dSYMs.zip` | `81635b754747dc30804790febb93dd30f46e6dc4dc0ead3f4db5a00924e11b81` |
| `Fiscal-macOS-v2.3.0-build43-dSYMs.zip` | `4a4a98eac6a8ba16fba20fff720a20f369e47289a09648c66a834a81fdcc28a0` |
| `Fiscal-macOS-v2.3.0-build43.zip` | `c5ebd27dc7b245a866c33bc465a8669dfbcccff82b71ccd5ef8ee26677121cc9` |
| `RELEASE.txt` | `f15dfe5e4446f725eb3b2fe1617321b8547ced2ed55d765cf287b4935fb9b3ab` |

- 跨0040回滚不得盲目downgrade，尤其已有随借随还、结清或新增关联时。先停写并备份当前状态，将上述迁移前dump恢复至独立新目标，核验schema/账本/鉴权/readiness及迁移后新增记录的处理后再切换。不得直接覆盖后续写入；客户端旧包回退不等同数据库回退。

## Closeout

- 复用既有DerivedData及ModuleCache，串行两job，无新模拟器/runtime或全局clean。六个用户scheme校验不变。
- 初次源码导出碰到系统Python不支持tarfile过滤参数，已改用Git archive与系统tar完成；失败步骤没有产物或生产改动，最终三个构建均独立成功。
- 仅删除本轮可重建的源码导出、打包staging、Git bundle和NB临时部署源码，保留正式App、旧包、独立数据库备份、iOS device App、安装包、符号和日志。见 [resource-closeout](qa/resource-closeout.json)。
- 主Plan及NB/HZ事实入口已同步，无剩余agent发布动作。恢复工作从本记录、PROJECT_PLAN.md和git status开始。
