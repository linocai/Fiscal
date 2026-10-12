# Fiscal 原生 App 退役与仓库归档记录

日期：2026-10-12（Asia/Shanghai）｜类型：快修级仓库整理，无代码行为变更、无云端操作

## 目标

项目已转为 MCP 形态，仓库只保留现役链路：`MCP/` → `Backend/`（+ PostgreSQL），以及 `Web/`（TOTP 批准/discovery 页为 MCP 必需；React 控制台按用户决定保留）。原生端相关组件移出仓库并归档。

## 恢复点

- 不可变 tag `native-app-final` → `6477dca`（移除前最后一个包含 `App/` 的提交），已推送 `origin`。恢复源码：`git checkout native-app-final -- App scripts`。
- 移除前未提交的 `AGENTS.md` 一行与 6 个 xcscheme 改动（xcodegen 重生成噪声，scheme `version 1.7→1.3`）未提交，原样保存为归档包内 patch。

## 移出仓库（git rm）

- `App/`（172 个跟踪文件，原生 SwiftUI iOS/macOS 与 FiscalKit）
- `scripts/`（`test_artifacts.py`，仅服务 Apple 测试产物）
- `FISCAL_V2_FRONTEND_UPGRADE_PLAN.md`、`MACOS_FRONTEND_UPGRADE_CONTRACT.md`

同步精简 `AGENTS.md`（退役 Apple 前端规则，保留金额/时区/发布约束），更新 `README.md`、`PROJECT_PLAN.md`、`MCP/README.md`。`archive/` 历史记录保持原样。

## 本地归档

根目录：`/Users/linotsai/文稿/Claude/Fiscal-archive/`

- `2026-10-11-pause/`：上一轮暂停归档包（源码快照、Build51 发布物、云端退役发布树、Git bundle）。原记录路径有误，实际生成在 `~/Downloads/`，本次迁至此处，四个包 SHA256 复核通过。
- `2026-10-12-native-retire/packages/`：
  - `Fiscal-build-final-v2.4.0.zip`：`build/` 中 Build51、Build50 发布树、`v240` 与 `operations`（79 个文件，与源一致）。
  - `Fiscal-design-sources.zip`：未入 Git 的 `Fiscal 前端设计启动/` 设计稿。
  - `Fiscal-learnings-notes.zip`：被 gitignore 的 `.learnings/` 笔记。
  - `Fiscal-main-history.bundle`：含 `native-app-final` 与本次提交的完整 Git 历史。
  - `uncommitted-worktree-changes.patch`：上述未提交改动。
  - 同目录 `MANIFEST.md`、`SHA256SUMS`。

所有 ZIP 通过 `unzip -t`。

## 回收

- `build/` 其余内容（v1.5–v2.3 历届发布树、`test-runs`、QA 目录，合计约 2.3 GB）、`App/` 残留的 Xcode 用户状态、原 `Fiscal 前端设计启动/` 与 `.learnings/` 目录已移入 macOS 废纸篓，可恢复；清空废纸篓由用户决定。
- 空目录 `.planning/` 已删除。
- 仓库工作目录 2.9 GB → 约 565 MB（余量主要为 `Backend/.venv`、`Web/node_modules` 与 `archive/`，均在用或为历史证据）。

## 未触碰

`/Applications/Fiscal.app` 与 Build50 回退 App、HZ/NB 云端服务、数据库与备份、所有 env/密钥。

## 验证

- `MCP/tests` 27/27 通过（代码未改动，仅作回归确认）。
- 现役目录无对 `App/`、`scripts/test_artifacts.py` 或已移除计划文件的残留引用（`archive/` 历史除外）。
