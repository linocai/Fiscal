// Host-provided, secret-free runtime configuration for console.fiscal.linotsai.top.
// The page prompts for the Fiscal access key and keeps it in memory only.
window.__FISCAL_RUNTIME_CONFIG__ = {
  mode: "http",
  baseUrl: "/api/v1",
  batchPath: "/import-batches",
  scopes: ["read:reports", "read:ledger", "stage:imports", "export:reports"],
};
