import type {
  AccessScope,
  BatchActionResult,
  BatchCommitInput,
  BatchValidation,
  CandidateTransaction,
  CashFlowItem,
  CashFlowOutlook,
  NamedOption,
  ExportRequest,
  ExportResult,
  FiscalApiAdapter,
  LedgerEntry,
  LedgerSearchQuery,
  MonthlyReport,
  PendingBatch,
} from "./types";

/**
 * The console's live boundary. A browser receives a key at construction time
 * only; this module never writes it to localStorage, cookies, or query strings.
 * The default app still uses the mock adapter.
 */
export type { FiscalApiAdapter } from "./types";

export class FiscalApiError extends Error {
  readonly code: string;
  readonly status?: number;

  constructor(code: string, message: string, status?: number) {
    super(message);
    this.name = "FiscalApiError";
    this.code = code;
    this.status = status;
  }
}

export interface HttpFiscalAdapterOptions {
  baseUrl: string;
  /** Ephemeral runtime value. Do not pass a Vite VITE_* secret. */
  apiKey?: string;
  batchPath?: string;
  scopes?: AccessScope[];
  fetchImpl?: typeof fetch;
}

export interface McpHttpAdapterOptions {
  endpoint: string;
  /** Ephemeral runtime value sent in JSON-RPC params._meta. */
  apiKey: string;
  /** Optional REST collection path until the MCP contract exposes listing. */
  batchListPath?: string;
  /** Origin/base URL for that optional REST collection route. */
  batchListBaseUrl?: string;
  scopes?: AccessScope[];
  fetchImpl?: typeof fetch;
}

type JsonObject = Record<string, unknown>;

const boundFetch: typeof fetch = (input, init) => globalThis.fetch(input, init);

const normalizeCredentialInput = (value: string): string =>
  value.trim().replace(/^Bearer\s+/i, "").replace(/^([\"'])(.*)\1$/, "$2").trim();

const looksLikeAccessKey = (value: string): boolean => value.startsWith("fiscal_ak_v1_");

const isObject = (value: unknown): value is JsonObject =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const stringValue = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value : undefined;

const numberValue = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;

const asArray = (value: unknown): unknown[] | undefined => (Array.isArray(value) ? value : undefined);

const dataRevision = (value: unknown, headers?: Headers): number | undefined => {
  const object = isObject(value) ? value : undefined;
  const meta = object && isObject(object.meta) ? object.meta : undefined;
  const candidates = [
    object?.data_revision,
    object?.dataRevision,
    object?.revision,
    meta?.data_revision,
    meta?.dataRevision,
    meta?.revision,
  ];
  for (const candidate of candidates) {
    if (typeof candidate === "number" && Number.isInteger(candidate) && candidate >= 0) return candidate;
    if (typeof candidate === "string" && /^\d+$/.test(candidate)) return Number(candidate);
  }
  for (const name of ["x-fiscal-data-revision", "x-data-revision", "x-fiscal-revision"]) {
    const valueFromHeader = headers?.get(name);
    if (valueFromHeader && /^\d+$/.test(valueFromHeader)) return Number(valueFromHeader);
  }
  return undefined;
};

const contractError = (message: string): FiscalApiError =>
  new FiscalApiError("backend_contract_mismatch", message);

const parseValidation = (value: unknown): BatchValidation | undefined => {
  if (!isObject(value)) return undefined;
  const duplicateValues = asArray(value.duplicates) ?? [];
  const missingValues = asArray(value.missing_fields) ?? asArray(value.missingFields) ?? [];
  const missingFields = missingValues.flatMap((item) => {
    if (!isObject(item)) return [];
    const clientId = stringValue(item.client_id) ?? stringValue(item.clientId);
    const fields = (asArray(item.fields) ?? []).filter((field): field is string => typeof field === "string");
    return clientId ? [{ clientId, fields }] : [];
  });
  return {
    duplicates: duplicateValues.filter((item): item is string => typeof item === "string"),
    missingFields,
    writableCount: numberValue(value.writable_count) ?? numberValue(value.writableCount),
    validatedAt: stringValue(value.validated_at) ?? stringValue(value.validatedAt),
  };
};

const parseBackendValidationErrors = (value: unknown): BatchValidation | undefined => {
  const errors = asArray(value);
  if (!errors) return undefined;
  return {
    duplicates: errors.flatMap((item) => (isObject(item) && stringValue(item.code) === "duplicate" && stringValue(item.client_id) ? [stringValue(item.client_id)!] : [])),
    missingFields: errors.flatMap((item) => {
      if (!isObject(item)) return [];
      const clientId = stringValue(item.client_id);
      const code = stringValue(item.code);
      return clientId && code ? [{ clientId, fields: [code] }] : [];
    }),
    writableCount: undefined,
  };
};

const normalizeCandidate = (value: unknown, index: number): CandidateTransaction => {
  if (!isObject(value)) throw contractError(`Candidate ${index + 1} is not an object.`);
  const date = stringValue(value.occurred_at) ?? stringValue(value.occurredAt) ?? stringValue(value.date);
  const merchant = stringValue(value.title) ?? stringValue(value.merchant) ?? stringValue(value.name);
  const amount = numberValue(value.amount_minor) ?? numberValue(value.amountMinor) ?? numberValue(value.amountCents);
  if (!date || !merchant || amount === undefined) {
    throw contractError(`Candidate ${index + 1} is missing date, title, or amount.`);
  }
  const confidenceBps = numberValue(value.overall_confidence_bps) ?? numberValue(value.overallConfidenceBps);
  const confidence = numberValue(value.confidence) ?? (confidenceBps === undefined ? 0 : confidenceBps / 10000);
  return {
    id: stringValue(value.client_id) ?? stringValue(value.clientId) ?? `candidate-${index + 1}`,
    date,
    merchant,
    category: stringValue(value.category) ?? stringValue(value.category_id) ?? stringValue(value.categoryId) ?? "待分类",
    account: stringValue(value.account) ?? stringValue(value.account_id) ?? stringValue(value.accountId) ?? "待选择账户",
    amountCents: amount,
    confidence: Math.max(0, Math.min(1, confidence)),
    note: stringValue(value.note),
  };
};

const normalizeBatch = (value: unknown): PendingBatch => {
  const source = isObject(value) && isObject(value.batch) ? value.batch : value;
  if (!isObject(source)) throw contractError("Fiscal batch response is not an object.");
  const candidates = asArray(source.candidates) ?? asArray(source.items) ?? [];
  const items = candidates.map(normalizeCandidate);
  const status = stringValue(source.status) ?? "pending";
  const validation = parseValidation(source.validation) ?? parseBackendValidationErrors(source.validation_errors);
  const uiStatus =
    status === "ignored"
      ? "ignored"
      : status === "validated" && validation && validation.duplicates.length === 0 && validation.missingFields.length === 0
        ? "ready"
        : "needs_review";
  const id = stringValue(source.batch_id) ?? stringValue(source.batchId) ?? stringValue(source.id);
  if (!id) throw contractError("Fiscal batch response is missing batch_id.");
  const total =
    numberValue(source.total_amount_minor) ??
    numberValue(source.totalAmountMinor) ??
    numberValue(source.totalAmountCents) ??
    items.reduce((sum, item) => sum + item.amountCents, 0);
  const itemCount = numberValue(source.item_count) ?? numberValue(source.itemCount) ?? items.length;
  const confidenceBps = numberValue(source.overall_confidence_bps) ?? numberValue(source.overallConfidenceBps);
  const confidence = numberValue(source.confidence) ?? (confidenceBps === undefined ? 0 : confidenceBps / 10000);
  return {
    id,
    title: stringValue(source.title) ?? stringValue(source.name) ?? `Fiscal 批次 ${id}`,
    receivedAt: stringValue(source.received_at) ?? stringValue(source.receivedAt) ?? stringValue(source.created_at) ?? new Date(0).toISOString(),
    source: stringValue(source.source) ?? "Agent",
    status: uiStatus,
    itemCount,
    totalAmountCents: total,
    confidence: Math.max(0, Math.min(1, confidence)),
    items,
    version: numberValue(source.version) ?? 0,
    dataRevision: dataRevision(value),
    validation,
  };
};

const normalizeBatchCollection = (value: unknown): PendingBatch[] => {
  const rows = Array.isArray(value)
    ? value
    : isObject(value)
      ? asArray(value.items) ?? asArray(value.batches)
      : undefined;
  if (!rows) throw contractError("Fiscal batch API returned no items collection.");
  return rows
    .filter((row) => {
      if (!isObject(row)) return true;
      const status = stringValue(row.status);
      return status !== "ignored" && status !== "committed";
    })
    .map(normalizeBatch);
};

/** Days counted for a month's daily average: all days for past months, days so far for the current one. */
const elapsedDays = (month: string, daysInMonth: number): number => {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  const today = parts.slice(0, 7);
  if (month < today) return daysInMonth;
  if (month > today) return 0;
  return Math.min(daysInMonth, Number(parts.slice(8, 10)));
};

const normalizeMonthlyReport = (value: unknown, requestedMonth: string): MonthlyReport => {
  if (!isObject(value)) throw contractError("Fiscal monthly report is not an object.");
  const summary = isObject(value.summary) ? value.summary : value;
  const meta = isObject(value.meta) ? value.meta : undefined;
  const categories = asArray(value.categoryBreakdown) ?? asArray(value.categories) ?? asArray(value.category_breakdown) ?? [];
  const categoryCount = categories.reduce<number>((sum, item) => sum + (isObject(item) ? numberValue(item.transaction_count) ?? numberValue(item.transactionCount) ?? 0 : 0), 0);
  const palette = ["#39785d", "#c9822b", "#4a72b0", "#a0527a", "#6d8f3a", "#8a6bbf", "#c4573f", "#3f8f99"];
  const rawBreakdown = categories.flatMap((item, index) => {
    if (!isObject(item)) return [];
    const category = stringValue(item.category) ?? stringValue(item.category_name) ?? stringValue(item.name) ?? `分类 ${index + 1}`;
    const amount = numberValue(item.amountCents) ?? numberValue(item.net_consumption_minor) ?? numberValue(item.amount_minor) ?? numberValue(item.amountMinor) ?? 0;
    return [{ category, amountCents: amount, percentage: numberValue(item.percentage), color: stringValue(item.color) ?? stringValue(item.color_hex) }];
  });
  const breakdownTotal = rawBreakdown.reduce((sum, item) => sum + Math.max(0, item.amountCents), 0);
  const categoryBreakdown = rawBreakdown
    .sort((left, right) => right.amountCents - left.amountCents)
    .map((item, index) => ({
      category: item.category,
      amountCents: item.amountCents,
      percentage: item.percentage ?? (breakdownTotal ? Math.round((Math.max(0, item.amountCents) / breakdownTotal) * 100) : 0),
      color: item.color ?? palette[index % palette.length],
    }));
  const total =
    numberValue(value.totalSpendCents) ??
    numberValue(summary.total_spend_minor) ??
    numberValue(summary.totalSpendMinor) ??
    numberValue(summary.net_consumption_minor) ??
    numberValue(value.total_spend_minor);
  const count = numberValue(value.transactionCount) ?? numberValue(summary.transaction_count) ?? numberValue(summary.transactionCount) ?? categoryCount;
  if (total === undefined || count === undefined) throw contractError("Fiscal monthly report is missing total or transaction count.");
  const trendValues = asArray(value.trend) ?? asArray(value.daily_trend) ?? asArray(value.daily) ?? [];
  const points = trendValues.flatMap((item) => {
    if (!isObject(item)) return [];
    return [{ label: stringValue(item.label) ?? stringValue(item.date) ?? "", amountCents: numberValue(item.amountCents) ?? numberValue(item.net_consumption_minor) ?? numberValue(item.amount_minor) ?? 0 }];
  });
  // Daily v2 points are grouped into 4-day buckets so a month fits the chart.
  const trend = points.length > 12
    ? Array.from({ length: Math.ceil(points.length / 4) }, (_, index) => {
        const bucket = points.slice(index * 4, index * 4 + 4);
        const day = Number(bucket[0].label.slice(8, 10)) || index * 4 + 1;
        return { label: `${day}日`, amountCents: bucket.reduce((sum, item) => sum + item.amountCents, 0) };
      })
    : points;
  const highlights = (asArray(value.highlights) ?? []).filter((item): item is string => typeof item === "string");
  return {
    month: stringValue(value.month) ?? stringValue(value.period) ?? stringValue(meta?.period) ?? requestedMonth,
    totalSpendCents: total,
    transactionCount: count,
    averageDailyCents: numberValue(value.averageDailyCents) ?? numberValue(summary.average_daily_minor) ?? (elapsedDays(requestedMonth, points.length) ? Math.round(total / elapsedDays(requestedMonth, points.length)) : 0),
    averageDays: elapsedDays(requestedMonth, points.length),
    categoryBreakdown,
    trend,
    highlights,
    dataRevision: dataRevision(value),
  };
};

const transactionSourceLabel: Record<string, LedgerEntry["source"]> = {
  manual: "手工录入",
  ai_text: "Agent 批次",
  ocr: "Agent 批次",
  cash_flow: "计划兑现",
};

const inflowKinds = new Set(["income", "reimbursement_receipt", "borrowing", "credit_fee_refund", "installment_refund"]);
const internalKinds = new Set(["transfer", "repayment", "credit_principal_waiver"]);

const ledgerSign = (kind?: string): 1 | -1 | 0 => (kind && inflowKinds.has(kind) ? 1 : kind && internalKinds.has(kind) ? 0 : -1);

const normalizeLedger = (value: unknown, names: NameMaps = emptyNames): LedgerEntry[] & { truncated?: boolean } => {
  const rows = Array.isArray(value) ? value : isObject(value) ? asArray(value.items) ?? asArray(value.transactions) : undefined;
  if (!rows) throw contractError("Fiscal ledger response returned no items collection.");
  return rows.flatMap((item, index) => {
    if (!isObject(item)) return [];
    const id = stringValue(item.id) ?? stringValue(item.transaction_id) ?? `transaction-${index + 1}`;
    // business_date is the Asia/Shanghai date; occurred_at is a UTC instant.
    const date = stringValue(item.business_date) ?? stringValue(item.date) ?? stringValue(item.occurred_at) ?? "";
    const amount = numberValue(item.amountCents) ?? numberValue(item.amount_minor) ?? 0;
    return [{
      id,
      date,
      merchant: stringValue(item.merchant) ?? stringValue(item.title) ?? "未命名交易",
      category: stringValue(item.category) ?? names.category(stringValue(item.category_id)) ?? "未分类",
      account: stringValue(item.account) ?? names.account(stringValue(item.account_id)) ?? "未指定账户",
      amountCents: amount,
      sign: ledgerSign(stringValue(item.kind)),
      status: item.voided_at ? "已撤销" : (stringValue(item.status) as LedgerEntry["status"]) ?? "已入账",
      source: transactionSourceLabel[stringValue(item.source) ?? ""] ?? (stringValue(item.source) as LedgerEntry["source"]) ?? "手工录入",
    }];
  });
};

interface NameMaps {
  account(id?: string): string | undefined;
  category(id?: string): string | undefined;
}

const emptyNames: NameMaps = { account: () => undefined, category: () => undefined };

const namesFrom = (accounts: unknown, categories: unknown): NameMaps => {
  const index = (value: unknown) => {
    const rows = Array.isArray(value) ? value : isObject(value) ? asArray(value.items) ?? [] : [];
    const map = new Map<string, string>();
    const visit = (row: unknown) => {
      if (!isObject(row)) return;
      const id = stringValue(row.id);
      const name = stringValue(row.name);
      if (id && name) map.set(id, name);
      (asArray(row.children) ?? []).forEach(visit);
    };
    rows.forEach(visit);
    return map;
  };
  const accountMap = index(accounts);
  const categoryMap = index(categories);
  return {
    account: (id) => (id ? accountMap.get(id) ?? undefined : undefined),
    category: (id) => (id ? categoryMap.get(id) ?? undefined : undefined),
  };
};

const cashFlowSourceLabel = (item: JsonObject): string => {
  const system = stringValue(item.system_kind);
  if (system === "credit_cycle") return "信用卡账期";
  if (system === "reimbursement") return "报销回款";
  return stringValue(item.source) === "ai_text" ? "Agent" : "手工计划";
};

const normalizeCashFlow = (value: unknown, names: NameMaps): CashFlowItem[] => {
  const rows = isObject(value) ? asArray(value.items) : asArray(value);
  if (!rows) throw contractError("Fiscal cash-flow response returned no items collection.");
  return rows.flatMap((item): CashFlowItem[] => {
    if (!isObject(item)) return [];
    const id = stringValue(item.id);
    const direction = stringValue(item.direction);
    if (!id || (direction !== "inflow" && direction !== "outflow" && direction !== "transfer")) return [];
    const planned = numberValue(item.planned_amount_minor) ?? 0;
    const remaining = numberValue(item.remaining_amount_minor);
    const status = stringValue(item.status) ?? "expected";
    const settled = numberValue(item.actual_amount_minor) ?? numberValue(item.settled_amount_minor);
    const shown = status === "settled" || status === "completed" ? settled || planned : remaining && remaining > 0 ? remaining : planned;
    return [{
      id,
      title: stringValue(item.title) ?? "未命名计划",
      direction,
      amountCents: shown,
      plannedCents: planned,
      expectedDate: stringValue(item.expected_date) ?? null,
      account: names.account(stringValue(item.account_id)) ?? (stringValue(item.account_id) ? "未知账户" : stringValue(item.system_kind) === "reimbursement" ? "回款时确定" : "未指定账户"),
      destinationAccount: names.account(stringValue(item.destination_account_id)),
      category: names.category(stringValue(item.category_id)),
      status: stringValue(item.status) ?? "expected",
      overdue: item.is_overdue === true,
      source: cashFlowSourceLabel(item),
      note: stringValue(item.note),
      actualDate: stringValue(item.actual_date) ?? null,
    }];
  }).sort((left, right) => (left.expectedDate ?? "9999").localeCompare(right.expectedDate ?? "9999"));
};

const normalizeOutlook = (value: unknown): CashFlowOutlook => {
  if (!isObject(value) || !isObject(value.disposable)) throw contractError("Fiscal cash-flow outlook is missing disposable facts.");
  const disposable = value.disposable;
  const cash = isObject(value.cash) ? value.cash : {};
  const required = (key: string) => {
    const found = numberValue(disposable[key]);
    if (found === undefined) throw contractError(`Fiscal cash-flow outlook is missing ${key}.`);
    return found;
  };
  return {
    dateFrom: stringValue(disposable.date_from) ?? "",
    dateTo: stringValue(disposable.date_to) ?? "",
    currentCashCents: numberValue(cash.current_balance_minor) ?? required("current_cash_minor"),
    expectedInflowCents: required("expected_inflow_minor"),
    expectedOutflowCents: required("expected_outflow_minor"),
    projectedBalanceCents: required("projected_balance_minor"),
    undatedInflowCents: numberValue(disposable.undated_inflow_minor) ?? 0,
    overdueOutflowCents: numberValue(disposable.overdue_outflow_minor) ?? 0,
    unscheduledCreditDebtCents: numberValue(disposable.unscheduled_credit_debt_minor) ?? 0,
    dataRevision: dataRevision(value),
  };
};

const categoryOptions = (value: unknown): NamedOption[] => {
  const rows = Array.isArray(value) ? value : isObject(value) ? asArray(value.items) ?? [] : [];
  const options: NamedOption[] = [];
  const visit = (row: unknown, prefix = "") => {
    if (!isObject(row)) return;
    const id = stringValue(row.id);
    const name = stringValue(row.name);
    if (id && name) options.push({ id, name: prefix ? `${prefix} / ${name}` : name });
    (asArray(row.children) ?? []).forEach((child) => visit(child, name ?? prefix));
  };
  rows.forEach((row) => visit(row));
  return options;
};

const monthRange = (month: string): { date_from: string; date_to: string } => {
  const lastDay = new Date(Date.UTC(Number(month.slice(0, 4)), Number(month.slice(5, 7)), 0)).getUTCDate();
  return { date_from: `${month}-01`, date_to: `${month}-${String(lastDay).padStart(2, "0")}` };
};

const toBase64 = (buffer: ArrayBuffer): string => {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
};

class HttpRequestClient {
  readonly baseUrl: string;
  private apiKey?: string;
  readonly batchPath?: string;
  readonly scopes: AccessScope[];
  private readonly fetchImpl: typeof fetch;
  private passphraseAttempted = false;

  constructor(options: HttpFiscalAdapterOptions) {
    this.baseUrl = options.baseUrl.replace(/\/$/, "");
    this.apiKey = options.apiKey ? normalizeCredentialInput(options.apiKey) : undefined;
    this.batchPath = options.batchPath?.replace(/\/$/, "");
    this.scopes = options.scopes ?? [];
    this.fetchImpl = options.fetchImpl ?? boundFetch;
  }

  private headers(): HeadersInit {
    return this.apiKey ? { Accept: "application/json", Authorization: `Bearer ${this.apiKey}` } : { Accept: "application/json" };
  }

  private async request(path: string, init: RequestInit = {}): Promise<Response> {
    const url = `${this.baseUrl}/${path.replace(/^\//, "")}`;
    const request = () => this.fetchImpl(url, {
      ...init,
      headers: { ...this.headers(), ...(init.headers ?? {}) },
    });
    let response = await request();
    if (response.status !== 401 || !this.apiKey || looksLikeAccessKey(this.apiKey) || this.passphraseAttempted) return response;

    this.passphraseAttempted = true;
    const sessionResponse = await this.fetchImpl(`${this.baseUrl}/auth/session`, {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ passphrase: this.apiKey }),
    });
    if (!sessionResponse.ok) return response;
    const sessionBody = (await sessionResponse.json()) as unknown;
    const minted = isObject(sessionBody) ? stringValue(sessionBody.access_key) : undefined;
    if (!minted) return response;
    this.apiKey = minted;
    response = await request();
    return response;
  }

  async json(path: string, init: RequestInit = {}): Promise<{ body: unknown; headers: Headers }> {
    const response = await this.request(path, init);
    const text = await response.text();
    let body: unknown = undefined;
    if (text) {
      try {
        body = JSON.parse(text);
      } catch {
        throw new FiscalApiError("backend_contract_mismatch", "Fiscal returned invalid JSON.", response.status);
      }
    }
    if (!response.ok) {
      const error = isObject(body) && isObject(body.error) ? body.error : body;
      const code = isObject(error) ? stringValue(error.code) ?? "backend_error" : "backend_error";
      const message = isObject(error) ? stringValue(error.message) ?? `Fiscal request failed (${response.status}).` : `Fiscal request failed (${response.status}).`;
      throw new FiscalApiError(code, message, response.status);
    }
    return { body, headers: response.headers };
  }

  async csv(path: string): Promise<{ bytes: ArrayBuffer; headers: Headers }> {
    const response = await this.request(path);
    if (!response.ok) throw new FiscalApiError("backend_error", `Fiscal export failed (${response.status}).`, response.status);
    return { bytes: await response.arrayBuffer(), headers: response.headers };
  }
}

const batchUnavailable = (): never => {
  throw new FiscalApiError("batch_api_unavailable", "Fiscal import-batch API is not configured for this console.");
};

export class HttpFiscalApiAdapter implements FiscalApiAdapter {
  private readonly client: HttpRequestClient;

  constructor(options: HttpFiscalAdapterOptions) {
    this.client = new HttpRequestClient(options);
  }

  private batchPath(): string {
    if (!this.client.batchPath) return batchUnavailable();
    return this.client.batchPath;
  }

  async listPendingBatches(): Promise<PendingBatch[]> {
    const response = await this.client.json(this.batchPath());
    return normalizeBatchCollection(response.body).filter((batch) => batch.status !== "ignored");
  }

  async getPendingBatch(batchId: string): Promise<PendingBatch> {
    const response = await this.client.json(`${this.batchPath()}/${encodeURIComponent(batchId)}`);
    return normalizeBatch(response.body);
  }

  async validateBatch(batchId: string, expectedVersion: number): Promise<PendingBatch> {
    const response = await this.client.json(`${this.batchPath()}/${encodeURIComponent(batchId)}/validate`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ expected_version: expectedVersion }),
    });
    return normalizeBatch(response.body);
  }

  async commitBatch(batchId: string, input: BatchCommitInput): Promise<BatchActionResult> {
    if (!input.confirmationToken.trim()) throw new FiscalApiError("confirmation_required", "请输入一次性确认凭证后再提交。");
    const response = await this.client.json(`${this.batchPath()}/${encodeURIComponent(batchId)}/commit`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Idempotency-Key": input.idempotencyKey },
      body: JSON.stringify({ expected_version: input.expectedVersion, confirmation_token: input.confirmationToken, idempotency_key: input.idempotencyKey }),
    });
    const raw = isObject(response.body) ? response.body : {};
    return {
      batch: normalizeBatch(raw.batch ?? raw),
      dataRevision: dataRevision(response.body, response.headers),
      transactions: asArray(raw.transactions),
      skipped: asArray(raw.skipped),
    };
  }

  async ignoreBatch(batchId: string, expectedVersion: number, reason?: string): Promise<PendingBatch> {
    const response = await this.client.json(`${this.batchPath()}/${encodeURIComponent(batchId)}/ignore`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ expected_version: expectedVersion, reason }),
    });
    return normalizeBatch(response.body);
  }

  async getMonthlyReport(month: string): Promise<MonthlyReport> {
    const response = await this.client.json(`/reports/v2/monthly/${encodeURIComponent(month)}`);
    return normalizeMonthlyReport(response.body, month);
  }

  private async names(): Promise<NameMaps> {
    const [accounts, categories] = await Promise.all([this.client.json("/accounts"), this.client.json("/categories")]);
    return namesFrom(accounts.body, categories.body);
  }

  async searchLedger(query: LedgerSearchQuery): Promise<LedgerEntry[]> {
    const params = new URLSearchParams();
    if (query.text.trim()) params.set("query", query.text.trim());
    if (query.category) params.set("category_id", query.category);
    if (query.month) {
      const range = monthRange(query.month);
      params.set("date_from", range.date_from);
      params.set("date_to", range.date_to);
    }
    const [response, names] = await Promise.all([this.client.json(`/transactions?${params.toString()}`), this.names()]);
    return normalizeLedger(response.body, names);
  }

  async listCashFlow(month?: string): Promise<CashFlowItem[]> {
    const path = month ? `/cash-flow-items/history?month=${encodeURIComponent(month)}` : "/cash-flow-items";
    const [response, names] = await Promise.all([this.client.json(path), this.names()]);
    return normalizeCashFlow(response.body, names);
  }

  async getCashFlowOutlook(windowDays = 30): Promise<CashFlowOutlook> {
    const response = await this.client.json(`/reports/facts?window_days=${windowDays}`);
    return normalizeOutlook(response.body);
  }

  async listCategories(): Promise<NamedOption[]> {
    return categoryOptions((await this.client.json("/categories")).body);
  }

  async listAccessScopes(): Promise<AccessScope[]> {
    return [...this.client.scopes];
  }

  async requestExport(request: ExportRequest): Promise<ExportResult> {
    if (request.format !== "csv") throw new FiscalApiError("unsupported_export", "Live Fiscal export currently supports CSV only.");
    const response = await this.client.csv(`/reports/v2/monthly/${encodeURIComponent(request.month)}/export.csv`);
    return {
      id: `export-${Date.now()}`,
      createdAt: new Date().toISOString(),
      format: "csv",
      month: request.month,
      status: "queued",
      dataRevision: dataRevision(undefined, response.headers),
      contentBase64: toBase64(response.bytes),
    };
  }
}

class McpToolClient {
  private nextId = 1;
  private readonly endpoint: string;
  private readonly authorization: () => string;
  private readonly meta?: JsonObject;
  private readonly fetchImpl: typeof fetch;
  private readonly onUnauthorized?: () => void;

  constructor(options: { endpoint: string; authorization: () => string; meta?: JsonObject; fetchImpl?: typeof fetch; onUnauthorized?: () => void }) {
    this.endpoint = options.endpoint;
    this.authorization = options.authorization;
    this.meta = options.meta;
    this.fetchImpl = options.fetchImpl ?? boundFetch;
    this.onUnauthorized = options.onUnauthorized;
  }

  async call(name: string, args: JsonObject): Promise<unknown> {
    const params: JsonObject = { name, arguments: Object.fromEntries(Object.entries(args).filter(([, value]) => value !== undefined)) };
    if (this.meta) params._meta = this.meta;
    const response = await this.fetchImpl(this.endpoint, {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json", Authorization: this.authorization() },
      body: JSON.stringify({ jsonrpc: "2.0", id: this.nextId++, method: "tools/call", params }),
    });
    const payload = (await response.json().catch(() => undefined)) as unknown;
    if (response.status === 401) {
      this.onUnauthorized?.();
      throw new FiscalApiError("session_expired", "登录已过期，请重新输入验证码。", 401);
    }
    if (!response.ok || !isObject(payload)) throw new FiscalApiError("backend_error", `MCP request failed (${response.status}).`, response.status);
    const result = isObject(payload.result) ? payload.result : undefined;
    const structured = result && result.structuredContent;
    if (result && result.isError && isObject(structured) && isObject(structured.error)) {
      throw new FiscalApiError(stringValue(structured.error.code) ?? "backend_error", stringValue(structured.error.message) ?? "MCP tool failed.");
    }
    if (payload.error) throw new FiscalApiError("mcp_protocol_error", "MCP transport returned a JSON-RPC error.");
    return structured;
  }
}

/** Shared read path for MCP-backed adapters: names, reports, ledger, cash flow and export. */
abstract class McpReadAdapter {
  protected abstract readonly client: McpToolClient;
  private nameCache?: Promise<NameMaps>;

  protected names(): Promise<NameMaps> {
    this.nameCache ??= Promise.all([
      this.client.call("fiscal_list_accounts", { include_archived: true }),
      this.client.call("fiscal_list_categories", { include_archived: true }),
    ]).then(([accounts, categories]) => namesFrom(accounts, categories)).catch((error: unknown) => {
      this.nameCache = undefined;
      throw error;
    });
    return this.nameCache;
  }

  async getMonthlyReport(month: string): Promise<MonthlyReport> { return normalizeMonthlyReport(await this.client.call("fiscal_get_monthly_report", { period: month }), month); }
  async searchLedger(query: LedgerSearchQuery): Promise<LedgerEntry[]> {
    const range = query.month ? monthRange(query.month) : {};
    const [result, names] = await Promise.all([
      this.client.call("fiscal_search_ledger", { query: query.text.trim() || undefined, category_id: query.category || undefined, ...range, limit: 100 }),
      this.names(),
    ]);
    const entries = normalizeLedger(result, names);
    entries.truncated = isObject(result) && Boolean(stringValue(result.next_cursor));
    return entries;
  }
  async listCashFlow(month?: string): Promise<CashFlowItem[]> {
    const [result, names] = await Promise.all([this.client.call("fiscal_list_cash_flow_items", { month }), this.names()]);
    return normalizeCashFlow(result, names);
  }
  async getCashFlowOutlook(windowDays = 30): Promise<CashFlowOutlook> { return normalizeOutlook(await this.client.call("fiscal_get_cash_flow_outlook", { window_days: windowDays })); }
  async listCategories(): Promise<NamedOption[]> { return categoryOptions(await this.client.call("fiscal_list_categories", {})); }
  async requestExport(request: ExportRequest): Promise<ExportResult> {
    if (request.format !== "csv") throw new FiscalApiError("unsupported_export", "Live Fiscal export currently supports CSV only.");
    const result = await this.client.call("fiscal_export_report", { period_kind: "month", period: request.month, format: "csv" });
    const raw = isObject(result) ? result : {};
    return { id: `export-${Date.now()}`, createdAt: new Date().toISOString(), format: "csv", month: request.month, status: "queued", dataRevision: dataRevision(result), contentBase64: stringValue(raw.content_base64) };
  }
}

/**
 * JSON-RPC MCP transport for the same Web boundary. The current MCP tool
 * contract intentionally has no list-batches tool; configure
 * batchListBaseUrl + batchListPath for the optional collection route, or the
 * adapter reports a precise feature error instead of guessing a tool name.
 */
export class McpHttpFiscalApiAdapter extends McpReadAdapter implements FiscalApiAdapter {
  protected readonly client: McpToolClient;
  private readonly listPath?: string;
  private readonly scopes: AccessScope[];
  private readonly rest?: HttpFiscalApiAdapter;

  constructor(options: McpHttpAdapterOptions) {
    super();
    this.client = new McpToolClient({
      endpoint: options.endpoint,
      authorization: () => `Bearer ${options.apiKey}`,
      meta: { fiscal_api_key: options.apiKey },
      fetchImpl: options.fetchImpl,
    });
    this.listPath = options.batchListPath;
    this.scopes = options.scopes ?? [];
    if (options.batchListPath && options.batchListBaseUrl) {
      this.rest = new HttpFiscalApiAdapter({ baseUrl: options.batchListBaseUrl, apiKey: options.apiKey, batchPath: options.batchListPath, scopes: options.scopes, fetchImpl: options.fetchImpl });
    }
  }

  async listPendingBatches(): Promise<PendingBatch[]> {
    if (!this.listPath || !this.rest) return batchUnavailable();
    return this.rest.listPendingBatches();
  }

  async getPendingBatch(batchId: string): Promise<PendingBatch> { return normalizeBatch(await this.client.call("fiscal_get_import_batch", { batch_id: batchId })); }
  async validateBatch(batchId: string, expectedVersion: number): Promise<PendingBatch> { return normalizeBatch(await this.client.call("fiscal_validate_import_batch", { batch_id: batchId, expected_version: expectedVersion })); }
  async commitBatch(batchId: string, input: BatchCommitInput): Promise<BatchActionResult> {
    if (!input.confirmationToken.trim()) throw new FiscalApiError("confirmation_required", "请输入一次性确认凭证后再提交。");
    const result = await this.client.call("fiscal_commit_import_batch", { batch_id: batchId, expected_version: input.expectedVersion, confirmation_token: input.confirmationToken, idempotency_key: input.idempotencyKey });
    const raw = isObject(result) ? result : {};
    return { batch: normalizeBatch(raw.batch ?? raw), dataRevision: dataRevision(result), transactions: asArray(raw.transactions), skipped: asArray(raw.skipped) };
  }
  async ignoreBatch(batchId: string, expectedVersion: number, reason?: string): Promise<PendingBatch> { return normalizeBatch(await this.client.call("fiscal_ignore_import_batch", { batch_id: batchId, expected_version: expectedVersion, reason })); }
  async listAccessScopes(): Promise<AccessScope[]> { return [...this.scopes]; }
}

export interface McpSessionAdapterOptions {
  endpoint: string;
  /** Returns the current panel session token; the adapter never stores it. */
  sessionToken: () => string;
  scopes: AccessScope[];
  onExpired: () => void;
  fetchImpl?: typeof fetch;
}

/**
 * Read-only owner panel over MCP with an Authenticator session. Import
 * batches stay with the Agent, so batch actions are deliberately unavailable.
 */
export class McpSessionFiscalApiAdapter extends McpReadAdapter implements FiscalApiAdapter {
  protected readonly client: McpToolClient;
  private readonly scopes: AccessScope[];

  constructor(options: McpSessionAdapterOptions) {
    super();
    this.scopes = options.scopes;
    this.client = new McpToolClient({
      endpoint: options.endpoint,
      authorization: () => `Session ${options.sessionToken()}`,
      fetchImpl: options.fetchImpl,
      onUnauthorized: options.onExpired,
    });
  }

  private readOnly(): never {
    throw new FiscalApiError("panel_read_only", "面板只读；批次由 Agent 处理。");
  }

  async listPendingBatches(): Promise<PendingBatch[]> { return this.readOnly(); }
  async getPendingBatch(): Promise<PendingBatch> { return this.readOnly(); }
  async validateBatch(): Promise<PendingBatch> { return this.readOnly(); }
  async commitBatch(): Promise<BatchActionResult> { return this.readOnly(); }
  async ignoreBatch(): Promise<PendingBatch> { return this.readOnly(); }
  async listAccessScopes(): Promise<AccessScope[]> { return [...this.scopes]; }
}

export function createHttpAdapter(options: HttpFiscalAdapterOptions): FiscalApiAdapter { return new HttpFiscalApiAdapter(options); }
export function createMcpHttpAdapter(options: McpHttpAdapterOptions): FiscalApiAdapter { return new McpHttpFiscalApiAdapter(options); }

/** Kept for phase-one callers that deliberately require explicit configuration. */
export function createApiAdapter(): FiscalApiAdapter {
  throw new Error("No live adapter is configured. Use createHttpAdapter() or createMcpHttpAdapter() with an ephemeral runtime key.");
}

