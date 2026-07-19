# P19 · v1.2.4 云端连接鉴权全重做（个人访问口令）验收记录

发布版本 **1.2.4 (Build 17)**。整期属鉴权高危区，A→E 逐块跑门禁；单分支直接在 `main` 施工。
安全底线：访问口令与 access_key 全程不写日志、不进 git、不出现在本记录；本期未设定任何真实口令
（生产仍处 transition，设口令由用户在 mac Build 17 上自选完成）。冒烟只用一次性假口令占位值。

## 提交

| 批次 | commit | 内容 |
|---|---|---|
| P19-A | `4e496df` | 后端凭证与鉴权核心（transition 双通道、KDF、access_key、迁移、CLI 恢复、测试改写） |
| P19-B | `f417067` | Apple `AccessKeyStore`（iCloud 同步钥匙串）+ `AuthRepository` + `PassphraseModel` + 传输改线，删 `PairingLink`/`DeviceSecurityModel`/`DeviceSecurityRepository` |
| P19-C | `c1dbd4f` | 双端 App 壳注入 `PassphraseModel`、口令 UI、删 `onOpenURL`/pending 恢复 |
| P19-D | `6c80814` | 测试/工具 seam 改 `FISCAL_ACCESS_KEY`、删 `fiscal://` scheme、文案收口 |
| P19-E | `39e9cbc` | 版本 1.2.4/17、`FISCAL_PASSPHRASE_KDF_ITERATIONS`、口令运维文档 |

> Apple 三块（B/C/D）是同一次原子重构：`FiscalmacOS` 测试 scheme 会连带编译 App target，
> 因此 B/C/D 的门禁在整合树上一次性跑通，再按关注点拆成三个提交。

## 门禁数据

### 后端（`backend/`，P19-A）

| 门禁 | 结果 |
|---|---|
| `ruff format --check .` | 全部通过（164 文件 unchanged） |
| `ruff check .` | All checks passed |
| `pyright` | 0 errors, 0 warnings, 0 informations |
| `pytest`（绿灯口径，`env -u FISCAL_TEST_DATABASE_URL`） | 144 passed, 105 skipped |
| `pytest`（全 PostgreSQL 组，一次性库） | 238 passed, **11 failed** |
| 新增 `test_p19_access_credential`（Postgres） | 5 passed |
| access_credential 迁移往返（upgrade head → downgrade 0015 → upgrade head） | 通过；downgrade 后 `access_*` 表消失，upgrade 后重建 |
| `uv lock --check` | Resolved 44 packages（未引新依赖，PBKDF2 走 stdlib `hashlib`） |
| CLI `access initialize` / `reset-passphrase`（一次性库冒烟） | initialize→generation=1，重复 initialize 被拒，reset-passphrase→generation=2 |

**11 项 PostgreSQL 失败为既有基线，非本期引入**：P18 `results.md` §已记录「全 PostgreSQL 组合测试自
v1.2.1 起即有历史契约冲突失败，不作发布绿灯」。为证明 P19 零新增回归，在临时 worktree 上用 P19 之前的
`main`（6aad733）跑同一全组，得 **12 failed**；其中 `test_p11_issue_activate_rotate_revoke_and_roles`
是本期按计划删除的设备生命周期用例，故 P19 后为 11 failed（12 − 1），与我方改动完全对齐，未新增任何失败。
发布绿灯口径仍为「跳过 PostgreSQL 组」的 144 passed。

失败清单（三个都不含 P19 新代码）：`test_p10_api/migration/postgres`、`test_p12_migration`、
`test_p4/p5/p6_migration`、`test_p8_api`(×2)、`test_p8_migration`(×2)。

### Apple（`apple/`，P19-B/C/D/E）

| 门禁 | 结果 |
|---|---|
| `xcodebuild ... FiscalmacOS test -only-testing:FiscalKitTests` | 84 tests passed（含新 `FiscalKit P19 access passphrase` 套件 6 例） |
| `FiscaliOS` generic iOS Simulator Debug build | BUILD SUCCEEDED |
| `FiscalmacOS` platform=macOS Debug build | BUILD SUCCEEDED |
| `FiscaliOS` build-for-testing（编译 `FiscalUITests`） | TEST BUILD SUCCEEDED |
| `FiscalSnapshotTool` build | BUILD SUCCEEDED |
| `FiscalmacOS` Release（签名，`-derivedDataPath build/DerivedData-p19x-release-mac`） | 1.2.4 (17)，Developer ID Application: ZheYuan Cai (HX73DFL88G) |
| `FiscaliOS` Release（签名） | 1.2.4 (17)，无 `CFBundleURLTypes`，Apple Development / TeamId HX73DFL88G |
| `codesign --verify --deep --strict`（两个 Release） | valid on disk · satisfies its Designated Requirement |

FiscalKitTests 覆盖：`AccessKeyStore` 同步钥匙串属性（`kSecAttrSynchronizable=true`、
`kSecAttrAccessibleAfterFirstUnlock` 非 ThisDeviceOnly、service 名、access group 透传）、
`PassphraseModel`（登录→连接、transition 旧 token 桥接设口令、改口令换 access_key、
generation 全局吊销后转 unauthorized）。

全仓 grep 收口：`apple/` 生产代码与文案中 `设备密钥`/`一次性`/`粘贴`/`配对`/`fiscal://`/`PairingLink`
归零（历史 §12 存档叙述不改）；后端用户可见串无残留。

## 生产部署与迁移「零双端断连」验证点

推 `main`（39e9cbc）→ 服务器 `git reset --hard origin/main` → `deploy.sh` dry-run（revision 39e9cbc 正确）
→ `--apply --public-smoke`：后端门禁 144 passed、升级前**已验证备份 `fiscal-20260719T101319Z.dump`**、
迁移 `20260718_0015 → 20260719_0016`、readiness 与备份新鲜度通过、alembic_head=`20260719_0016`。

| 迁移步骤 | 状态 | 证据 |
|---|---|---|
| **1. transition 部署，旧端全程在线** | ✅ 完成 | `current → releases/39e9cbcf8851`；本地 `ready`；公网 `https://fiscal.linotsai.top` liveness `live`；`access_credential=0`（口令未设）、`active_device_tokens=3`（旧 mac + 两台旧 iPhone 的旧 token 仍可连）、`alembic=20260719_0016`。新端点冒烟：`POST /auth/session`→`409 passphrase_not_set`、`GET /auth/status`→`401`、`GET /accounts`→`401 authentication_required`；旧 `GET /device-tokens` 与 `/system/security-status`→`404`（端点已删）。 |
| **2. 设访问口令（关旧鉴权层）** | ⏳ 待用户 | 由用户在已装 Build 17 的 mac「访问口令卡」用旧 token 桥接调 `initialize` 设口令（口令用户自选；或 HZ `cli access initialize` 兜底）。设定瞬间凭证行落库、返回首个 access_key、device-token 层永久关闭；同一旧 token 再打受保护路由即 401。**本期不代用户设口令。** |
| **3. 逐台装 Build 17 iPhone，凭 iCloud/口令恢复** | ⏳ 待用户 | 用户自装 Build 17 后，经 iCloud 同步钥匙串自动恢复 access_key，或输一次口令 `session` 换本机 access_key。旧版 iPhone 在自身升级前的短暂掉线可接受（mac 在线）。 |
| **4. 记录旧 device token 全灭** | ⏳ 随步骤 2 | 设口令后 `kkk` 等孤儿 token 立即失效；`device_tokens` 表保留，下版清理。 |

## mac 换包

Build 16 (1.2.3) → `osascript quit Fiscal` 优雅退出 → `ditto` 备份为
`/Applications/Fiscal-build16-backup.app`（Build 16）→ `rm` 旧包 → `ditto` 装入 Build 17 →
`codesign --verify --deep --strict` valid（Developer ID）→ `open -a` 启动成功（版本 1.2.4/17）。
绝未用 `cp -R`。此刻 mac 运行 Build 17、生产处 transition，App 通过旧 token 桥接连接并展示「设置访问口令」卡。

## 运维恢复路径（无用户体系的「忘记口令」出路）

`python -m fiscal_api.cli.access initialize`（stdin 读口令，建凭证行 generation=1，作 mac-app 路径的操作端/兜底）
与 `reset-passphrase`（stdin 读新口令，强制改并 generation+1 全局吊销——**唯一的忘记口令恢复手段**）。
两者都在 systemd 单元的环境下运行（需 `FISCAL_TOKEN_PEPPER` 与 `FISCAL_PASSPHRASE_KDF_ITERATIONS`），
口令只经 stdin、不落参数/日志。步骤见 `infra/production/README.md` §Access passphrase。
回退：仅当 `alembic head` 与目标 revision 相同才用 `rollback.sh`；否则从已验证备份恢复。

## 遗留事项

- **iPhone 需用户自装 Build 17 后输口令**：两台 iPhone 仍在旧版，凭 transition 期的旧 device token 继续可用；
  用户设口令后需在各自 Build 17 上凭 iCloud 同步的 access_key 自动恢复或输一次口令重连。
- **访问口令尚未设定**：生产当前为 transition（`access_credential=0`）；设口令是用户动作，口令由用户自选，builder 不代设。
- **`device_tokens` 表下版清理**：本期只删端点与客户端 UI，保留表、model 与 `authenticate`（transition 需要）；
  下个版本连同 `KeychainTokenStore` 过渡桥接一并移除。
- 迁移验证点 2–4 的最终证据（设口令后旧 token 401、双端总览/下钻正常）在用户完成设口令与装机后补录。
