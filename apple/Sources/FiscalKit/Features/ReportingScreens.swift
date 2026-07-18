import SwiftUI

#if os(macOS)
import Charts
#endif

public struct ReportPeriodControl: View {
  let model: ReportingModel
  public init(model: ReportingModel) { self.model = model }
  public var body: some View {
    HStack(spacing: 8) {
      Button { Task { await model.moveMonth(by: -1) } } label: {
        Image(systemName: "chevron.left").frame(width: 30, height: 30)
      }
      .buttonStyle(.plain).background(FiscalColor.surface, in: .rect(cornerRadius: 9))
      .accessibilityLabel("上个月")
      Text(Self.title(model.month)).font(.subheadline.weight(.semibold))
        .frame(minWidth: 92)
      Button { Task { await model.moveMonth(by: 1) } } label: {
        Image(systemName: "chevron.right").frame(width: 30, height: 30)
      }
      .buttonStyle(.plain).background(FiscalColor.surface, in: .rect(cornerRadius: 9))
      .accessibilityLabel("下个月")
      Button("本月") { Task { await model.returnToCurrentMonth() } }
        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.accent)
        .padding(.horizontal, 10).frame(height: 30)
        .background(FiscalColor.accent.opacity(0.08), in: .rect(cornerRadius: 9))
    }
  }
  static func title(_ month: String) -> String {
    let parts = month.split(separator: "-")
    guard parts.count == 2 else { return month }
    return "\(parts[0]) 年 \(Int(parts[1]) ?? 0) 月"
  }
}

private struct ReportingNotice: View {
  let model: ReportingModel
  var body: some View {
    if let message = model.refreshMessage ?? model.message {
      HStack(spacing: 9) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(FiscalColor.expense).accessibilityHidden(true)
        Text(message).font(.caption).foregroundStyle(FiscalColor.secondary)
        Spacer()
      }
      .padding(12).background(FiscalColor.expense.opacity(0.075), in: .rect(cornerRadius: 12))
    }
  }
}

private struct ReportMetric: View {
  let label: String
  let amount: Int64
  let color: Color
  var detail: String?
  // Net values (inflow − outflow) carry a directional sign; magnitude metrics do not. Set this
  // explicitly instead of sniffing the label text for "净额" (L19).
  var showsSign = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.secondary)
      Text(Money(minorUnits: amount).formatted(showPositiveSign: showsSign && amount > 0))
        .font(.system(size: 24, weight: .semibold, design: .default))
        .tracking(-0.35)
        .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.68)
      if let detail { Text(detail).font(.caption2).foregroundStyle(FiscalColor.tertiary) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

public struct IOSReportingOverviewScreen: View {
  @Bindable var model: ReportingModel
  @State private var showAllCreditDues = false
  let pendingProposalCount: Int
  let openAI: () -> Void
  let openCashFlow: () -> Void
  let openAccounts: () -> Void
  let openCreditAccount: (UUID) -> Void
  let openReport: (ReportLens) -> Void
  let openUncategorized: () -> Void
  public init(
    model: ReportingModel, pendingProposalCount: Int, openAI: @escaping () -> Void,
    openCashFlow: @escaping () -> Void,
    openAccounts: @escaping () -> Void,
    openCreditAccount: @escaping (UUID) -> Void,
    openReport: @escaping (ReportLens) -> Void,
    openUncategorized: @escaping () -> Void = {}
  ) {
    self.model = model; self.pendingProposalCount = pendingProposalCount; self.openAI = openAI
    self.openCashFlow = openCashFlow; self.openReport = openReport
    self.openAccounts = openAccounts; self.openCreditAccount = openCreditAccount
    self.openUncategorized = openUncategorized
  }
  public var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 13) {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("当前财务状态 · 实时更新")
                .font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.tertiary)
              Text("总览").font(.system(size: 32, weight: .bold)).tracking(-0.8)
            }
            Spacer()
            Button(action: openAI) {
              Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(FiscalColor.accent).frame(width: 42, height: 42)
                .background(.regularMaterial, in: .circle)
                .overlay(alignment: .topTrailing) {
                  if pendingProposalCount > 0 {
                    Text(pendingProposalCount > 99 ? "99+" : String(pendingProposalCount))
                      .font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 5)
                      .frame(minWidth: 17, minHeight: 17).background(FiscalColor.expense, in: .capsule)
                  }
                }
            }.buttonStyle(.plain).accessibilityLabel("AI 待确认，\(pendingProposalCount) 笔")
              .accessibilityIdentifier("overview.aiPending")
          }
        }
        ReportingNotice(model: model)
        if model.phase == .loading && model.overview == nil { loading }
        else if let value = model.overview { content(value) }
        else { unavailable }
      }.padding(.horizontal, 16).padding(.vertical, 16)
    }.background(FiscalColor.iOSBackground.ignoresSafeArea())
      .task { await model.loadOverview() }
      .refreshable { await model.loadOverview() }
      .sheet(isPresented: $showAllCreditDues) {
        if let overview = model.overview {
          CreditDueEventsList(events: overview.creditDueEvents, openAccount: openCreditAccount)
        }
      }
  }
  @ViewBuilder private func content(_ value: OverviewReport) -> some View {
    Button { openReport(.spending) } label: {
      FiscalCard(radius: 22) {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            FiscalIconTile("list.bullet.rectangle.fill", color: FiscalColor.accent)
            VStack(alignment: .leading, spacing: 2) {
              Text("本月消费").font(.headline)
              Text("原始消费与个人承担分开计算").font(.caption).foregroundStyle(FiscalColor.tertiary)
            }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(FiscalColor.tertiary).accessibilityHidden(true)
          }
          Text(Money(minorUnits: value.spending.grossConsumptionMinor).formatted())
            .font(.system(size: 35, weight: .semibold, design: .default)).tracking(-0.55)
          HStack(spacing: 22) {
            smallValue("预计个人承担", value.spending.personalExpectedMinor, FiscalColor.reimbursement)
            smallValue("实际个人承担", value.spending.personalRealizedMinor, FiscalColor.text)
          }
        }
      }
    }.buttonStyle(.plain)
    Button(action: openCashFlow) {
      FiscalCard(radius: 20) {
        HStack(spacing: 12) {
          FiscalIconTile("arrow.up.arrow.down", color: FiscalColor.reimbursement)
          VStack(alignment: .leading, spacing: 3) {
            Text("未来 30 天现金流").font(.headline)
            Text("预计流入 \(Money(minorUnits: value.cashFlow.inflowMinor).formatted()) · 预计流出 \(Money(minorUnits: value.cashFlow.outflowMinor).formatted())")
              .font(.caption).foregroundStyle(FiscalColor.tertiary).fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Text(Money(minorUnits: value.cashFlow.netMinor).formatted(showPositiveSign: value.cashFlow.netMinor > 0))
            .font(.subheadline.bold())
            .foregroundStyle(value.cashFlow.netMinor >= 0 ? FiscalColor.income : FiscalColor.expense)
        }
      }
    }.buttonStyle(.plain)
    Button(action: openAccounts) { FiscalCard(radius: 18) {
      ReportMetric(label: "现金余额", amount: value.accountValueMinor, color: FiscalColor.income, detail: "现金与储蓄卡余额")
    } }.buttonStyle(.plain)
    if !value.coverage.isComplete {
      Button(action: openUncategorized) {
        HStack(spacing: 10) {
          Image(systemName: "questionmark.circle.fill").accessibilityHidden(true)
          Text("\(value.coverage.uncategorizedCount) 笔待归类 · \(Money(minorUnits: value.coverage.uncategorizedMinor).formatted()) 已计入总额")
          Spacer()
          Text("去处理").foregroundStyle(FiscalColor.accent)
          Image(systemName: "chevron.right").accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.debt).padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FiscalColor.debt.opacity(0.09), in: .rect(cornerRadius: 14))
      }
      .buttonStyle(.plain)
      .accessibilityHint("打开待归类流水")
    }
    if !value.creditDueEvents.isEmpty {
      VStack(alignment: .leading, spacing: 9) {
        Text("未来 30 天信用应还").font(.headline)
        FiscalCard(radius: 20) {
          VStack(spacing: 0) {
            ForEach(value.creditDueEvents.prefix(4)) { event in
              Button { openCreditAccount(event.accountID) } label: { CreditDueEventRow(event: event) }
                .buttonStyle(.plain)
            }
            if value.creditDueEvents.count > 4 {
              Button("查看全部") { showAllCreditDues = true }
                .font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.accent)
                .padding(.top, 10)
            }
          }
        }
      }
    }
    VStack(alignment: .leading, spacing: 9) {
      Text("最近流水").font(.headline)
      FiscalCard(radius: 20) {
        VStack(spacing: 0) {
          ForEach(Array(value.recentTransactions.enumerated()), id: \.element.id) { index, row in
            if index > 0 { Divider().padding(.leading, 45).opacity(0.4) }
            HStack(spacing: 10) {
              FiscalIconTile(row.kind.symbol, color: row.kind == .income ? FiscalColor.income : FiscalColor.accent)
              VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(row.businessDate).font(.caption).foregroundStyle(FiscalColor.tertiary)
              }
              Spacer(); Text(Money(minorUnits: row.amountMinor).formatted())
                .font(.subheadline.weight(.semibold))
            }.frame(minHeight: 54)
          }
        }
      }
    }
  }
  private func smallValue(_ title: String, _ amount: Int64, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(FiscalColor.tertiary)
      Text(Money(minorUnits: amount).formatted()).font(.subheadline.bold()).foregroundStyle(color)
    }
  }
  private var loading: some View {
    VStack(spacing: 13) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 20).fill(FiscalColor.surface).frame(height: 130) } }.redacted(reason: .placeholder)
  }
  private var unavailable: some View {
    FiscalCard(radius: 20) { ContentUnavailableView("无法加载总览", systemImage: "chart.bar.xaxis", description: Text("检查个人 VPS 连接后重试。")) }
  }
}

public struct IOSReportsScreen: View {
  let model: ReportingModel
  public init(model: ReportingModel, initialLens: ReportLens = .spending) {
    self.model = model
    _ = initialLens
  }
  public var body: some View {
    IOSSpendingReportContent(model: model)
      .background(FiscalColor.iOSBackground).navigationTitle("报表")
  }
}

private struct IOSSpendingReportContent: View {
  let model: ReportingModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        ReportPeriodControl(model: model)
        IOSSpendingSummary(model: model)
        SpendingDrillDownContent(model: model)
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
    }
    .task { await model.loadSpending() }
    .refreshable { await model.loadSpending() }
  }
}

private struct IOSSpendingSummary: View {
  let model: ReportingModel
  var body: some View {
    if let report = model.spending {
      SpendingReportContent(
        report: report,
        compact: true,
        selectCategory: { categoryID in Task { await model.loadDrillDown(categoryID: categoryID) } }
      )
    } else { Text("消费") }
  }
}

#if os(macOS)
public struct MacReportingOverviewScreen: View {
  let model: ReportingModel
  let navigate: (ReportLens?) -> Void
  let openCreditAccount: (UUID) -> Void
  @State private var showAllCreditDues = false
  public init(model: ReportingModel, navigate: @escaping (ReportLens?) -> Void, openCreditAccount: @escaping (UUID) -> Void = { _ in }) { self.model = model; self.navigate = navigate; self.openCreditAccount = openCreditAccount }
  public var body: some View {
    GeometryReader { proxy in
      let compact = proxy.size.width < 1_020
      let dashboardHeight = min(620, max(360, proxy.size.height - 210))
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("总览").font(.system(size: 24, weight: .bold))
              Text("当前财务状态 · 实时更新")
                .font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.tertiary)
            }
            Spacer()
          }
          ReportingNotice(model: model)
          if let value = model.overview {
            LazyVGrid(
              columns: Array(
                repeating: GridItem(.flexible(), spacing: 12), count: compact ? 2 : 4),
              spacing: 12
            ) {
              metricButton("本月自己承担", value.spending.personalRealizedMinor, FiscalColor.text) { navigate(.spending) }
              metricButton("现金余额", value.accountValueMinor, FiscalColor.income) { navigate(nil) }
              metricButton("当前信用负债", value.currentCreditDebtMinor, FiscalColor.debt) { navigate(nil) }
              metricButton("待归类", value.uncategorizedAmountMinor, FiscalColor.reimbursement) { navigate(.spending) }
            }
            if compact {
              VStack(spacing: 16) {
                recentCard(value)
                HStack(alignment: .top, spacing: 16) {
                  spendingCard(value)
                  forecastCard(value)
                }
              }
            } else {
              HStack(alignment: .top, spacing: 16) {
                recentCard(value)
                VStack(spacing: 16) {
                  spendingCard(value)
                  forecastCard(value)
                }
                .frame(width: min(340, max(280, proxy.size.width * 0.23)))
                .frame(maxHeight: .infinity)
              }
              .frame(minHeight: dashboardHeight, maxHeight: dashboardHeight)
            }
          } else if model.phase == .loading {
            ProgressView().frame(maxWidth: .infinity).padding(160)
          } else {
            ContentUnavailableView("总览暂不可用", systemImage: "chart.bar.xaxis")
          }
        }
        .padding(20)
        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
      }
    }
    .background(FiscalColor.macBackground)
    .task { await model.loadOverview() }
    .sheet(isPresented: $showAllCreditDues) {
      if let overview = model.overview {
        CreditDueEventsList(events: overview.creditDueEvents, openAccount: openCreditAccount)
          .frame(minWidth: 480, minHeight: 420)
      }
    }
  }
  private func metricButton(_ label: String, _ amount: Int64, _ color: Color, showsSign: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) { FiscalCard(radius: 15) { ReportMetric(label: label, amount: amount, color: color, detail: "查看口径与明细", showsSign: showsSign) } }.buttonStyle(.plain)
  }
  private func recentCard(_ value: OverviewReport) -> some View {
    FiscalCard(radius: 15) {
      VStack(alignment: .leading, spacing: 10) {
        Text("最近流水").font(.headline)
        ForEach(value.recentTransactions) { row in
          Divider().opacity(0.35)
          HStack {
            Text(row.businessDate).font(.caption).foregroundStyle(FiscalColor.tertiary)
              .frame(width: 72, alignment: .leading)
            Text(row.title).lineLimit(2)
            Spacer()
            Text(Money(minorUnits: row.amountMinor).formatted())
          }
          .frame(height: 32)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func spendingCard(_ value: OverviewReport) -> some View {
    FiscalCard(radius: 15) {
      VStack(alignment: .leading, spacing: 9) {
        Text("消费口径").font(.headline)
        Spacer(minLength: 8)
        ReportMetric(label: "本月自己承担", amount: value.spending.personalRealizedMinor, color: FiscalColor.text)
        Text("已扣商家退款和已到账报销；未到账报销仍计入本人承担。")
          .font(.caption).foregroundStyle(FiscalColor.tertiary)
        Spacer(minLength: 8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func forecastCard(_ value: OverviewReport) -> some View {
    FiscalCard(radius: 15) {
      VStack(alignment: .leading, spacing: 9) {
        Text("未来 30 天信用应还").font(.headline)
        Spacer(minLength: 8)
        if value.creditDueEvents.isEmpty {
          EmptyInline(symbol: "calendar", title: "未来 30 天没有信用应还")
        } else {
          ForEach(value.creditDueEvents.prefix(4)) { event in
            Button { openCreditAccount(event.accountID) } label: { CreditDueEventRow(event: event) }
              .buttonStyle(.plain)
          }
          if value.creditDueEvents.count > 4 {
            Button("查看全部") { showAllCreditDues = true }
              .font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.accent)
          }
        }
        Spacer(minLength: 8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

public struct MacReportsScreen: View {
  let model: ReportingModel
  public init(model: ReportingModel) { self.model = model }
  public var body: some View {
    MacSpendingReportContent(model: model)
  }
}

private struct MacSpendingReportContent: View {
  let model: ReportingModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        ReportPeriodControl(model: model)
        MacSpendingSummary(model: model)
        SpendingDrillDownContent(model: model)
      }
      .padding(20)
    }
    .task { await model.loadSpending() }
  }
}

private struct MacSpendingSummary: View {
  let model: ReportingModel
  var body: some View {
    if let report = model.spending {
      SpendingReportContent(
        report: report,
        compact: false,
        selectCategory: { categoryID in Task { await model.loadDrillDown(categoryID: categoryID) } }
      )
    } else { Text("消费") }
  }
}

#endif

private struct SpendingReportSummaryCard: View {
  let report: SpendingReport
  var body: some View {
    FiscalCard(radius: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("实际个人承担").font(.caption).foregroundStyle(FiscalColor.tertiary)
        Text(Money(minorUnits: report.totals.personalRealizedMinor).formatted()).font(.title.bold())
        Text("已扣商家退款和已到账报销；未到账报销仍计入本人承担。")
          .font(.caption).foregroundStyle(FiscalColor.secondary)
      }
    }
  }
}

private struct SpendingReportContent: View {
  let report: SpendingReport
  let compact: Bool
  let selectCategory: (UUID?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SpendingReportSummaryCard(report: report)
      Text("分类构成").font(.headline)
      SpendingCategoryRows(
        categories: report.categories,
        totalMinor: report.totals.personalRealizedMinor,
        compact: compact,
        selectCategory: selectCategory
      )
      if report.uncategorized.transactionCount > 0 {
        SpendingCategoryLine(
          name: "待归类", amountMinor: report.uncategorized.personalRealizedMinor,
          count: report.uncategorized.transactionCount,
          totalMinor: report.totals.personalRealizedMinor, indent: 0,
          action: { selectCategory(nil) }
        )
      }
    }
    .padding(compact ? 16 : 18)
  }
}

private struct SpendingCategoryRows: View {
  let categories: [SpendingCategoryRoot]
  let totalMinor: Int64
  let compact: Bool
  let selectCategory: (UUID?) -> Void

  var body: some View {
    FiscalCard(radius: compact ? 20 : 15) {
      VStack(spacing: 0) {
        ForEach(categories) { category in
          SpendingCategoryLine(
            name: category.name, amountMinor: category.personalRealizedMinor,
            count: category.transactionCount, totalMinor: totalMinor, indent: 0,
            action: { selectCategory(category.categoryID) }
          )
          ForEach(category.children) { child in
            SpendingCategoryLine(
              name: child.name, amountMinor: child.personalRealizedMinor,
              count: child.transactionCount, totalMinor: totalMinor, indent: 18,
              action: { selectCategory(child.categoryID) }
            )
          }
        }
      }
    }
  }
}

private struct SpendingCategoryLine: View {
  let name: String
  let amountMinor: Int64
  let count: Int
  let totalMinor: Int64
  let indent: CGFloat
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
          .padding(.leading, indent)
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 2) {
          Text(Money(minorUnits: amountMinor).formatted()).font(.subheadline.weight(.semibold))
          Text("\(share) · \(count) 笔").font(.caption2).foregroundStyle(FiscalColor.tertiary)
        }
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary)
      }
      .padding(.vertical, 9).contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  private var share: String {
    guard totalMinor > 0 else { return "—" }
    return "\(Int((Double(amountMinor) * 100 / Double(totalMinor)).rounded()))%"
  }
}
private struct CreditDueEventRow: View {
  let event: OverviewCreditDueEvent
  var body: some View {
    HStack(spacing: 10) {
      FiscalIconTile("creditcard", color: FiscalColor.debt)
      VStack(alignment: .leading, spacing: 2) {
        Text(event.accountName).font(.subheadline.weight(.semibold))
        Text("还款日 \(event.dueDate)").font(.caption).foregroundStyle(FiscalColor.tertiary)
      }
      Spacer()
      Text(Money(minorUnits: event.remainingMinor).formatted()).font(.subheadline.bold()).foregroundStyle(FiscalColor.debt)
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary)
    }
    .padding(.vertical, 7).contentShape(.rect)
  }
}

private struct CreditDueEventsList: View {
  let events: [OverviewCreditDueEvent]
  let openAccount: (UUID) -> Void
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List(events) { event in
        Button { dismiss(); openAccount(event.accountID) } label: { CreditDueEventRow(event: event) }
          .buttonStyle(.plain)
      }
      .navigationTitle("未来 30 天信用应还")
    }
  }
}

private struct SpendingDrillDownContent: View {
  let model: ReportingModel

  var body: some View {
    if let page = model.drillDown {
      FiscalCard(radius: 16) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("贡献明细").font(.headline)
              Text("按原消费日期与分类归因").font(.caption).foregroundStyle(FiscalColor.tertiary)
            }
            Spacer()
            Button { model.clearDrillDown() } label: {
              Image(systemName: "xmark").font(.caption.bold()).frame(width: 28, height: 28)
                .background(FiscalColor.separator.opacity(0.72), in: .circle)
            }
            .buttonStyle(.plain).accessibilityLabel("关闭贡献明细")
          }
          if page.items.isEmpty {
            EmptyInline(symbol: "doc.text.magnifyingglass", title: "这个筛选下没有贡献流水")
          } else {
            ForEach(page.items) { item in
              HStack(spacing: 10) {
                FiscalIconTile(item.kind.symbol, color: FiscalColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                  Text([item.businessDate, item.accountName, item.categoryName]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(2)
                }
                Spacer()
                Text(Money(minorUnits: item.signedAmountMinor).formatted())
                  .font(.subheadline.bold()).foregroundStyle(FiscalColor.text)
              }
              .frame(minHeight: 52)
              Divider().padding(.leading, 45).opacity(0.35)
            }
          }
          if page.nextCursor != nil {
            Button { Task { await model.loadMoreDrillDown() } } label: {
              HStack(spacing: 7) {
                if model.loadingMore { ProgressView().controlSize(.small) }
                Text(model.loadingMore ? "加载中" : "加载更多贡献明细")
              }
              .font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.accent)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(FiscalColor.accent.opacity(0.08), in: .rect(cornerRadius: 10))
            }
            .buttonStyle(.plain).disabled(model.loadingMore).padding(.top, 8)
          }
        }
      }
    }
  }
}

#if os(macOS)
private func spendingChart(_ values: [SpendingTrendBucket]) -> some View {
  VStack(spacing: 5) {
    Chart(values) { value in
      BarMark(x: .value("日期", value.dateFrom), y: .value("个人承担", Double(value.metrics.personalRealizedMinor) / 100))
        .foregroundStyle(FiscalColor.accent.gradient).cornerRadius(3)
    }
    .chartXAxis(.hidden)
    .chartYAxis { currencyAxis }
    chartRangeLabels(values.first?.dateFrom, values.last?.dateFrom)
  }
  .accessibilityLabel("消费趋势")
}
private func cashChart(_ values: [CashFlowTrendBucket]) -> some View {
  VStack(spacing: 5) {
    Chart(values) { value in
      AreaMark(x: .value("日期", value.date), y: .value("净现金流", Double(value.metrics.netMinor) / 100))
        .foregroundStyle(FiscalColor.reimbursement.opacity(0.18))
      LineMark(x: .value("日期", value.date), y: .value("净现金流", Double(value.metrics.netMinor) / 100))
        .foregroundStyle(FiscalColor.reimbursement).lineStyle(.init(lineWidth: 2))
    }
    .chartXAxis(.hidden)
    .chartYAxis { currencyAxis }
    chartRangeLabels(values.first?.date, values.last?.date)
  }
  .accessibilityLabel("实际现金流趋势")
}

private func chartRangeLabels(_ first: String?, _ last: String?) -> some View {
  HStack {
    if let first { Text(String(first.suffix(5))) }
    Spacer()
    if let last { Text(String(last.suffix(5))) }
  }
  .font(.caption2).foregroundStyle(FiscalColor.tertiary)
}

private var currencyAxis: some AxisContent {
  AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
    AxisGridLine().foregroundStyle(FiscalColor.separator)
    AxisValueLabel {
      if let amount = value.as(Double.self) {
        Text(amount.formatted(.number.precision(.fractionLength(0...1))))
      }
    }
  }
}
#endif

private func reportAmountRow(_ title: String, _ amount: Int64, _ color: Color) -> some View {
  HStack(spacing: 12) {
    Text(title).font(.subheadline).foregroundStyle(FiscalColor.secondary)
    Spacer()
    Text(Money(minorUnits: amount).formatted())
      .font(.subheadline.weight(.semibold)).foregroundStyle(color)
  }.frame(minHeight: 46)
}

private func reportColor(_ hex: String?, fallback: Color = FiscalColor.tertiary) -> Color {
  guard let hex, let value = UInt(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
  else { return fallback }
  return Color(hex: value)
}

@MainActor private func categoryRows(
  _ values: [SpendingCategoryRow], model: ReportingModel, showsBars: Bool = true
) -> some View {
  let maximum = max(1, values.map(\.rollup.personalRealizedMinor).max() ?? 1)
  return VStack(spacing: 0) {
    ForEach(values) { row in
      Button { model.lens = .spending; Task { await model.loadDrillDown(categoryID: row.categoryID) } } label: {
        HStack(spacing: 10) {
          FiscalIconTile(row.icon ?? "questionmark", color: reportColor(row.colorHex))
          VStack(alignment: .leading, spacing: showsBars ? 6 : 0) {
            HStack { Text(row.name).font(.subheadline.weight(.semibold)); Spacer(); Text(Money(minorUnits: row.rollup.personalRealizedMinor).formatted()) }
            if showsBars {
              GeometryReader { proxy in Capsule().fill(FiscalColor.separator.opacity(0.72)).overlay(alignment: .leading) { Capsule().fill(reportColor(row.colorHex, fallback: FiscalColor.accent)).frame(width: proxy.size.width * CGFloat(max(0, row.rollup.personalRealizedMinor)) / CGFloat(maximum)) } }.frame(height: 7)
            }
          }
          Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary).accessibilityHidden(true)
        }.padding(.vertical, 9).contentShape(.rect)
      }.buttonStyle(.plain)
      Divider().padding(.leading, 45).opacity(0.35)
    }
  }
}

@MainActor private func accountRows(_ values: [CashFlowAccountRow], model: ReportingModel) -> some View {
  VStack(spacing: 0) {
    ForEach(values) { row in
      Button { model.lens = .cashFlow; Task { await model.loadDrillDown(accountID: row.accountID) } } label: {
        HStack { Text(row.name).font(.subheadline.weight(.semibold)); Spacer(); Text("+\(Money(minorUnits: row.metrics.inflowMinor).formatted())").foregroundStyle(FiscalColor.income); Text("-\(Money(minorUnits: row.metrics.outflowMinor).formatted())").foregroundStyle(FiscalColor.expense); Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary).accessibilityHidden(true) }.padding(.vertical, 11)
      }.buttonStyle(.plain); Divider().opacity(0.35)
    }
  }
}

@MainActor
private func drillDownRows(_ page: ReportDrillDownPage, model: ReportingModel) -> some View {
  VStack(spacing: 0) {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("贡献明细").font(.headline)
        Text(model.lens == .spending ? "按原消费日期与分类归因" : "按实际现金账户变动")
          .font(.caption).foregroundStyle(FiscalColor.tertiary)
      }
      Spacer()
      Button { model.clearDrillDown() } label: {
        Image(systemName: "xmark").font(.caption.bold()).frame(width: 28, height: 28)
          .background(FiscalColor.separator.opacity(0.72), in: .circle)
      }.buttonStyle(.plain).accessibilityLabel("关闭贡献明细")
    }.padding(.bottom, 8)
    if page.items.isEmpty {
      EmptyInline(symbol: "doc.text.magnifyingglass", title: "这个筛选下没有贡献流水")
    } else {
      ForEach(page.items) { item in
        HStack(spacing: 10) {
          FiscalIconTile(
            item.kind.symbol,
            color: model.lens == .cashFlow && item.signedAmountMinor > 0
              ? FiscalColor.income : FiscalColor.accent)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(
              [item.businessDate, item.accountName, item.categoryName]
                .compactMap { $0 }.joined(separator: " · "))
              .font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(2)
          }
          Spacer()
          Text(
            Money(minorUnits: item.signedAmountMinor).formatted(
              showPositiveSign: model.lens == .cashFlow && item.signedAmountMinor > 0))
            .font(.subheadline.bold())
            .foregroundStyle(
              model.lens == .cashFlow && item.signedAmountMinor > 0
                ? FiscalColor.income : FiscalColor.text)
        }.frame(minHeight: 52)
        Divider().padding(.leading, 45).opacity(0.35)
      }
      if page.nextCursor != nil {
        Button { Task { await model.loadMoreDrillDown() } } label: {
          HStack(spacing: 7) {
            if model.loadingMore { ProgressView().controlSize(.small) }
            Text(model.loadingMore ? "加载中" : "加载更多贡献明细")
          }.font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.accent)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(FiscalColor.accent.opacity(0.08), in: .rect(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(model.loadingMore).padding(.top, 8)
      }
    }
  }
}

@MainActor private func debtAccountCard(_ account: DebtAccountRow) -> some View {
  FiscalCard(radius: 16) {
    VStack(alignment: .leading, spacing: 10) {
      HStack { Text(account.name).font(.headline); Spacer(); Text(Money(minorUnits: account.currentDebtMinor).formatted()).font(.headline).foregroundStyle(FiscalColor.debt) }
      if account.openingConfigurationRequired { Label("期初欠款尚未配置日期，不推测到期事件", systemImage: "calendar.badge.exclamationmark").font(.caption).foregroundStyle(FiscalColor.debt) }
      ForEach(account.cycles.filter { $0.remainingMinor > 0 }) { cycle in
        HStack { VStack(alignment: .leading) { Text("还款日 \(cycle.dueDate)").font(.caption); Text(cycle.overdue ? "已逾期" : cycle.status).font(.caption2).foregroundStyle(cycle.overdue ? FiscalColor.expense : FiscalColor.tertiary) }; Spacer(); Text(Money(minorUnits: cycle.remainingMinor).formatted()) }.padding(.top, 7)
      }
    }
  }
}

private func installmentRows(_ groups: [DebtInstallmentGroup]) -> some View {
  VStack(spacing: 0) {
    ForEach(groups) { group in
      HStack { Text(group.month).font(.subheadline); Text("\(group.periodCount) 期").font(.caption).foregroundStyle(FiscalColor.tertiary); Spacer(); Text(Money(minorUnits: group.totalScheduledGrossMinor).formatted()).font(.subheadline.weight(.semibold)).foregroundStyle(FiscalColor.debt) }.padding(.vertical, 10)
      Divider().opacity(0.35)
    }
    if groups.isEmpty { EmptyInline(symbol: "calendar", title: "没有未来分期计划") }
  }
}
