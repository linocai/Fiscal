// Deployment override for the static console. Keep this file secret-free.
// Replace the object on the hosting machine, or inject the same global before
// the module bundle loads. An HTTP/MCP mode prompts for an ephemeral key.
window.__FISCAL_RUNTIME_CONFIG__ = { mode: "mock" };
