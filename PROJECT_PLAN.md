# Fiscal · PROJECT_PLAN

> 更新：2026-09-10（Asia/Shanghai）｜目标：**2.2.1（42）审计问题全修复**｜状态：**已完成修复与独立复查；一条龙发布进行中**

## 概述

用户已明确进入正式工作流并授权修复上一轮审计全部问题；本轮包含 A01–A17 缺陷和 A18–A21 架构优化，不以 Backlog 替代完成。保持 V2.2.0 已接受的原生 SwiftUI 产品结构和视觉语言。

用户随后授权 2.2.1（42）一条龙发布：提交并推送 main、固定不可变 build 标签、后端备份/0039 迁移/部署、签名构建与 Mac 换包；iOS 保留 Xcode 真机安装就绪状态，不生成 IPA。发布事实统一见 [发布记录](archive/releases/v2.2.1/RELEASE_STATE.md)。

## 稳定技术决定

- iOS/macOS 26+，Swift 6；xcodegen 管理 App 工程；后端事实以后端 schema/service 为准。四主空间、主要业务入口与双端能力保持一致。
- 界面金额输入为元、API/领域金额为 Int64 分；CNYAmountParser 统一转换。业务日期、报表期间与用户可见导出日期采用 Asia/Shanghai。
- 已发送写入属于不可变请求，输入、页面生命周期与读取 generation 不得销毁其幂等键和恢复归属。共享加密写入日志覆盖本轮记账、还款及导入关键写入；人工确认入账规则不变。
- 历史余额缺少生效依据时返回可识别的未知；界面与导出均不伪造为 0，不拿新确认的期初欠款回填早期报表。
- 真实 PDF 使用已有本地逐行证据/OCR/脱敏，statement 专用解析器复用现有 AI 配置；每次外发授权绑定当前配置和证据，Synthetic 仅用于测试夹具。
- 优化采用批量读取、请求内复用、有界缓存及缩短锁内计算；保留金额不溢出、信用限额、账期、revision、版本冲突及幂等不变量，不扩大成无关重构。
- API、归档兼容、迁移和回滚的唯一详细契约见 [本轮版本记录](archive/releases/v2.2.1/execution.md)。

## 当前状态

- 本轮基线 main：`5a4991fc65e3326e411fcc96c9abfd7ec4b9bde4`；源工程及双端实际构建产物均为 **2.2.1（42）**。
- A01–A21 全部完成，复查追加的状态收敛、跨午夜、缓存兼容及多窗口问题均已修复；无已知待修复 finding。逐项证据见 [版本记录](archive/releases/v2.2.1/execution.md)。
- 后端完整 430 项通过；Ruff/格式/Pyright 通过。0039 migration、历史回填、原生 0038 双路径恢复及并发快照均在唯一隔离库验证。
- Apple 完整 FiscalKitTests 431 项通过；末轮 65 项定向回归通过；iOS/macOS App target 和 11 个关键 UI 场景通过。
- 真实文字/扫描 PDF 经正式客户端 HTTP 和隔离后端完成确认及异常恢复；最终两份账单各入账一次，每笔支出 1850 分。
- 独立复查 R1–R5 闭环，最终生产源码与 R5 一致；仅随后修正一处 macOS UI 测试读取菜单文字的方式，已重跑通过。固定最终源码清单见 `build/v2.2.1-42/qa/final-source/manifest.json`。
- 六个用户既有 scheme 修改保持原字节，未暂存；当前改动保留在本地工作区，未提交/推送/打标签/部署/替换已安装 App/生成 IPA。
- 临时 loopback 服务已停止；唯一隔离测试库仅含合成数据。资源与日志位置见 `build/v2.2.1-42/preflight/runtime.json` 及版本记录。
- 待用户决定项：**无**。发布已授权，按后端 0039/API 能力先就绪、再交付客户端的既有发布链执行。

## 当前 Plan

B1–B6 全部验收完成；详细契约、测试、复查与发布边界统一在 [本轮版本记录](archive/releases/v2.2.1/execution.md)，本轮无剩余修复施工块。发布剩余：固定源码与签名 Release 构建 → 后端备份/迁移/部署及恢复演练 → Mac 换包/启动，iOS Xcode 就绪 → 记录归档。

## Backlog

本轮审计范围内无延期项。后续新需求单独定范围。

## 里程碑索引

- V2.2.0（40–41）界面重构及视觉快修已发布；原详细 Plan 已移至 [执行历史](archive/releases/v2.2.0/execution.md)，Build 41 发布事实见 [发布记录](archive/releases/v2.2.0/build41/RELEASE_STATE.md)。
- 2026-09-10：2.2.1（42）完成审计全修复、完整验证及 R1–R5 独立复查；本地候选未发布，详见 [版本记录](archive/releases/v2.2.1/execution.md)。
