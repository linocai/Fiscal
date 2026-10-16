export type ApiDemoMode = "normal" | "empty" | "error";

export type AccessScope =
  | "read:reports"
  | "read:ledger"
  | "stage:imports"
  | "commit:imports"
  | "export:reports";

export type PendingBatchStatus = "needs_review" | "ready" | "ignored";

export interface BatchValidation {
  duplicates: string[];
  missingFields: Array<{ clientId: string; fields: string[] }>;
  writableCount?: number;
  validatedAt?: string;
}

export interface CandidateTransaction {
  id: string;
  date: string;
  merchant: string;
  category: string;
  account: string;
  amountCents: number;
  confidence: number;
  note?: string;
}

export interface PendingBatch {
  id: string;
  title: string;
  receivedAt: string;
  source: string;
  status: PendingBatchStatus;
  itemCount: number;
  totalAmountCents: number;
  confidence: number;
  items: CandidateTransaction[];
  /** Optimistic concurrency version supplied by Fiscal. */
  version: number;
  dataRevision?: number;
  validation?: BatchValidation;
}

export interface CategoryBreakdown {
  category: string;
  amountCents: number;
  percentage: number;
  color: string;
}

export interface MonthlyReport {
  month: string;
  totalSpendCents: number;
  transactionCount: number;
  averageDailyCents: number;
  categoryBreakdown: CategoryBreakdown[];
  trend: Array<{ label: string; amountCents: number }>;
  highlights: string[];
  dataRevision?: number;
}

export interface LedgerEntry {
  id: string;
  date: string;
  merchant: string;
  category: string;
  account: string;
  amountCents: number;
  status: "已入账" | "待确认" | "已撤销";
  source: "Agent 批次" | "手工录入" | "计划兑现";
}

export interface LedgerSearchQuery {
  text: string;
  category: string;
  month: string;
}

export interface ExportRequest {
  month: string;
  format: "csv" | "xlsx";
}

export interface ExportResult {
  id: string;
  createdAt: string;
  format: "csv" | "xlsx";
  month: string;
  status: "queued";
  dataRevision?: number;
  /** Base64 content is only returned by an explicit live export request. */
  contentBase64?: string;
}

export interface BatchCommitInput {
  expectedVersion: number;
  confirmationToken: string;
  idempotencyKey: string;
}

export interface BatchActionResult {
  batch: PendingBatch;
  dataRevision?: number;
  transactions?: unknown[];
  skipped?: unknown[];
}

export type CashFlowDirection = "inflow" | "outflow" | "transfer";

export interface CashFlowItem {
  id: string;
  title: string;
  direction: CashFlowDirection;
  /** Amount still expected, in fen. */
  amountCents: number;
  plannedCents: number;
  expectedDate: string | null;
  account: string;
  destinationAccount?: string;
  category?: string;
  status: string;
  overdue: boolean;
  source: string;
  note?: string;
  actualDate?: string | null;
}

export interface CashFlowOutlook {
  dateFrom: string;
  dateTo: string;
  currentCashCents: number;
  expectedInflowCents: number;
  expectedOutflowCents: number;
  projectedBalanceCents: number;
  undatedInflowCents: number;
  overdueOutflowCents: number;
  unscheduledCreditDebtCents: number;
  dataRevision?: number;
}

export interface NamedOption {
  id: string;
  name: string;
}

export interface FiscalApiAdapter {
  listPendingBatches(): Promise<PendingBatch[]>;
  getPendingBatch(batchId: string): Promise<PendingBatch>;
  validateBatch(batchId: string, expectedVersion: number): Promise<PendingBatch>;
  commitBatch(batchId: string, input: BatchCommitInput): Promise<BatchActionResult>;
  ignoreBatch(batchId: string, expectedVersion: number, reason?: string): Promise<PendingBatch>;
  getMonthlyReport(month: string): Promise<MonthlyReport>;
  searchLedger(query: LedgerSearchQuery): Promise<LedgerEntry[]>;
  listAccessScopes(): Promise<AccessScope[]>;
  requestExport(request: ExportRequest): Promise<ExportResult>;
  /** Active plans, or settled/cancelled history for one YYYY-MM month. */
  listCashFlow(month?: string): Promise<CashFlowItem[]>;
  getCashFlowOutlook(windowDays?: number): Promise<CashFlowOutlook>;
  listCategories(): Promise<NamedOption[]>;
}
