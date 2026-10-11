# Fiscal Ledger Console

Fiscal Ledger Console 是 Agent-first 网页控制台。它只依赖 `FiscalApiAdapter`，默认使用本地 mock 数据；第二阶段提供可配置的 HTTP 和 JSON-RPC MCP adapter，不需要改页面组件。

公开的 Agent 接入说明位于 `/agent/`，机器可读 discovery 位于
`/.well-known/fiscal-agent.json`。这两份静态资源不包含密钥。Agent 通过
MCP 网关的 TOTP challenge 获取短期 Session；网页的 `/agent/approve/` 页面
只负责让用户输入当前 Google Authenticator 验证码。

## 本地运行

```bash
npm install
npm run dev
```

默认开发地址为 `http://localhost:4174`。生产构建使用：

```bash
npm run build
npm run preview
```

## 演示状态

页面支持通过查询参数检查状态分支：

- `/?demo=normal`：正常 mock 数据（默认）
- `/?demo=empty`：待确认、报告、账本为空，设置页展示未开启 scope
- `/?demo=error`：所有读取和导出请求显示错误与重试入口

## 页面范围

- **待确认**：查看 Agent 导入批次、候选记录和确认前预览。
- **月度报告**：按月份查看总支出、分类分布、趋势和复盘提示。
- **账本搜索**：按关键词、分类和月份查询已入账、待确认及已撤销记录。
- **设置 / 导出**：查看演示 scope，发起 CSV 或 Excel 导出任务，并显示 MCP 接入边界。

默认页面仍然使用 mock。静态部署通过 `public/runtime-config.js` 选择
`http` 或 `mcp` 模式；该文件只放地址、路径和 scope，不放密钥。HTTP/MCP
模式首次打开页面时会要求输入一次性会话密钥，密钥只留在当前页面内存中。
生产环境应在宿主机上覆盖这个文件，不要把真实值回写 Git：

```js
window.__FISCAL_RUNTIME_CONFIG__ = {
  mode: "http",
  baseUrl: "https://fiscal.example/api/v1",
  batchPath: "/import-batches",
  scopes: ["read:reports", "read:ledger", "stage:imports", "export:reports"],
};
```

MCP 模式还需要 `endpoint`，批次列表可按现有契约配置
`batchListBaseUrl` + `batchListPath`。模板见 `public/runtime-config.example.js`。

宿主也可以不走提示框，直接在页面加载前注入短期 `apiKey`；这个值只能
来自不入库的运行时注入，不能写进静态文件、Vite `VITE_*` 变量、URL、
localStorage 或 cookie。底层 adapter 仍可单独构造：

HTTP 模式的页面提示也接受 Fiscal 访问口令，并通过 `/auth/session` 换取当前页面内存中的
API key；MCP key 不能用于网页 REST 路由，粘贴 `Bearer ...` 时页面会自动去掉前缀。

```ts
import { createHttpAdapter, createMcpHttpAdapter } from "./src/api/adapter";

const http = createHttpAdapter({
  baseUrl: "https://fiscal.example/api/v1",
  batchPath: "/import-batches",
  scopes: ["read:reports", "read:ledger", "stage:imports", "export:reports"],
  apiKey: runtimeKey, // 只传入内存，不写 localStorage/cookie/URL
});

const mcp = createMcpHttpAdapter({
  endpoint: "https://fiscal.example/mcp",
  apiKey: runtimeKey,
  batchListBaseUrl: "https://fiscal.example/api/v1",
  batchListPath: "/import-batches", // 当前 MCP tool 契约没有 list 工具时的可选集合路由
});
```

HTTP adapter 对应 `/reports/v2/monthly/{period}`、`/transactions`、CSV 导出以及可选的
`/import-batches`、`/{id}/validate|commit|ignore` 路径。没有配置 `batchPath` 时，批次操作会返回
`batch_api_unavailable`，不会把一批记录拆成多次写入。MCP adapter 通过
`tools/call` 的 `params._meta.fiscal_api_key` 传递短期 key；批次列表需要显式配置
`batchListBaseUrl` + `batchListPath`，因为现有 MCP tool 契约没有擅自新增列表工具。

批次确认始终携带 `expected_version`、一次性 `confirmation_token` 和 `idempotency_key`。
适配器只读取后端明确返回的 `data_revision`（响应体或 `X-Fiscal-Data-Revision` 等已约定头），
缺失时返回 `undefined`，不会猜测版本。网页层不直接连接数据库，也不会保存真实密钥。

`npm run build` 生成的 `dist/` 是纯静态文件，可交给现有 Nginx、Caddy
或对象存储托管；API/MCP 地址必须允许该站点的 HTTPS/CORS 策略。网页
不会启动 MCP HTTP 服务，也不会直连数据库。

## 目录约定

- `src/App.tsx`：四个页面和页面级 loading / empty / error 状态。
- `src/api/types.ts`：网页与服务层之间的最小数据契约。
- `src/api/mockAdapter.ts`：可重复运行的本地 fixture，供视觉和交互验收。
- `src/api/adapter.ts`：HTTP 与 JSON-RPC MCP live adapter、字段归一化和清晰的 feature 错误边界。
- `src/styles.css`：桌面侧栏、内容卡片和移动端响应式布局。

