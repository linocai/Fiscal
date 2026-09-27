# Fiscal V2.4.0 Build51 发布

2026-09-27（Asia/Shanghai）。用户授权“一条龙发布”；**发布完成**：后端与 Mac 已发布，线上读取及本地/远端资源核验通过。iOS 设备安装按约定由用户通过 Xcode 完成，不生成 IPA。

## 最终版本与范围

- 正式源码：`b006ed906fb150a996499bdcbecd82063ee71723`；不可变标签 `v2.4.0-build51`（tag object `0104d303c5332a8b4cba5f13c44b3ba8298ec299`），均已推送。
- 后端生产同 revision，Alembic `20260926_0042`；Mac `/Applications/Fiscal.app` 为 `2.4.0 (51)`，已单实例启动并读取总览和财务分析。
- 累计起点：现场旧 Mac `2.3.0 (48)` / `825705eb0d5e1aa41f39cb200838fc6da948a195`；旧服务器 `db95c136ddfb8efeba8e30e3ca59a4dc6db25c25` / `20260922_0041`。各平台旧部署到实施基线 `2d5cc84` 的业务代码差异为空，Build49目标审查、Build50修复复查和Build51定向复查覆盖累计发布范围。
- 完全移除PDF导入及多人报销分摊，保留手机截图OCR人工确认录入；其余精简契约见 [执行记录](execution.md)。本轮原有 `AGENTS.md` 和六份scheme均未提交/覆盖，最终7/7逐字节不变。

## 发布中发现与修复

Build50 `0bd45b25` / `v2.4.0-build50` 首次上线时，迁移、备份恢复、签名构建通过；真实月报只读验收发现500。根因为旧claim/receipt revision中的内嵌transaction仍有 `reimbursement_relations.party_id/party_name`，新版严格模型拒绝该旧形状。

Build51在历史快照读取边界转换旧字段，同时覆盖月报、旧交易创建回执及报销操作回执；原JSON、金额、postings、现行严格响应契约均不改。生产旧关系实际位于6份claim及6份receipt revision，无历史多人revision。保持Build50标签不动，追加Build51独立标签、完整验证、备份部署和双端构建。七个Backend文件独立复查无finding，内容指纹 `680042b5604ce02da2b30705b68da55aa540199a77d1cbc9686989e7de98ce01`。

## 验收结果

- 后端隔离PostgreSQL **441/441、0跳过**，124.30秒；Ruff/格式/Pyright通过。新增纯模型2项与生产旧JSON形状集成1项，覆盖月报/年报/CSV、原revision不变及归档恢复后读取。
- 客户端业务代码除build号未再变化；沿用Build50全量335/335、最终定向6/6、双端商户UI各1/1。Build51从冻结commit导出规范scheme，三个Release构建通过：iOS Simulator、Mac universal、iOS device；[构建](qa/release/build51-build-state.json)、[源码核对](qa/release/build51-source-audit.json)。
- Mac Developer ID签名、hardened runtime、时间戳、arm64/x86_64；iOS Development签名、arm64、设备profile/entitlements；双端最低OS27。App/framework严格验签、dSYM UUID、Mac ZIP解包验签均通过：[签名与SHA256](qa/release/build51-verification.json)。
- 主会话独立生产验证：live200、外部ready403、未鉴权accounts401；当月/历史月/年报及月年CSV200、as-of语义正确；30天上海日期和金额关系、信用账户及结清历史读取通过。未写真实测试账目、未保存私人报表正文：[读取证据](qa/release/build51-production-postflight.json)。
- Mac换包有可恢复备份，实际总览本月收支和财务分析恢复，单实例及binary hash验证：[安装证据](qa/release/build51-installation.json)。最新两机开发支持审计 `pending_devices=[]`：[设备审计](qa/release/device-support-build51.json)。

## 数据库与回退

0041只读预检确认退役PDF16表全空、多人claim=0、7个claim可无损转换。停写并完成独立0041备份及隔离恢复演练后应用0042，前后核心金融事实指纹一致；Build51以0042→0042再次按标准流程独立前后备份、恢复验证，16张金融/历史表完整内容指纹和data_revision=102均不变。API与4个运维timer均active+enabled，health/readiness/public smoke通过。

四份保护备份的准确路径、SHA256、隔离恢复结果及远端清理见 [后端发布证据](qa/release/backend-production.md)。

0042没有downgrade。退回旧schema必须使用已验证的0041整库快照，并处理升级后的新写入；不能仅切旧API或旧App。迁移前Build48 App备份 `/Applications/Fiscal-v2.3.0-build48-backup-20260927-120318.app` 与换Build51前的Build50备份 `/Applications/Fiscal-v2.4.0-build50-backup-20260927-122541.app` 均保留。

## 交付与资源

- Mac已安装启动；可分发ZIP与双端符号、SHA256位于 `build/release-v2.4.0-51/artifacts/`。
- iOS签名App位于共用DerivedData的 `Build/Products/Release-iphoneos/Fiscal.app`；工程版本2.4.0/51、签名与最低OS27已准备好，用户通过Xcode安装。
- 两轮发布source/staging及已被替代的Build50 ZIP/符号包依精确指纹清单回收，合计501,080,064 allocated bytes；保留Build51正式包、回退App、生产恢复集、最终验收结果和日志。APFS占用差值不当作精确物理释放量。[清理计划](qa/release/build51-cleanup-plan.json)、[回执](qa/release/build51-cleanup-receipt.json)、[核验](qa/release/build51-cleanup-check.json)。
- 测试资源最终check complete，无未分类、未闭环运行、变更保留证据或待删残留：[核验](qa/release/test-resources-check.json)。系统临时目录中0byte `FiscalV15Exports` 属App运行目录而保留；两份传输bundle已精确回收137,306,112 allocated bytes且确认不存在；两处远端暂存均已清除，清理期间可用空间增加283,394,048 bytes。
- 真机照片权限/系统选图、快捷指令安装及通知横幅未新增交互验收；真实Vision OCR到人工确认与一笔execute已有Build49回归，不冒充上述真机验证。
