# Fiscal Web 控制台上线记录

日期：2026-10-11（Asia/Shanghai）  
状态：Web 控制台已完成 HZ HTTPS 部署；真实浏览器业务验收和多终端账单闭环待用户执行。

## 本轮范围

- 保持原生 App 冻结，不改 App 业务源码、NB 数据库或现有 Fiscal API 业务规则。
- 构建 `Web/` 静态控制台，宿主覆盖 secret-free `runtime-config.js`，使用 HTTP adapter 访问同源 `/api/v1`。
- HZ Nginx 承载静态文件，并将 `/api/` 通过 HTTPS、SNI 和原始 Authorization 头转发到 NB 的 `fiscal.linotsai.top`。
- 先安装 HTTP-01 challenge 入口，待 DNS 指向 HZ 后签发 Let's Encrypt 证书，再启用完整 HTTPS site。

## 已完成

- `npm ci --no-audit --no-fund && npm run build` 通过；Vite 生成 `index.html`、CSS 和 JS 生产包。
- HZ 发布目录：`/opt/fiscal-web/releases/20261011-web-0e4f1d18`；`/opt/fiscal-web/current` 已指向该版本。
- 发布包 SHA-256：`0e4f1d18fb33c7dcf2167e27ec3a1c83701f16d92206d0bffedca52b6e5ee4ba`。
- 运行时配置只包含 `mode=http`、同源 `baseUrl=/api/v1`、批次路径和 scopes，不包含 Fiscal API key；网页仍在当前会话内存中提示并保存用户输入的 access key。
- `/etc/nginx/sites-available/fiscal-web.conf` 已启用；证书签发后已移除 `fiscal-web-acme`，`nginx -t`、reload 和 HTTPS 直连验证通过。
- Certbot deploy hook 已安装为 `/etc/letsencrypt/renewal-hooks/deploy/50-fiscal-web-nginx-reload`，证书签发后续自动 reload Nginx。
- `console.fiscal.linotsai.top` A 记录已解析到 `118.178.122.194`；Let's Encrypt 证书有效至 2027-01-09；HTTPS site 已启用，HTTP 自动跳转 HTTPS。
- 公网 smoke：HTTP 301、首页 200、`runtime-config.js` 200 且无 secret、未认证 `/api/v1/auth/status` 401；带真实 Fiscal access key 的 `/auth/status` 和 `/transactions?limit=1` 均 200。

## 待收口

1. 用户打开 `https://console.fiscal.linotsai.top/`，输入 Fiscal API access key，验证待确认、月报、账本搜索、设置/导出四个入口。
2. 用户用真实一周账单完成 Agent 暂存、校验、网页确认或忽略，以及重复请求验证；通过后再决定是否授予 `commit:imports`。

## 2026-10-11 fetch 上下文热修

- 用户截图复现网页加载失败：`Failed to execute 'fetch' on 'Window': Illegal invocation`。
- 根因是浏览器原生 `fetch` 作为未绑定函数保存到 HTTP/MCP adapter 后调用，丢失 `Window` 上下文；数据库、access key 和 Nginx 代理均不是本次错误来源。
- `Web/src/api/adapter.ts` 改为通过 `globalThis.fetch(input, init)` 的包装函数作为默认实现，HTTP 与 MCP 两个 adapter 同时修复；`npm ci --no-audit --no-fund && npm run build` 通过。
- 新静态包已部署到 HZ `/opt/fiscal-web/releases/20261011-web-4bb08594`，`/opt/fiscal-web/current` 已原子切换；包 SHA-256 为 `4bb0859497aab5fe5dd3b36a1d22129abd1bc1b8345e1dcd78af6cfb79a48094`。
- 公网 smoke：首页 200、`runtime-config.js` 200 且无 secret、未认证 auth 401；使用 Keychain access key 的 auth/status、import-batches 和 transactions 均 200。

## 2026-10-11 凭证入口修正

- 用户刷新后已越过前端 `fetch` 错误，但页面显示 `The access key is invalid or has been revoked`。当前有效 Keychain 个人 key 访问同一公网 `/auth/status` 返回 200，故后端、Nginx 和数据库连接正常；截图中的输入凭证不是当前有效的个人 REST key，或使用了 MCP key/旧 key/访问口令。
- HTTP Web adapter 现在会规范化可选的 `Bearer ` 前缀；输入非 `fiscal_ak_v1_...` 形式的凭证时，首次 401 会尝试通过同源 `/auth/session` 将 Fiscal 访问口令换成本页内存中的个人 API key。MCP key 仍不会用于 REST 路由。
- 新静态包已部署到 HZ `/opt/fiscal-web/releases/20261011-web-935c2b3b`，包 SHA-256 为 `935c2b3bd3628b317d175af1e3bcb3210c1c371b626893a9ede7ca77e3975034`；公网首页、运行时配置、认证和批次接口 smoke 通过。

## 边界

- HZ 只保存静态 Web 发布物和 Nginx 配置，不保存账本数据库。
- Web 使用 Fiscal API access key；HTTP 页面也可用访问口令换取本页内存中的 API key，MCP key 不能直接作为网页 REST access key。批次确认按钮仍要求后端一次性 confirmation credential，Agent MCP key 的 scopes 不因此扩大。
