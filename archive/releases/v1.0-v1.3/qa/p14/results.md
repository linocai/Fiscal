# P14 现金流可编辑性与已完成账期修复验收

日期：2026-07-17

## 结果

- 所有待处理现金流均直接显示“编辑”，覆盖手工计划、信用账期和报销事项；历史中的已完成、已取消及已入账事项同样可编辑。
- 系统来源事项可编辑标题、备注、金额、日期和完成状态；已完成事项可重新打开。
- 截图中的 5 个旧账期已依据 LinoFinance 生产库的 `paid` 状态标记完成并移入历史：白条 2026-06-11、工商 3576 2026-06-12、花呗 2026-07-08、白条 2026-07-11、工商 3576 2026-07-12。
- 修订只写入系统现金流覆盖记录，不补造流水、不改变账户余额。生产正式流水修订前后均为 117 条，覆盖记录为 5 条。
- 生产待处理共 11 条，11 条全部包含 `edit`；上述 5 条均不再出现在待处理，并可在对应月份历史中查看和编辑。
- 后端已部署迁移 `20260717_0014`；部署前备份位于 `/var/lib/fiscal/backups/fiscal-20260717T064121Z.dump`。
- V1.1.0 Build 8 已替换 macOS 应用并安装到实体 iPhone。iPhone 安装成功，因验收时设备锁屏，系统仅拒绝了远程自动启动。

## 自动化验证

- Ruff 全量格式与检查通过。
- strict Pyright 通过。
- 后端无数据库测试：132 passed / 94 skipped。
- P13/P14 PostgreSQL 集成测试：3 passed。
- Alembic 0014 升级、降级至 0013、再次升级通过。
- macOS 与 iOS Debug 无签名构建通过。
- iOS 签名 Release Build 8 通过。
- macOS 签名 Release Build 8 通过；Apple 时间戳服务不可用，直装包使用 Developer ID 无在线时间戳签名。
- macOS/iOS Release 包均通过 `codesign --verify --deep --strict`，版本均为 1.1.0 (8)。

## 实机界面

- [macOS Build 8 总览](./mac-build8.png)
- [macOS Build 8 现金流](./mac-cash-flow-build8.png)

