import { useCallback, useEffect, useMemo, useState } from "react";
import type {
  AccessScope,
  ApiDemoMode,
  FiscalApiAdapter,
  LedgerEntry,
  MonthlyReport,
  PendingBatch,
} from "./api/types";
import { createRuntimeAdapter } from "./runtimeConfig";

type ViewId = "inbox" | "reports" | "ledger" | "settings";

const navItems: Array<{ id: ViewId; label: string; description: string; icon: string }> = [
  { id: "inbox", label: "待确认", description: "Agent 导入批次", icon: "⌁" },
  { id: "reports", label: "月度报告", description: "查看消费分布", icon: "◒" },
  { id: "ledger", label: "账本搜索", description: "查找历史记录", icon: "⌕" },
  { id: "settings", label: "设置 / 导出", description: "连接与数据管理", icon: "⚙" },
];

const money = new Intl.NumberFormat("zh-CN", {
  style: "currency",
  currency: "CNY",
  minimumFractionDigits: 2,
});

const amount = (cents: number) => money.format(cents / 100);

const dateText = (value: string) =>
  new Intl.DateTimeFormat("zh-CN", { month: "short", day: "numeric" }).format(new Date(value));

const fullDateText = (value: string) =>
  new Intl.DateTimeFormat("zh-CN", { year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(value));

function LoadingBlock({ lines = 3 }: { lines?: number }) {
  return (
    <div className="loading-stack" aria-label="正在加载">
      {Array.from({ length: lines }, (_, index) => (
        <div className="skeleton-row" key={index}>
          <span className="skeleton skeleton-avatar" />
          <span className="skeleton skeleton-copy" />
          <span className="skeleton skeleton-value" />
        </div>
      ))}
    </div>
  );
}

function ErrorState({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div className="state-card state-error" role="alert">
      <span className="state-icon">!</span>
      <div>
        <strong>暂时无法读取 Fiscal</strong>
        <p>{message}</p>
        <button className="button button-secondary" onClick={onRetry}>重试</button>
      </div>
    </div>
  );
}

function EmptyState({ title, detail }: { title: string; detail: string }) {
  return (
    <div className="state-card state-empty">
      <span className="state-icon">○</span>
      <div>
        <strong>{title}</strong>
        <p>{detail}</p>
      </div>
    </div>
  );
}

function ProgressBar({ value, color }: { value: number; color: string }) {
  return (
    <div className="progress-track" aria-hidden="true">
      <span style={{ width: `${Math.min(100, value)}%`, background: color }} />
    </div>
  );
}

function InboxView({ api, onToast, environmentLabel }: { api: FiscalApiAdapter; onToast: (text: string) => void; environmentLabel: string }) {
  const [batches, setBatches] = useState<PendingBatch[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<PendingBatch | null>(null);
  const [reviewed, setReviewed] = useState<string[]>([]);
  const [working, setWorking] = useState(false);

  const load = useCallback(() => {
    setError(null);
    setBatches(null);
    api.listPendingBatches().then(setBatches).catch((reason: Error) => setError(reason.message));
  }, [api]);

  useEffect(() => { load(); }, [load]);

  if (error) return <ErrorState message={error} onRetry={load} />;
  if (!batches) return <LoadingBlock lines={3} />;

  const visibleBatches = batches.filter((batch) => batch.status !== "ignored" && !reviewed.includes(batch.id));

  const openBatch = async (batch: PendingBatch) => {
    setWorking(true);
    try {
      setSelected(await api.getPendingBatch(batch.id));
    } catch (reason) {
      onToast((reason as Error).message);
    } finally {
      setWorking(false);
    }
  };

  const validateSelected = async () => {
    if (!selected) return;
    setWorking(true);
    try {
      const next = await api.validateBatch(selected.id, selected.version);
      setSelected(next);
      onToast("批次校验完成，请确认没有重复或缺失字段。");
    } catch (reason) {
      onToast((reason as Error).message);
    } finally {
      setWorking(false);
    }
  };

  const commitSelected = async () => {
    if (!selected) return;
    const confirmationToken = window.prompt("请输入一次性确认凭证（不会被 Fiscal 保存）")?.trim();
    if (!confirmationToken) return;
    setWorking(true);
    try {
      await api.commitBatch(selected.id, {
        expectedVersion: selected.version,
        confirmationToken,
        idempotencyKey: `web-commit-${selected.id}-${selected.version}`,
      });
      setReviewed((ids) => [...ids, selected.id]);
      setSelected(null);
      onToast("批次已提交，月报和账本会使用新的 data_revision。");
    } catch (reason) {
      onToast((reason as Error).message);
    } finally {
      setWorking(false);
    }
  };

  const ignoreSelected = async () => {
    if (!selected) return;
    setWorking(true);
    try {
      await api.ignoreBatch(selected.id, selected.version, "web_console");
      setReviewed((ids) => [...ids, selected.id]);
      setSelected(null);
      onToast("批次已忽略，原始来源和审计记录仍会保留。");
    } catch (reason) {
      onToast((reason as Error).message);
    } finally {
      setWorking(false);
    }
  };
  return (
    <div className="page-stack">
      <section className="intro-row">
        <div>
          <p className="eyebrow">INBOX / AGENT IMPORTS</p>
          <h2>把一周账单，变成一次确认</h2>
          <p className="muted">Agent 先整理候选记录，确认后才会进入账本。候选批次不会绕过确认直接写入。</p>
        </div>
        <div className="intro-action">
          <span className="connection-dot" /> {environmentLabel}
        </div>
      </section>

      <section className="metric-grid metric-grid-three">
        <div className="metric-card"><span className="metric-label">待处理批次</span><strong>{visibleBatches.length}</strong><span className="metric-foot">最近 14 天</span></div>
        <div className="metric-card"><span className="metric-label">候选记录</span><strong>{visibleBatches.reduce((sum, batch) => sum + batch.itemCount, 0)}</strong><span className="metric-foot">需要人工确认</span></div>
        <div className="metric-card"><span className="metric-label">平均识别置信度</span><strong>{visibleBatches.length ? `${Math.round(visibleBatches.reduce((sum, batch) => sum + batch.confidence, 0) / visibleBatches.length * 100)}%` : "—"}</strong><span className="metric-foot">来自 Agent 提案</span></div>
      </section>

      {visibleBatches.length === 0 ? (
        <EmptyState title="没有待确认批次" detail="把最近一周的账单交给 Agent 后，它们会出现在这里。" />
      ) : (
        <section className="content-card">
          <div className="card-heading">
            <div><h3>最近导入</h3><p className="muted">批次级确认会保留原始来源和变更记录。</p></div>
            <span className="quiet-badge">只读预览</span>
          </div>
          <div className="batch-list">
            {visibleBatches.map((batch) => (
              <article className="batch-row" key={batch.id}>
                <div className="batch-mark">{batch.status === "ready" ? "✓" : "↗"}</div>
                <div className="batch-main">
                  <div className="row-title"><strong>{batch.title}</strong><span className={`status-pill status-${batch.status}`}>{batch.status === "ready" ? "可提交" : "需要复核"}</span></div>
                  <p className="muted">{batch.source} · {dateText(batch.receivedAt)} · {batch.itemCount} 笔候选</p>
                </div>
                <div className="batch-amount"><strong>{amount(batch.totalAmountCents)}</strong><span className="muted">置信度 {Math.round(batch.confidence * 100)}%</span></div>
                <button className="button button-secondary button-small" onClick={() => void openBatch(batch)} disabled={working}>查看批次</button>
              </article>
            ))}
          </div>
        </section>
      )}

      <div className="info-strip"><span>ⓘ</span><p>第一阶段只展示批次和确认前预览。连接真实 MCP 后，提交按钮会遵循 access scope 与版本校验。</p></div>

      {selected && (
        <div className="drawer-backdrop" role="presentation" onClick={() => setSelected(null)}>
          <aside className="drawer" role="dialog" aria-modal="true" aria-label="批次详情" onClick={(event) => event.stopPropagation()}>
            <div className="drawer-heading"><div><p className="eyebrow">IMPORT BATCH</p><h3>{selected.title}</h3></div><button className="icon-button" onClick={() => setSelected(null)} aria-label="关闭">×</button></div>
            <div className="drawer-meta"><span>{selected.source}</span><span>{selected.itemCount} 笔候选</span><span>{amount(selected.totalAmountCents)}</span></div>
            {selected.items.length === 0 ? <EmptyState title="批次内容已就绪" detail="当前响应没有逐笔候选；完成后端接入后可在这里查看校验结果。" /> : (
              <div className="candidate-list">{selected.items.map((item) => <div className="candidate-row" key={item.id}><div><strong>{item.merchant}</strong><p className="muted">{fullDateText(item.date)} · {item.category} · {item.account}</p>{item.note && <p className="candidate-note">{item.note}</p>}</div><div className="candidate-amount"><strong>{amount(item.amountCents)}</strong><span>{Math.round(item.confidence * 100)}%</span></div></div>)}</div>
            )}
            <div className="drawer-footer"><button className="button button-secondary" onClick={() => void validateSelected()} disabled={working || selected.status === "ready"}>校验批次</button><button className="button button-primary" onClick={() => void commitSelected()} disabled={working || selected.status !== "ready"}>确认入账</button><button className="button button-secondary" onClick={() => void ignoreSelected()} disabled={working}>忽略</button></div>
          </aside>
        </div>
      )}
    </div>
  );
}

function ReportView({ api }: { api: FiscalApiAdapter }) {
  const [month, setMonth] = useState("2026-10");
  const [report, setReport] = useState<MonthlyReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(() => {
    setError(null); setReport(null);
    api.getMonthlyReport(month).then(setReport).catch((reason: Error) => setError(reason.message));
  }, [api, month]);
  useEffect(() => { load(); }, [load]);

  if (error) return <ErrorState message={error} onRetry={load} />;
  if (!report) return <LoadingBlock lines={4} />;
  // The empty demo adapter intentionally returns an empty payload. Keep the
  // report shell usable in that state instead of trying to render chart data
  // that is not present yet.
  if (!Array.isArray(report.categoryBreakdown) || report.transactionCount === 0) {
    return (
      <div className="page-stack">
        <section className="intro-row">
          <div>
            <p className="eyebrow">REPORTS / MONTHLY REVIEW</p>
            <h2>看清这个月的钱去了哪里</h2>
            <p className="muted">报告由账本事实生成，待确认批次不会偷偷混入统计。</p>
          </div>
          <label className="month-picker"><span>报告月份</span><input type="month" value={month} onChange={(event) => setMonth(event.target.value)} /></label>
        </section>
        <EmptyState title="这个月还没有已入账记录" detail="完成一批账单确认后，分类分布和每日趋势会显示在这里。" />
      </div>
    );
  }
  const maxTrend = Math.max(...report.trend.map((item) => item.amountCents), 1);
  return (
    <div className="page-stack">
      <section className="intro-row"><div><p className="eyebrow">REPORTS / MONTHLY REVIEW</p><h2>看清这个月的钱去了哪里</h2><p className="muted">报告由账本事实生成，待确认批次不会偷偷混入统计。</p></div><label className="month-picker"><span>报告月份</span><input type="month" value={month} onChange={(event) => setMonth(event.target.value)} /></label></section>
      <section className="metric-grid metric-grid-three"><div className="metric-card metric-card-accent"><span className="metric-label">本月总支出</span><strong>{amount(report.totalSpendCents)}</strong><span className="metric-foot">{report.month.replace("-", "年")}月 · 已入账</span></div><div className="metric-card"><span className="metric-label">入账笔数</span><strong>{report.transactionCount}</strong><span className="metric-foot">平均每天 {amount(report.averageDailyCents)}</span></div><div className="metric-card"><span className="metric-label">最大分类</span><strong>{report.categoryBreakdown[0]?.category ?? "—"}</strong><span className="metric-foot">占比 {report.categoryBreakdown[0]?.percentage ?? 0}%</span></div></section>
      <section className="report-grid"><div className="content-card"><div className="card-heading"><div><h3>分类分布</h3><p className="muted">按已入账金额计算</p></div><span className="quiet-badge">{report.categoryBreakdown.length} 个分类</span></div><div className="category-list">{report.categoryBreakdown.map((item) => <div className="category-row" key={item.category}><div className="category-label"><span className="category-dot" style={{ background: item.color }} />{item.category}<strong>{amount(item.amountCents)}</strong></div><ProgressBar value={item.percentage} color={item.color} /><span className="category-percent">{item.percentage}%</span></div>)}</div></div><div className="content-card"><div className="card-heading"><div><h3>每日趋势</h3><p className="muted">每 4 天取一个观测点</p></div></div><div className="trend-chart">{report.trend.map((item) => <div className="trend-column" key={item.label}><div className="trend-bar-wrap"><span className="trend-bar" style={{ height: `${Math.max(8, item.amountCents / maxTrend * 100)}%` }} /></div><span>{item.label}</span></div>)}</div></div></section>
      <section className="content-card highlights"><div className="card-heading"><div><h3>本月观察</h3><p className="muted">给月底复盘留下三条可行动线索</p></div></div>{report.highlights.map((highlight) => <div className="highlight-row" key={highlight}><span>↗</span><p>{highlight}</p></div>)}</section>
    </div>
  );
}

function LedgerView({ api }: { api: FiscalApiAdapter }) {
  const [text, setText] = useState("");
  const [category, setCategory] = useState("");
  const [month, setMonth] = useState("2026-10");
  const [query, setQuery] = useState({ text: "", category: "", month: "2026-10" });
  const [entries, setEntries] = useState<LedgerEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(() => { setError(null); setEntries(null); api.searchLedger(query).then(setEntries).catch((reason: Error) => setError(reason.message)); }, [api, query]);
  useEffect(() => { load(); }, [load]);
  const submit = (event: React.FormEvent) => { event.preventDefault(); setQuery({ text, category, month }); };
  if (error) return <ErrorState message={error} onRetry={load} />;
  return <div className="page-stack"><section className="intro-row"><div><p className="eyebrow">LEDGER / SEARCH</p><h2>需要追溯时，再打开账本</h2><p className="muted">搜索结果来自账本服务，Agent 批次、手工录入和计划兑现保持原始来源。</p></div></section><form className="search-toolbar" onSubmit={submit}><label className="search-input"><span>⌕</span><input value={text} onChange={(event) => setText(event.target.value)} placeholder="搜索商户、分类或账户" /></label><label><span className="sr-only">月份</span><input type="month" value={month} onChange={(event) => setMonth(event.target.value)} /></label><label><span className="sr-only">分类</span><select value={category} onChange={(event) => setCategory(event.target.value)}><option value="">全部分类</option><option>日常餐饮</option><option>交通</option><option>旅行</option><option>订阅服务</option><option>居家</option></select></label><button className="button button-primary" type="submit">搜索</button></form>{!entries ? <LoadingBlock lines={4} /> : entries.length === 0 ? <EmptyState title="没有匹配记录" detail="可以换一个商户关键词，或者清空分类筛选。" /> : <section className="content-card ledger-card"><div className="card-heading"><div><h3>账本记录</h3><p className="muted">找到 {entries.length} 笔记录</p></div><span className="quiet-badge">Asia/Shanghai</span></div><div className="ledger-table-wrap"><table className="ledger-table"><thead><tr><th>日期</th><th>商户 / 来源</th><th>分类</th><th>账户</th><th className="align-right">金额</th><th>状态</th></tr></thead><tbody>{entries.map((entry) => <tr key={entry.id}><td>{fullDateText(entry.date)}</td><td><strong>{entry.merchant}</strong><span className="table-subtitle">{entry.source}</span></td><td>{entry.category}</td><td>{entry.account}</td><td className="align-right amount-cell">{amount(entry.amountCents)}</td><td><span className={`table-status table-status-${entry.status === "已入账" ? "done" : entry.status === "待确认" ? "pending" : "void"}`}>{entry.status}</span></td></tr>)}</tbody></table></div></section>}</div>;
}

const scopeLabel: Record<AccessScope, { label: string; detail: string; tone: "green" | "amber" }> = {
  "read:reports": { label: "读取报告", detail: "月报、年报和统计", tone: "green" },
  "read:ledger": { label: "读取账本", detail: "查询历史交易", tone: "green" },
  "stage:imports": { label: "暂存提案", detail: "创建待确认批次", tone: "amber" },
  "commit:imports": { label: "提交入账", detail: "当前密钥未开启", tone: "amber" },
  "export:reports": { label: "创建导出", detail: "生成 CSV / Excel", tone: "green" },
};

function SettingsView({ api, onToast }: { api: FiscalApiAdapter; onToast: (text: string) => void }) {
  const [scopes, setScopes] = useState<AccessScope[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [exporting, setExporting] = useState<string | null>(null);
  const load = useCallback(() => { setError(null); setScopes(null); api.listAccessScopes().then(setScopes).catch((reason: Error) => setError(reason.message)); }, [api]);
  useEffect(() => { load(); }, [load]);
  const requestExport = async (format: "csv" | "xlsx") => { setExporting(format); try { const result = await api.requestExport({ month: "2026-10", format }); onToast(`已创建 ${result.format.toUpperCase()} 导出任务`); } catch (reason) { onToast((reason as Error).message); } finally { setExporting(null); } };
  if (error) return <ErrorState message={error} onRetry={load} />;
  return <div className="page-stack"><section className="intro-row"><div><p className="eyebrow">SETTINGS / ACCESS</p><h2>控制 Agent 能看到和做到什么</h2><p className="muted">这里展示 scope 和导出入口。会话密钥只在当前页面内存中使用。</p></div><div className="key-status"><span className="connection-dot" /> 当前会话已连接</div></section><section className="settings-grid"><div className="content-card"><div className="card-heading"><div><h3>当前访问 scope</h3><p className="muted">密钥仅用于当前页面请求，不写入浏览器存储。</p></div><span className="quiet-badge">只展示，不存储</span></div>{!scopes ? <LoadingBlock lines={4} /> : <div className="scope-list">{(Object.keys(scopeLabel) as AccessScope[]).map((scope) => { const item = scopeLabel[scope]; const active = scopes.includes(scope); return <div className={`scope-row ${active ? "scope-active" : "scope-inactive"}`} key={scope}><span className={`scope-icon scope-icon-${item.tone}`}>{active ? "✓" : "—"}</span><div><strong>{item.label}</strong><p className="muted">{scope} · {item.detail}</p></div><span className="scope-state">{active ? "已开启" : "未开启"}</span></div>; })}</div>}</div><div className="content-card"><div className="card-heading"><div><h3>导出数据</h3><p className="muted">按月导出，便于留存和复核。</p></div></div><div className="export-actions"><button className="export-option" onClick={() => requestExport("csv")} disabled={Boolean(exporting)}><span className="file-icon">CSV</span><span><strong>导出 CSV</strong><small>兼容 Excel 和分析工具</small></span><span className="export-arrow">{exporting === "csv" ? "…" : "→"}</span></button><button className="export-option" onClick={() => requestExport("xlsx")} disabled={Boolean(exporting)}><span className="file-icon file-icon-green">XLS</span><span><strong>导出 Excel</strong><small>保持分类和金额格式</small></span><span className="export-arrow">{exporting === "xlsx" ? "…" : "→"}</span></button></div></div></section><section className="content-card security-note"><span className="state-icon">⌁</span><div><h3>MCP 接入边界</h3><p className="muted">真实环境会由 MCP Server 校验密钥、scope、请求幂等键和账本 revision。网页只负责展示结果和发起确认，不直接连接数据库。</p></div></section></div>;
}

export default function App() {
  const [view, setView] = useState<ViewId>("inbox");
  const [toast, setToast] = useState<string | null>(null);
  const demoMode = useMemo<ApiDemoMode>(() => {
    const mode = new URLSearchParams(window.location.search).get("demo");
    return mode === "empty" || mode === "error" ? mode : "normal";
  }, []);
  const runtime = useMemo(() => createRuntimeAdapter(demoMode), [demoMode]);
  const api = runtime.adapter;
  const current = navItems.find((item) => item.id === view) ?? navItems[0];
  useEffect(() => { if (!toast) return; const timer = window.setTimeout(() => setToast(null), 3200); return () => window.clearTimeout(timer); }, [toast]);
  return <div className="app-shell"><aside className="sidebar"><div className="brand"><span className="brand-mark">F</span><div><strong>Fiscal</strong><span>Ledger Console</span></div></div><div className="workspace-chip"><span className="workspace-avatar">L</span><span><strong>个人账本</strong><small>Owner workspace</small></span><span className="workspace-chevron">⌄</span></div><nav className="side-nav" aria-label="主导航">{navItems.map((item) => <button className={`nav-item ${view === item.id ? "nav-item-active" : ""}`} onClick={() => setView(item.id)} key={item.id}><span className="nav-icon">{item.icon}</span><span><strong>{item.label}</strong><small>{item.description}</small></span>{item.id === "inbox" && <span className="nav-count">2</span>}</button>)}</nav><div className="sidebar-footer"><div className="sidebar-help"><span>?</span><div><strong>需要帮助？</strong><small>查看接入说明</small></div></div><div className="freeze-label"><span className="connection-dot" /> 原生 App 已冻结</div></div></aside><main className="main-content"><header className="topbar"><div className="mobile-brand"><span className="brand-mark">F</span><strong>Fiscal</strong></div><div className="breadcrumb"><span>个人账本</span><span>/</span><strong>{current.label}</strong></div><div className="topbar-actions"><span className="environment-pill"><span className="connection-dot" /> {runtime.label}</span><button className="avatar-button" aria-label="账户">L</button></div></header><div className="mobile-nav"><select value={view} onChange={(event) => setView(event.target.value as ViewId)} aria-label="选择页面">{navItems.map((item) => <option value={item.id} key={item.id}>{item.label}</option>)}</select></div><div className="view-container">{view === "inbox" && <InboxView api={api} onToast={setToast} environmentLabel={runtime.label} />}{view === "reports" && <ReportView api={api} />}{view === "ledger" && <LedgerView api={api} />}{view === "settings" && <SettingsView api={api} onToast={setToast} />}</div></main>{toast && <div className="toast" role="status"><span>✓</span>{toast}</div>}</div>;
}
