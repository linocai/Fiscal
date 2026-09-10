# Fiscal v2.2.1 build 42 release state

2026-09-10, Asia/Shanghai. **RELEASED** — 一条龙发布完成。后端已上线，Mac 已换装并实际读取生产；iOS 已完成签名真机构建，最终安装由用户在 Xcode 执行，不生成 IPA。

## Source and audit

- A01–A21 全修及 R1–R5 独立复查闭环，详细矩阵与验证见 [execution.md](execution.md)。
- 源码 `60efa4b3c7e932967e1754ad9fd42b5cbf8a5882` 已推送 main；不可变标签 `v2.2.1-build42` 已推送，tag object `a3784ae27fc7d2ded20725b4dbb7e798ed84c284`。既有标签未移动。
- 实际旧后端 `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4` / 0038，旧客户端源码 `89cb977e8d28fd8e8a098e5c0efe692893644785` / 2.2.0（41）。二者各自到工作基线 `5a4991fc65e3326e411fcc96c9abfd7ec4b9bde4` 的 Backend/App 差异为空；本轮累计 98 文件均与最终已审清单一致，生产部署的 55 个变更后端文件也逐个校验一致。见 [累计审查证明](qa/cumulative-audit.json)。
- 最终清单 SHA-256 `701a23dcf4fb94902188748e827ce196fbb2449d06cce476bcfb99f02abab59a`；R5 后仅 Mac UI 测试 selector 校正，已重跑。六个用户 scheme 原字节保留、不提交；发布使用 tagged canonical schemes。

## Verification

- 修复阶段：后端完整 430 tests、Ruff/格式/Pyright 通过；Apple 完整 431 tests，末轮 65 定向 tests；11 个 UI 场景通过。覆盖真实 PG、文字/扫描 PDF、正式 HTTP、归档恢复和重复写入保护；定向重跑不累加成独立覆盖数。
- 发布服务器独立门禁：Ruff/格式通过，Pyright 0 errors；170 passed、260 skipped（生产部署门禁明确不接生产数据库；260 个数据库用例已在本轮本地隔离 PG 全套验证），1 warning。
- 三组串行 Release 构建全部通过：iOS Simulator arm64、macOS arm64/x86_64、iOS device arm64。实际版本 2.2.1（42）、最低系统 26.0、生产 API URL、架构、iPhone device family 均校验。见 [build-state](qa/build-state.json)。
- macOS Developer ID，hardened runtime 与 secure timestamp；iOS Apple Development，有效配置及 application/team/Keychain/get-task-allow entitlements 校验。App/framework 严格验签与 dSYM UUID 匹配；Mac ZIP 完整性、解压后签名和二进制 hash 一致。见 [verification](qa/verification.json)。
- Mac 换包后单实例运行，总览与财务分析显示生产实时数据，已回到总览；未做生产财务写入，未归档私人画面。真实 AI provider 外发、iOS 最终真机安装、无边界压力测试不在已完成验证中。

## Production

- NB `114.66.2.205`，当前 `/opt/fiscal/releases/60efa4b3c7e9`，revision `60efa4b3c7e932967e1754ad9fd42b5cbf8a5882`，Alembic `20260910_0039`。
- 19:44:35 停 Fiscal API 写入并先备份，服务器门禁及迁移后于 19:45:33 readiness 通过；仅 Fiscal 服务短暂停写，其余项目、NPM/防火墙未改变。
- 0038→0039 成功；账户、交易（排除预期新增 generation 字段）、分录的条数与内容指纹在迁移前后一致。API 和四个运维 timer 均 active + enabled。
- 独立保留迁移前备份：`/var/lib/fiscal/backups/releases/v2.2.1-build42/pre/fiscal-20260910T114435Z.dump`，SHA-256 `d811b6695e9dda2bd05b88146c1e105520eb3b47cd4885645971273c99841997`。
- 独立保留迁移后备份：`/var/lib/fiscal/backups/releases/v2.2.1-build42/post/fiscal-20260910T114530Z.dump`，SHA-256 `ef31480e82269f6bb25078f47fd27e93d691672fc5c26b2eb6242cd583c6d34b`。两份均通过 manifest 与 pg_restore list；正式隔离恢复演练 19:45:36 通过，无孤立分录。发布备份位于 releases 子目录，免受普通 14 天平铺备份保留策略影响。
- 公网 live 200、ready 403、无鉴权 accounts 401；带鉴权 operations-status 200。新版 as-of-v1 的 2026-09 与 2026-04 月报均 200，能力响应头/未知余额状态字段通过；旧客户端 9 月 200、4 月明确 409 historical_balance_unavailable，符合缺历史依据时不伪造金额的兼容契约。不存在交易的 receipt 404 + no-store。
- 详见 [preflight](qa/production-preflight.json)、[deployment](qa/production-deployment.json)、[postflight](qa/production-postflight.json)。

## Delivery and recovery

- 安装且运行：`/Applications/Fiscal.app`，2.2.1（42）；二进制 SHA-256 `69534bdff1b77a2a661d9064b230018248b6cf2362965daf64ed19c40d42eb97`。
- 已验签旧版回退包：`/Applications/Fiscal-v2.2.0-build41-backup-20260910-194606.app`；旧 build 41 二进制 SHA-256 `1213e06659d2ebda29d1115d30574942a93dc2943be9ebefc0b3507939bdbdf9`。数据与既有凭据保留。
- iOS 签名真机产物保留于 `/Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou/Build/Products/Release-iphoneos/Fiscal.app`；项目 `App/Fiscal.xcodeproj` / FiscaliOS 已具备 2.2.1（42）与现有签名配置，用户通过 Xcode 安装。无 IPA、TestFlight、App Store 或公证提交。
- 安装包和符号位于 `build/release-v2.2.1-42/artifacts/`；见 [installation](qa/installation.json) 与 [checksums](qa/SHA256SUMS)。

| File | SHA-256 |
| --- | --- |
| `Fiscal-iOS-v2.2.1-build42-dSYMs.zip` | `9648c3a103442d0ae41e2565b3978888865c9f1310bf4886efa7e8f387bfde97` |
| `Fiscal-macOS-v2.2.1-build42-dSYMs.zip` | `a755b7bc43af49e6767d6926d943e1bb618b64fa3d589ef742d392127484bca8` |
| `Fiscal-macOS-v2.2.1-build42.zip` | `0ffe69ac56974ef08bcaa8fdf5b0c4777168be24717749ea85a0d9c1c2b4a604` |
| `RELEASE.txt` | `3f429df51ff4747330ac35bdceaa3730596b5568627510d02e05d3be23bb0c42` |

- 0039 保留历史 mapping generation 后禁止盲目 downgrade；后端回退须先停写并备份当前状态，再将上述迁移前备份恢复到独立新目标，检查 schema/数据/鉴权/readiness 后切换，不能直接丢字段。Mac 旧包只用于客户端回退。

## Closeout

- 复用既有 DerivedData/共享 ModuleCache，串行两 job；主模拟器保持 Shutdown，无新设备/runtime/全局 clean。六用户 scheme 校验不变。
- 仅删除本轮可重建的导出源码、打包 staging、Git bundle 及 NB 部署源码临时副本；保留已安装 App、旧包、生产前后备份、iOS device App、日志、签名包和符号。见 [resource-closeout](qa/resource-closeout.json)。
- `PROJECT_PLAN.md` 与 NB/HZ 事实入口已同步；无剩余 agent 发布动作。恢复工作从本记录、主 Plan 和 git status 开始。
