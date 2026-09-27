# Fiscal V2.4.0 Build51 发布

2026-09-27（Asia/Shanghai）。用户已授权“一条龙发布”；当前状态：Build50 首次上线验收发现旧历史快照嵌套字段兼容遗漏，已定位并推进 Build51 修复；尚未完成发布。

## 范围与冻结

- 客户端上次记录：2.3.0（48）/ `825705eb0d5e1aa41f39cb200838fc6da948a195`；后端上次记录：`db95c136ddfb8efeba8e30e3ca59a4dc6db25c25` / `20260922_0041`。开始发布时现场核验。
- 与本轮实施基线 `2d5cc840c4a558ced3fa5753606a9542c0f92618` 比较，上述客户端至基线的 App 差异为空、上述后端至基线的 Backend 差异为空；因此已做的累计精简审查和 Build50 定向复查覆盖业务发布差异。
- 已验收 App+Backend 工作区内容指纹 `648e00bdcbf6b0a34a2cbdfde5bca990ee6fba3d0a0823c6994e12acc055bc86`；业务验证与独立复查见 [Build50 QA](qa/build50.md)。Build50 冻结 commit `0bd45b25d1ef0f41af9dfe40a225d477022b4da6`、不可变 tag `v2.4.0-build50` 已推送；Build51 待冻结，保护用户原有 AGENTS 与六份 scheme，不混入本轮提交。

## 发布步骤与当前状态

- [ ] 现场核验生产 revision、0041、备份/恢复、服务与客户端版本。
- [ ] 提交推送 main，验证源码一致，创建不可变 `v2.4.0-build50`。
- [ ] 0041 只读预检通过；非空 PDF、多对象报销或金额关系异常必须停止，不能绕过守卫。
- [ ] 后端标准 dry-run、停写、迁移前备份与恢复证明、0042 迁移、后备份、恢复验证、readiness/public smoke；财务 postings/交易事实核对。
- [ ] 最终冻结源码三组 Release 构建、Mac/iOS 签名与 profile、架构和 dSYM、Mac ZIP 解包验签。
- [ ] Mac 旧包可恢复备份后换装、单实例启动并读生产；iOS 签名产物供 Xcode 安装，不生成 IPA。
- [ ] 精确清理本地/远端发布临时副本，保留当前和回退包、数据库备份、最终验证证据；同步主 Plan 与云端事实。

## 回退边界

0042 不提供 downgrade。数据库回退依赖经验证的迁移前 0041 整库备份，并须处理新版本上线后的写入，不能仅把后端或客户端切旧就声称回退成功。禁止生成测试交易进入真实账本。

## 已知验证边界

真机照片库权限/系统选图、快捷指令安装及通知横幅尚未新增交互验证；iOS 最终安装由用户通过 Xcode 完成。当前待办由本次授权发布继续执行，不再要求重复批准。

## Build50 生产读取发现及 Build51 修复

生产迁移前 PDF 16 表全空、无多人 claim，7 个 claim 可无损转换。0041 备份隔离恢复通过后已迁移至 0042；transactions/postings 与报销金融事实指纹未改变。客户端三个 Release 构建及签名通过，Mac 已替换为 Build50并保留 Build48 回退包。

真实读取检查发现月报 500：历史 claim revision 的 `latest_receipt.transaction.reimbursement_relations` 仍有旧 `party_id/party_name`；新版严格响应模型拒绝旧字段。修复范围为所有历史 claim/receipt/transaction revision 的纯读适配，不改不可变 JSON、不改金融字段、不放松现行 API 契约。Build51 追加合成回归和独立复查后重新冻结、部署与双端签名构建；Build50 标签不移动。
