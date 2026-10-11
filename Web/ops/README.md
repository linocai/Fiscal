# Fiscal Web Console on HZ

The console is a static build hosted on HZ. It uses same-origin `/api/v1`
requests; HZ Nginx forwards those requests over HTTPS to the Fiscal API on NB.
The browser never talks to PostgreSQL and no API key is stored in the static
bundle, URL, localStorage or cookie.

Public origin:

```text
https://console.fiscal.linotsai.top
```

The static site needs an A record to `118.178.122.194`, a Let's Encrypt
certificate, and the Nginx site in `nginx/fiscal-web.conf`. The production
runtime config is `runtime-config.production.js`; copy it to the deployed
`dist/runtime-config.js` after building. It is deliberately secret-free.

The console prompts for a Fiscal access key in the current page session. Start
with `read:reports,read:ledger,stage:imports,export:reports`; the current MCP
key is suitable for Agent requests, while the Web console uses the user's
Fiscal API access key for the proxied REST routes. The page's confirmation
button still requires the backend's one-time confirmation credential.
