// Copy this shape into the hosting layer's runtime-config.js.
// Never put apiKey here in a tracked or publicly served file.
window.__FISCAL_RUNTIME_CONFIG__ = {
  mode: "http", // "http" or "mcp"
  baseUrl: "https://fiscal.example/api/v1",
  endpoint: "https://fiscal.example/mcp", // required for mode: "mcp"
  batchPath: "/import-batches",
  batchListBaseUrl: "https://fiscal.example/api/v1",
  batchListPath: "/import-batches",
  scopes: ["read:reports", "read:ledger", "stage:imports", "export:reports"],
};
