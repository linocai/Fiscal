import type {
  AccessScope,
  BatchActionResult,
  BatchCommitInput,
  ApiDemoMode,
  ExportRequest,
  ExportResult,
  FiscalApiAdapter,
  LedgerEntry,
  LedgerSearchQuery,
  MonthlyReport,
  PendingBatch,
} from "./types";

const wait = (milliseconds = 420) =>
  new Promise<void>((resolve) => window.setTimeout(resolve, milliseconds));

const scopes: AccessScope[] = ["read:reports", "read:ledger", "stage:imports", "export:reports"];

const batches: PendingBatch[] = [
  {
    id: "batch-20261009-01",
    title: "10 月第 2 周账单",
    receivedAt: "2026-10-09T21:14:00+08:00",
    source: "Agent · Claude Desktop",
    status: "needs_review",
    itemCount: 16,
    totalAmountCents: 2_486_50,
    confidence: 0.94,
    version: 1,
    items: [
      {
        id: "candidate-01",
        date: "2026-10-09",
        merchant: "盒马鲜生",
        category: "日常餐饮",
        account: "招商银行储蓄卡",
        amountCents: 18650,
        confidence: 0.99,
      },
      {
        id: "candidate-02",
        date: "2026-10-08",
        merchant: "滴滴出行",
        category: "交通",
        account: "微信支付",
        amountCents: 4200,
        confidence: 0.96,
      },
      {
        id: "candidate-03",
        date: "2026-10-07",
        merchant: "Apple Services",
        category: "订阅服务",
        account: "Apple Card",
        amountCents: 6800,
        confidence: 0.81,
        note: "商户名称已通过历史映射，建议复核分类。",
      },
    ],
  },
  {
    id: "batch-20261002-01",
    title: "10 月第 1 周账单",
    receivedAt: "2026-10-02T19:42:00+08:00",
    source: "Agent · ChatGPT",
    status: "ready",
    itemCount: 11,
    totalAmountCents: 1_762_00,
    confidence: 0.98,
    version: 1,
    items: [],
  },
];

const ledger: LedgerEntry[] = [
  { id: "tx-1001", date: "2026-10-09", merchant: "盒马鲜生", category: "日常餐饮", account: "招商银行储蓄卡", amountCents: 18650, status: "已入账", source: "Agent 批次" },
  { id: "tx-1002", date: "2026-10-08", merchant: "滴滴出行", category: "交通", account: "微信支付", amountCents: 4200, status: "已入账", source: "Agent 批次" },
  { id: "tx-1003", date: "2026-10-07", merchant: "Apple Services", category: "订阅服务", account: "Apple Card", amountCents: 6800, status: "待确认", source: "Agent 批次" },
  { id: "tx-1004", date: "2026-10-06", merchant: "山姆会员商店", category: "日常餐饮", account: "招商银行储蓄卡", amountCents: 32800, status: "已入账", source: "手工录入" },
  { id: "tx-1005", date: "2026-10-04", merchant: "深圳航空", category: "旅行", account: "Apple Card", amountCents: 128000, status: "已入账", source: "Agent 批次" },
  { id: "tx-1006", date: "2026-10-02", merchant: "小米有品", category: "居家", account: "微信支付", amountCents: 8990, status: "已撤销", source: "手工录入" },
  { id: "tx-1007", date: "2026-09-30", merchant: "星巴克", category: "日常餐饮", account: "微信支付", amountCents: 3600, status: "已入账", source: "Agent 批次" },
];

const report: MonthlyReport = {
  month: "2026-10",
  totalSpendCents: 12_860_50,
  transactionCount: 46,
  averageDailyCents: 4288_83,
  categoryBreakdown: [
    { category: "日常餐饮", amountCents: 3_840_00, percentage: 30, color: "#39785d" },
    { category: "旅行", amountCents: 3_210_00, percentage: 25, color: "#5e9e78" },
    { category: "居家", amountCents: 2_050_00, percentage: 16, color: "#d2a75b" },
    { category: "交通", amountCents: 1_540_00, percentage: 12, color: "#8e9c66" },
    { category: "订阅服务", amountCents: 1_120_00, percentage: 9, color: "#c7795e" },
    { category: "其他", amountCents: 1_100_50, percentage: 8, color: "#a9b6ad" },
  ],
  trend: [
    { label: "01", amountCents: 32000 },
    { label: "05", amountCents: 98000 },
    { label: "09", amountCents: 18650 },
    { label: "13", amountCents: 45000 },
    { label: "17", amountCents: 132000 },
    { label: "21", amountCents: 76400 },
    { label: "25", amountCents: 112500 },
    { label: "29", amountCents: 89000 },
  ],
  highlights: [
    "旅行支出占比 25%，主要来自深圳航空和酒店预订。",
    "本月有 1 笔待确认订阅，确认后会更新总额。",
    "日常餐饮比上月同期下降 8%。",
  ],
};

export class MockFiscalAdapter implements FiscalApiAdapter {
  constructor(private readonly mode: ApiDemoMode = "normal") {}

  private async respond<T>(value: T): Promise<T> {
    await wait();
    if (this.mode === "error") {
      throw new Error("Mock API 暂时不可用。请检查 MCP 连接后重试。");
    }
    return this.mode === "empty" ? ([] as T) : value;
  }

  listPendingBatches(): Promise<PendingBatch[]> {
    return this.respond(batches);
  }

  async getPendingBatch(batchId: string): Promise<PendingBatch> {
    const batch = batches.find((item) => item.id === batchId);
    if (!batch) throw new Error("Mock 批次不存在。");
    return this.respond(batch);
  }

  async validateBatch(batchId: string, expectedVersion: number): Promise<PendingBatch> {
    const batch = await this.getPendingBatch(batchId);
    if (expectedVersion !== batch.version) throw new Error("批次版本已变化，请重新加载。");
    return this.respond({
      ...batch,
      status: "ready",
      version: batch.version + 1,
      validation: { duplicates: [], missingFields: [], writableCount: batch.itemCount, validatedAt: new Date().toISOString() },
    });
  }

  async commitBatch(batchId: string, input: BatchCommitInput): Promise<BatchActionResult> {
    if (!input.confirmationToken.trim()) throw new Error("mock 确认需要一次性凭证。");
    const batch = await this.getPendingBatch(batchId);
    if (input.expectedVersion !== batch.version) throw new Error("批次版本已变化，请重新加载。");
    return this.respond({ batch: { ...batch, status: "ready", version: batch.version + 1 }, dataRevision: 2, transactions: [] });
  }

  async ignoreBatch(batchId: string, expectedVersion: number, _reason?: string): Promise<PendingBatch> {
    const batch = await this.getPendingBatch(batchId);
    if (expectedVersion !== batch.version) throw new Error("批次版本已变化，请重新加载。");
    return this.respond({ ...batch, status: "ignored", version: batch.version + 1 });
  }

  getMonthlyReport(month: string): Promise<MonthlyReport> {
    return this.respond({ ...report, month });
  }

  async searchLedger(query: LedgerSearchQuery): Promise<LedgerEntry[]> {
    const text = query.text.trim().toLowerCase();
    const result = ledger.filter((entry) => {
      const textMatch = !text || `${entry.merchant} ${entry.category} ${entry.account}`.toLowerCase().includes(text);
      const categoryMatch = !query.category || entry.category === query.category;
      const monthMatch = !query.month || entry.date.startsWith(query.month);
      return textMatch && categoryMatch && monthMatch;
    });
    return this.respond(result);
  }

  listAccessScopes(): Promise<AccessScope[]> {
    return this.respond(scopes);
  }

  async requestExport(request: ExportRequest): Promise<ExportResult> {
    await wait(280);
    if (this.mode === "error") {
      throw new Error("Mock 导出服务不可用，请稍后重试。");
    }
    return {
      id: `export-${Date.now()}`,
      createdAt: new Date().toISOString(),
      format: request.format,
      month: request.month,
      status: "queued",
    };
  }
}

export function createMockAdapter(mode: ApiDemoMode = "normal"): FiscalApiAdapter {
  return new MockFiscalAdapter(mode);
}
