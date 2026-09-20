# Fiscal v2.3.0 release state

最新发布：**2.3.0（45）RELEASED**，2026-09-20。Mac已换装，iOS签名构建就绪，后端无改动；详见[build45发布完成](#2026-09-20-build45-发布完成)。旧版本内容保留为历史记录。

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

## 2026-09-13 资源补清与工作流修正

上次“Closeout”只覆盖发布临时目录，未涵盖多轮测试和旧设备符号，资源收尾范围不完整；本节及[清理结果](qa/cleanup-20260913/summary.json)补正这一遗漏，不改动发布代码或标签。

- 经用户明确授权，删除30份过时/中止的xcresult和149个临时导出媒体，按清单计3.400 GB；保留19份最终验收/独立场景/未解决问题原始结果。49份原结果的完整测试摘要已转入[原始测试索引](qa/cleanup-20260913/test-results.json)。Mac长流程的断言失败及最新窗口丢失仍各保留原始证据，未将问题清理成“已解决”。
- `build/` 从5.401 GB降至2.008 GB。当前与回退所需的发布ZIP/dSYM校验和一致，已安装2.3.0（43）二进制及用户六个scheme保持原样；此次未访问后端或真实账本。
- iPhone18,4当前26.6.2的开发服务及关键符号验证通过后，删除其26.6.1缓存6.108 GB。对iPhone17,3最初误把连接记录当用户当前使用设备；用户明确没有该真机后，按闲置缓存删除其26.6.1目录6.103 GB，不要求准备新版、不改配对、不删除模拟器。
- 仅保留iPhone18,4 26.6.2支持目录；主模拟器/iOS26.5仍available、Shutdown。全局最终审计无待处理设备。按删除清单总计15.611 GB；整盘可用空间变化含APFS及其他进程影响，不全归因于本次清理。
- 2026-09-12记录的展开旧App备份路径在本轮核验时已不存在，本次删除范围未包含`/Applications`；v2.2.1-build42签名ZIP及符号仍完整保留、SHA-256一致，作为当前回退来源，不为清理再重复解压一份。
- 新增 `scripts/test_artifacts.py` 的run/plan/apply/check入口：测试必须登记用途及待收尾状态，不默认导出附件；删除前整批检查精确路径、未跟踪范围、内容指纹、唯一证据和在用状态；未分类产物或未收尾运行使check返回非零。14项隔离脚本测试通过，覆盖真实子进程成功/失败状态及删除防护；设备保留边界7项通过。未修改App源码、版本或build。
- 跨项目规则和设备审计工具落在全局AGENTS及`~/.codex/scripts/apple_device_support.py`，Fiscal细则与入口落在项目AGENTS及[scripts/README.md](../../../scripts/README.md)。删除计划、逐项回执和终验均在本节链接的证据目录；本轮临时枚举文件已清除。

## 2026-09-13 build44 紧急发布完成

用户明确要求立即发布。**2.3.0（44）完整发布与资源收尾完成**：后端和本机Mac已更新，iOS签名真机构建已就绪，由用户通过Xcode安装。未创建或修改真实财务账目。

- 冻结源码 `3b29dcdd8ed9b330949f716b3ba170ddcffc7216`，不可变标签 `v2.3.0-build44`，tag object `4cdf3ba76f81e56f33dd1f060aca90d4ead4b061`；main与标签已推送。收尾文档在其后单独提交，既有标签不移动。
- 主会话核对实际生产 `fa4181f` 至目标的累计11个App/Backend文件；无新增迁移，312个后端文件的上传及部署指纹均与冻结源码一致。本轮未执行独立复审，build43独立复审结论不覆盖新增快修。见[累计范围](qa/build44/release/cumulative-audit.json)、[部署源码](qa/build44/release/deployed-source-verification.json)。
- 同一源码的本地Backend全量474项通过；FiscalKit 459项通过、1项既有PDF/loopback条件跳过，Ruff/格式/Pyright通过。服务器门禁177项通过、297项数据库用例跳过、1项既有警告；数据库用例已由本地隔离PostgreSQL全量覆盖，服务器门禁不连接生产数据库。见[本地验证](qa/build44/verification.json)、[服务器门禁](qa/build44/release/server-gates.json)。
- 从标签导出canonical schemes，串行完成iOS Simulator arm64、Mac arm64/x86_64和iOS device arm64的Release构建，实际版本均2.3.0（44）。App/framework严格验签、Mac Developer ID与hardened runtime、iOS开发签名/profile、dSYM UUID和ZIP解压后签名/指纹均核验通过。见[构建](qa/build44/release/build-state.json)、[签名及包验证](qa/build44/release/verification.json)。
- NB当前目录 `/opt/fiscal/releases/3b29dcdd8ed9`，完整revision为上述源码，Alembic仍为 `20260912_0040`。API及四个运维timer active/enabled、数据库ready、磁盘healthy；15张财务表的条数与完整内容指纹在部署前后完全一致。
- 部署前备份 `/var/lib/fiscal/backups/releases/v2.3.0-build44/pre/fiscal-20260913T124654Z.dump`；部署后备份 `/var/lib/fiscal/backups/releases/v2.3.0-build44/post/fiscal-20260913T124656Z.dump`。均完成内容核验，20:47:01 CST隔离恢复演练通过，演练库已删除。发布备份以硬链接保留已有运维dump，避免重复整库占用；精确SHA-256及账本指纹见[部署证据](qa/build44/release/production-deployment.json)。
- 公网TLS/live、鉴权边界、运维状态、历史报表能力、幂等回执、30日预测与信用账户读取均通过；原报告消费的只读资格返回 `eligible=true`，可选起始账期60个。见[上线后核验](qa/build44/release/production-postflight.json)。
- `/Applications/Fiscal.app` 已换装并单实例运行2.3.0（44），二进制SHA-256 `acefa59362e62bcb22057fec1446b805b432386acba1026ba82fd4644b0599c0`。已验签回退包为 `/Applications/Fiscal-v2.3.0-build43-backup-20260913-204955.app`；数据及凭据保留。见[安装记录](qa/build44/release/installation.json)。
- 实际Mac页面显示“可以建立分期”，恢复用户原输入12期、零手续费，起始账单日2026-09-25、还款日2026-10-12，停在最终确认前。目视核对原生截图，未导出私人截图，未提交分期；生产只读验收不冒充整套真实写入端到端测试。
- 交付包与符号位于 `build/release-v2.3.0-44/artifacts/`，见[校验和](qa/build44/release/SHA256SUMS)。iOS真机App保留在既有DerivedData的 `Build/Products/Release-iphoneos/Fiscal.app`，工程版本与签名配置就绪；没有生成IPA或提交App Store/TestFlight/公证。
- 本地准确删除源码导出、打包staging和bundle，按分配空间计479,584,256字节；删除后整盘可用70,781,583,360字节。远端准确删除部署源码、bundle、测试缓存及已确认归属的临时目录，按逻辑空间计494,882,313字节。清单及保留项见[本地清理](qa/build44/release/local-cleanup.json)、[远端清理](qa/build44/release/remote-cleanup.json)，不同计量口径不合并宣称磁盘净收益。
- 测试产物终验 `complete`，无未分类产物、未收尾运行或待删残留；保留最终及未解决问题证据，没有批量导出附件。复用既有DerivedData与主模拟器，六个用户scheme逐字节保持且不提交；[设备审计](qa/build44/release/device-support.json)无待处理项。保护当前及回退App、安装包、符号、iOS真机构建和数据库备份。
- 后端回退可切回已保留的 `fa4181f02025` 源码并重启服务，schema同为0040；不得以代码回退为由用旧库覆盖用户后续写入。主Plan和NB事实已同步，无剩余agent发布动作。


## 2026-09-20 build45 发布完成

用户授权一条龙发布。**2.3.0（45）已发布**：Mac已换装并读取生产成功，iOS签名真机构建已就绪，由用户通过Xcode安装。发布与测试临时产物清理通过；设备支持缓存因新版符号未完整保留待处理。

- 发布源 `00a70259a29f38ec02b5ccfe601f6786a40318d6`、不可变标签 `v2.3.0-build45`、tag object `fd00959a3e281c7d7530ad21576fd6a4cf29579d` 已推送main。六份用户scheme逐字节保留且不提交，正式包从标签导出的canonical schemes构建；收尾记录单独提交，标签不移动。
- 从实际生产build44对应 `3b29dcd` 核对累计差异：只有iOS日期布局、工具链/build配置和测试隔离，无Backend差异、无迁移、无金额规则变化。主会话累计审查完成，本轮未调用独立复审。验证为核心459项通过/1项既有PDF联调条件跳过，iOS27界面10项及iOS26回归1项通过。见[累计核对](qa/build45/release/cumulative-audit.json)、[实施记录 §15](execution.md#15-2026-09-20-build45-ios-27兼容验证与快修)。
- 三组Release构建全部通过：iOS Simulator arm64、Mac arm64/x86_64、iOS device arm64。版本2.3.0（45）、最低系统26.0、生产API核验一致；Mac Developer ID/hardened runtime/secure timestamp、iOS开发签名/profile与有效Keychain组、App及framework严格验签、dSYM UUID、ZIP解压后验签/hash均通过。见[构建](qa/build45/release/build-state.json)、[包验证](qa/build45/release/verification.json)。
- 生产后端继续运行 `3b29dcdd8ed9b330949f716b3ba170ddcffc7216`，Alembic `20260912_0040`。仅只读核对RELEASE文件、服务、备份恢复状态及公网API；不重启、不迁移、不新增数据库备份副本。API与四个timer正常，最近备份及恢复演练verified，数据库ready、磁盘healthy；报表、30日公式、信用账户及鉴权边界读取通过。见[生产读取](qa/build45/release/production-postflight.json)。
- `/Applications/Fiscal.app` 已于17:23 CST换装并单实例运行。二进制SHA-256 `7575fc436ce02bb6cb06ae1424c70a6e5e1aafc612a80f18ff17e82aafc88785`；旧版已验签备份 `/Applications/Fiscal-v2.3.0-build44-backup-20260920-172334.app`。实际新窗口总览和30日预测成功加载，无真实财务写入。见[安装记录](qa/build45/release/installation.json)。
- iOS签名App位于既有DerivedData `Fiscal-gxhyzwdownkctphiwckdkhzmywou/Build/Products/Release-iphoneos/Fiscal.app`，工程build45及签名配置就绪。Mac ZIP和双端符号在 `build/release-v2.3.0-45/artifacts/`，见[校验和](qa/build45/release/SHA256SUMS)。无IPA、TestFlight、App Store或公证提交；iOS最终安装和真机交互由用户执行。
- 发布目录分配空间从367,357,952降到71,589,888字节，精确回收源码导出和打包staging。清理先发现完成后的ibtoold仍持有源码工作目录，退出该闲置进程后重验再删。测试资源终验complete，无未分类或未收尾测试；保留签名发布物、最终证据、日志、当前与回退App和iOS待安装产物。本轮未创建远端或自定义系统临时目录。见[资源回执](qa/build45/release/resource-closeout.json)。
- 设备审计已执行apply，无删除候选；`pending_devices=[iPhone18,4]`：iOS27.0新版调试符号仍缺usr/lib/dyld，旧支持文件保留，待新版准备完整再回收，不冒充设备资源全部清理完成。见[设备状态](qa/build45/release/device-support.json)。
- 主Plan及NB事实已同步。客户端回退使用上述build44备份，不涉及数据库恢复；不以客户端回退覆盖用户后续账目。

### build45 设备支持补充收尾

- 按精确iPhone目的地完成iOS27.0（24A437）符号复制与提取。Xcode27将完整符号写入arm64e子目录；全局审计脚本已兼容该布局，仍校验采集元数据、关键Mach-O及SHA-256，并拒绝链接路径和不完整新版回退到旧符号。7项隔离边界验证通过，临时测试目录自动回收。
- 新版开发服务与dyld/Foundation/UIKit符号验证通过后，删除同型号26.6.2（23G90）支持缓存，按分配空间计6,108,323,840字节；删除后新版符号指纹不变、旧路径不存在，pending_devices为空。详见[最终回执](qa/build45/release/device-support-followup.json)。本节关闭上文首次发布留下的设备待办。
- 首次准备未明确destination而误选已配对Watch，已中止；随后仅用精确iPhone目的地成功准备。未改配对、未安装手机App、未修改真实账目。发布标签及已安装客户端不变，iOS仍由用户通过Xcode安装。
