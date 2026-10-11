# Fiscal Agent-first 第一阶段施工记录

日期：2026-10-10（Asia/Shanghai）  
范围：只新增独立 MCP/Web 层，不改 Fiscal 现成组件  
基线：V2.4.0 Build51

## 已完成

### MCP/

- 新建独立 Python 包 `fiscal-ledger-mcp`，不导入 `Backend/` 代码、不连接数据库。
- 建立 9 个稳定工具契约：月报、年报、账本搜索、导入批次创建/读取/校验/提交/忽略、报告导出。
- 增加参数校验、整数小单位金额、ISO 日期/Asia/Shanghai 约束、原始输入 SHA-256 指纹和工具 JSON Schema。
- 增加 API key 哈希指纹、scope、撤销、过期校验；增加 HMAC 批次+版本确认凭证。
- 增加 service 编排、有限审计 sink、Mock adapter 和既有 Build51 读接口的 HTTP adapter。
- 增加 stdio JSON-RPC 的 `initialize`、`tools/list`、`tools/call`、`ping` 入口。

### Web/

- 新建独立 Vite/React/TypeScript 控制台，页面与服务层通过 `FiscalApiAdapter` 隔离。
- 建立待确认、月度报告、账本搜索、设置/导出四个入口。
- 提供 normal/empty/error 三种 mock 演示状态，覆盖加载、空数据、错误重试和批次详情抽屉。
- 使用响应式布局完成桌面侧栏和移动端导航；不保存真实密钥、不连接数据库、不执行真实提交。
- scope 命名与 MCP 契约统一为 `read:reports`、`read:ledger`、`stage:imports`、`commit:imports`、`export:reports`。

## 验证

- Python 3.12：`MCP/tests` 7/7 通过。
- Ruff：`MCP/src MCP/tests` 通过。
- Pyright：MCP 源码 0 errors、0 warnings。
- MCP stdio：initialize/tools/list/tools/call 手动验证通过。
- Web：`npm ci && npm run build` 通过（TypeScript + Vite）。
- 浏览器现场检查：正常首页、月报、设置页、`?demo=empty` 空态、`?demo=error` 错误态均可渲染；移动宽度下导航和内容无明显溢出。
- 构建后已清理 `Web/node_modules`、`Web/dist`、TypeScript 临时文件和 MCP `__pycache__`。

## 未覆盖与下一步

- Build51 既有后端没有原子 import-batch 路由；HTTP adapter 未配置批次路径时明确返回 `batch_api_unavailable`，没有把一批账单拆成多笔 proposal。
- 尚未新增 `Backend/` 的批次表、service 或路由，尚未部署远程 MCP，也尚未把 Web mock adapter 切换成 live adapter。
- 下一步需要先确定后端批次接口是否纳入目标版本，再实现数据库迁移、批次 service、网页确认凭证和真实 MCP/HTTP 连接。

## 资源状态

- 本轮只保留源码、README、pyproject/package-lock、测试和计划记录。
- 未生成或保留生产数据库副本、真实密钥、账单原文、安装包或发布构建物。
