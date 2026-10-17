import type { AccessScope, ApiDemoMode, FiscalApiAdapter } from "./api/types";
import { createHttpAdapter, createMcpHttpAdapter, FiscalApiError, McpSessionFiscalApiAdapter } from "./api/adapter";
import { createMockAdapter } from "./api/mockAdapter";
import { PANEL_SCOPES, PanelSession } from "./api/session";

/** `session` is the owner panel: Authenticator login, read-only MCP tools. */
export type FiscalRuntimeMode = "mock" | "http" | "mcp" | "session";

export interface FiscalRuntimeConfig {
  mode: FiscalRuntimeMode;
  /** API root including /api/v1 when mode is http or mcp batch listing is used. */
  baseUrl?: string;
  /** JSON-RPC MCP endpoint when mode is mcp or session. */
  endpoint?: string;
  batchPath?: string;
  batchListBaseUrl?: string;
  batchListPath?: string;
  scopes?: AccessScope[];
  /** Optional host-injected, ephemeral key. Never put this in a tracked file. */
  apiKey?: string;
}

declare global {
  interface Window {
    __FISCAL_RUNTIME_CONFIG__?: FiscalRuntimeConfig;
  }
}

export interface RuntimeAdapter {
  adapter: FiscalApiAdapter;
  label: string;
  /** Present in session mode; the app shows the login gate until it has a token. */
  session?: PanelSession;
}

let sessionKey: string | undefined;

function config(): FiscalRuntimeConfig | undefined {
  const value = window.__FISCAL_RUNTIME_CONFIG__;
  if (!value || value.mode === "mock") return undefined;
  return value;
}

export function hasLiveRuntimeConfig(): boolean {
  return config() !== undefined;
}

function ephemeralKey(runtime: FiscalRuntimeConfig): string {
  const injected = runtime.apiKey?.trim();
  if (injected) {
    sessionKey = injected;
    return injected;
  }
  if (sessionKey) return sessionKey;
  const prompt = runtime.mode === "http"
    ? "请输入 Fiscal API access key（fiscal_ak_v1_...）；也可输入 Fiscal 访问口令。不要输入 MCP key 或 Bearer 前缀。"
    : "请输入本次 Fiscal MCP 会话密钥（只驻留当前页面内存）";
  const entered = window.prompt(prompt)?.trim();
  if (!entered) throw new FiscalApiError("configuration_missing", "没有提供本次会话密钥。");
  sessionKey = entered;
  return entered;
}

function unavailable(message: string): FiscalApiAdapter {
  const fail = async (): Promise<never> => {
    throw new FiscalApiError("configuration_missing", message);
  };
  return {
    listPendingBatches: fail,
    getPendingBatch: fail,
    validateBatch: fail,
    commitBatch: fail,
    ignoreBatch: fail,
    getMonthlyReport: fail,
    searchLedger: fail,
    listAccessScopes: fail,
    requestExport: fail,
    listCashFlow: fail,
    getCashFlowOutlook: fail,
    listCategories: fail,
    listAccounts: fail,
  };
}

export function createRuntimeAdapter(demoMode: ApiDemoMode, onExpired: () => void = () => undefined): RuntimeAdapter {
  if (demoMode !== "normal") return { adapter: createMockAdapter(demoMode), label: "Mock 环境" };
  const runtime = config();
  if (!runtime) return { adapter: createMockAdapter(demoMode), label: "Mock 环境" };

  if (runtime.mode === "session") {
    if (!runtime.endpoint) return { adapter: unavailable("面板模式缺少 endpoint。"), label: "配置待完成" };
    const session = new PanelSession(new URL(runtime.endpoint).origin);
    const adapter = new McpSessionFiscalApiAdapter({
      endpoint: runtime.endpoint,
      sessionToken: () => session.token() ?? "",
      scopes: PANEL_SCOPES,
      onExpired: () => {
        session.clear();
        onExpired();
      },
    });
    return { adapter, label: "只读面板", session };
  }

  try {
    const apiKey = ephemeralKey(runtime);
    if (runtime.mode === "http") {
      if (!runtime.baseUrl) throw new FiscalApiError("configuration_missing", "HTTP 模式缺少 baseUrl。");
      return {
        adapter: createHttpAdapter({
          baseUrl: runtime.baseUrl,
          apiKey,
          batchPath: runtime.batchPath,
          scopes: runtime.scopes,
        }),
        label: "Fiscal API",
      };
    }
    if (!runtime.endpoint) throw new FiscalApiError("configuration_missing", "MCP 模式缺少 endpoint。");
    return {
      adapter: createMcpHttpAdapter({
        endpoint: runtime.endpoint,
        apiKey,
        batchListBaseUrl: runtime.batchListBaseUrl ?? runtime.baseUrl,
        batchListPath: runtime.batchListPath ?? runtime.batchPath,
        scopes: runtime.scopes,
      }),
      label: "MCP 会话",
    };
  } catch (reason) {
    const message = reason instanceof Error ? reason.message : "运行时配置不完整。";
    return { adapter: unavailable(message), label: "配置待完成" };
  }
}
