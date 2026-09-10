# Fiscal v2.2.1 build 42 release state

2026-09-10, Asia/Shanghai. **RELEASING** — 用户已授权一条龙发布。最终 iOS 真机安装由用户在 Xcode 执行；不生成 IPA。

## Scope and audit

- A01–A21 全修及 R1–R5 独立复查闭环；详细证据见 [execution.md](execution.md)。
- 工作基线 `5a4991fc65e3326e411fcc96c9abfd7ec4b9bde4`；生产后端 `64cb1aee0190eeba81f1a38cf6b322d4d1ee33e4`，已装客户端源码 `89cb977e8d28fd8e8a098e5c0efe692893644785`。
- Git 已核对上述生产后端/客户端分别到工作基线的 Backend/App 差异均为空；本轮累计差异全部落在已复查的 98 文件源码清单。最后仅 macOS UI 测试 selector 校正，已重跑。
- 最终清单 SHA-256 `701a23dcf4fb94902188748e827ce196fbb2449d06cce476bcfb99f02abab59a`。六个用户 scheme 修改保留原字节、不提交，发布使用 canonical tagged schemes。
- 后端完整 430 tests、Apple 完整 431 tests 及末轮 65 定向 tests、11 UI 场景通过；真实 PG/文字与扫描 PDF/HTTP/恢复测试通过。

## Pending release actions

- 固定源码 commit/build tag，提交推送；三组串行 Release 构建，双平台签名/符号验证，Mac ZIP 验证。
- NB 生产 0038→0039；已核对旧 revision/readiness/备份正常。迁移期间停 Fiscal API 写入，保留迁移前后备份，升级后恢复服务、恢复演练和只读公网验收。
- Mac 旧包可恢复备份→换包→启动和真实读取；iOS Xcode 安装就绪。
- 补齐发布事实、云端事实与证据。当前尚未宣称发布完成。

## Rollback boundary

0039 已回填历史 mapping generation 后禁止盲目降级丢字段；后端恢复使用已校验迁移前备份恢复到隔离新目标、验证后再切换。Mac 旧包回退仅是客户端回退，不能冒充数据库回退。
