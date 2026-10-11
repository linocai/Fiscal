import type { AccessScope, ApiDemoMode, FiscalApiAdapter } from "./api/types";
import { createHttpAdapter, createMcpHttpAdapter, FiscalApiError } from "./api/adapter";
import { createMockAdapter } from "./api/mockAdapter";

export type FiscalRuntimeMode = "mock" | "http" | "mcp";

export interface FiscalRuntimeConfig {
  mode: FiscalRuntimeMode;
  /** API root including /api/v1 when mode is http or mcp batch listing is used. */
  baseUrl?: string;
  /** JSON-RPC MCP endpoint when mode is mcp. */
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
}

let sessionKey: string | undefined;

function config(): FiscalRuntimeConfig | undefined {
  const value = window.__FISCAL_RUNTIME_CONFIG__;
  if (!value || value.mode === "mock") return undefined;
  return value;
}

function ephemeralKey(runtime: FiscalRuntimeConfig): string {
  const injected = runtime.apiKey?.trim();
  if (injected) {
    sessionKey = injected;
    return injected;
  }
  if (sessionKey) return sessionKey;
  const entered = window.prompt("请输入本次 Fiscal 会话密钥（只驻留当前页面内存）")?.trim();
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
  };
}

export function createRuntimeAdapter(demoMode: ApiDemoMode): RuntimeAdapter {
  if (demoMode !== "normal") return { adapter: createMockAdapter(demoMode), label: "Mock 环境" };
  const runtime = config();
  if (!runtime) return { adapter: createMockAdapter(demoMode), label: "Mock 环境" };

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
