import SwiftUI

#if os(macOS)
import Charts
#endif

public struct ReportPeriodControl: View {
  @Bindable var model: ReportingModel
  public init(model: ReportingModel) { self.model = model }
  public var body: some View {
    HStack(spacing: 8) {
      Button { Task { await model.moveMonth(by: -1) } } label: {
        Image(systemName: "chevron.left").frame(width: 30, height: 30)
      }
      .buttonStyle(.plain).background(.white, in: .rect(cornerRadius: 9))
      Text(Self.title(model.month)).font(.subheadline.weight(.semibold)).monospacedDigit()
        .frame(minWidth: 92)
      Button { Task { await model.moveMonth(by: 1) } } label: {
        Image(systemName: "chevron.right").frame(width: 30, height: 30)
      }
      .buttonStyle(.plain).background(.white, in: .rect(cornerRadius: 9))
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
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(FiscalColor.expense)
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
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.secondary)
      Text(Money(minorUnits: amount).formatted(showPositiveSign: amount > 0 && label.contains("净额")))
        .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
        .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.68)
      if let detail { Text(detail).font(.caption2).foregroundStyle(FiscalColor.tertiary) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

public struct IOSReportingOverviewScreen: View {
  @Bindable var model: ReportingModel
  let pendingProposalCount: Int
  let openAI: () -> Void
  let openCashFlow: () -> Void
  let openReport: (ReportLens) -> Void
  public init(
    model: ReportingModel, pendingProposalCount: Int, openAI: @escaping () -> Void,
    openCashFlow: @escaping () -> Void,
    openReport: @escaping (ReportLens) -> Void
  ) {
    self.model = model; self.pendingProposalCount = pendingProposalCount; self.openAI = openAI
    self.openCashFlow = openCashFlow; self.openReport = openReport
  }
  public var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 13) {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("\(ReportPeriodControl.title(model.month)) · 消费 / 现金流 / 负债")
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
          ReportPeriodControl(model: model).frame(maxWidth: .infinity, alignment: .trailing)
        }
        ReportingNotice(model: model)
        if model.phase == .loading && model.overview == nil { loading }
        else if let value = model.overview { content(value) }
        else { unavailable }
      }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 112)
    }.background(FiscalColor.iOSBackground.ignoresSafeArea())
      .refreshable { await model.loadAll() }
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
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(FiscalColor.tertiary)
          }
          Text(Money(minorUnits: value.spending.grossConsumptionMinor).formatted())
            .font(.system(size: 35, weight: .bold, design: .rounded)).monospacedDigit()
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
            Text("本月实际现金流").font(.headline)
            Text("流入 \(Money(minorUnits: value.cashFlow.inflowMinor).formatted()) · 流出 \(Money(minorUnits: value.cashFlow.outflowMinor).formatted())")
              .font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(1)
          }
          Spacer()
          Text(Money(minorUnits: value.cashFlow.netMinor).formatted(showPositiveSign: value.cashFlow.netMinor > 0))
            .font(.subheadline.bold()).monospacedDigit()
            .foregroundStyle(value.cashFlow.netMinor >= 0 ? FiscalColor.income : FiscalColor.expense)
        }
      }
    }.buttonStyle(.plain)
    HStack(spacing: 12) {
      Button { openReport(.debt) } label: {
        FiscalCard(radius: 18) {
          ReportMetric(label: "当前信用负债", amount: value.currentCreditDebtMinor, color: FiscalColor.debt)
        }
      }.buttonStyle(.plain)
      FiscalCard(radius: 18) {
        ReportMetric(
          label: "报销待回款", amount: value.reimbursementOutstandingMinor,
          color: FiscalColor.reimbursement)
      }
    }
    if !value.coverage.isComplete {
      Label(
        "\(value.coverage.uncategorizedCount) 笔待归类 · \(Money(minorUnits: value.coverage.uncategorizedMinor).formatted()) 已计入总额",
        systemImage: "questionmark.circle.fill")
        .font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.debt).padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FiscalColor.debt.opacity(0.09), in: .rect(cornerRadius: 14))
    }
    if !value.forecastEvents.isEmpty {
      VStack(alignment: .leading, spacing: 9) {
        Text("未来 30 天").font(.headline)
        FiscalCard(radius: 20) { forecastRows(value.forecastEvents.prefix(3)) }
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
                Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(row.businessDate).font(.caption).foregroundStyle(FiscalColor.tertiary)
              }
              Spacer(); Text(Money(minorUnits: row.amountMinor).formatted())
                .font(.subheadline.weight(.semibold)).monospacedDigit()
            }.frame(minHeight: 54)
          }
        }
      }
    }
  }
  private func smallValue(_ title: String, _ amount: Int64, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(FiscalColor.tertiary)
      Text(Money(minorUnits: amount).formatted()).font(.subheadline.bold()).monospacedDigit().foregroundStyle(color)
    }
  }
  private var loading: some View {
    VStack(spacing: 13) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 20).fill(.white).frame(height: 130) } }.redacted(reason: .placeholder)
  }
  private var unavailable: some View {
    FiscalCard(radius: 20) { ContentUnavailableView("无法加载总览", systemImage: "chart.bar.xaxis", description: Text("检查个人 VPS 连接后重试。")) }
  }
}

public struct IOSCashFlowScreen: View {
  @Bindable var model: ReportingModel
  public init(model: ReportingModel) { self.model = model }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 10) {
          Text("现金流").font(.system(size: 32, weight: .bold))
          ReportPeriodControl(model: model).frame(maxWidth: .infinity, alignment: .trailing)
        }
        ReportingNotice(model: model)
        if let report = model.cashFlow {
          Text("现金流摘要").font(.headline).padding(.horizontal, 3)
          FiscalCard(radius: 20) {
            VStack(spacing: 0) {
              let forecastNet =
                report.forecast.expectedReceiptInflowMinor - report.forecast.exactDueOutflowMinor
              reportAmountRow("未来 30 天预测净额", forecastNet, forecastNet >= 0 ? FiscalColor.income : FiscalColor.expense)
              Divider().opacity(0.35)
              reportAmountRow("预计到账", report.forecast.expectedReceiptInflowMinor, FiscalColor.income)
              Divider().opacity(0.35)
              reportAmountRow("精确应还", report.forecast.exactDueOutflowMinor, FiscalColor.expense)
              Divider().opacity(0.35)
              reportAmountRow("本月实际流入", report.actual.inflowMinor, FiscalColor.income)
              Divider().opacity(0.35)
              reportAmountRow("本月实际流出", report.actual.outflowMinor, FiscalColor.expense)
            }
          }
          Text("未来将要发生").font(.headline).padding(.horizontal, 3)
          FiscalCard(radius: 20) {
            if report.forecast.events.isEmpty {
              EmptyInline(symbol: "calendar.badge.checkmark", title: "未来 30 天没有权威日期事件")
            } else { forecastRows(report.forecast.events) }
          }
          Text("本月账户收支").font(.headline).padding(.horizontal, 3)
          FiscalCard(radius: 20) {
            if report.accounts.isEmpty {
              EmptyInline(symbol: "wallet.bifold", title: "本月没有账户现金变动")
            } else { accountRows(report.accounts, model: model) }
          }
          Text("预测不会写入账本；内部转账不计入全局流入与流出。")
            .font(.caption).foregroundStyle(FiscalColor.tertiary).padding(.horizontal, 3)
        } else if model.phase == .loading { ProgressView().frame(maxWidth: .infinity).padding(80) }
        else { ContentUnavailableView("现金流暂不可用", systemImage: "arrow.up.arrow.down") }
      }.padding(16).padding(.bottom, 110)
    }.background(FiscalColor.iOSBackground.ignoresSafeArea())
  }
}

public struct IOSReportsScreen: View {
  @Bindable var model: ReportingModel
  public init(model: ReportingModel, initialLens: ReportLens = .spending) {
    self.model = model
    model.lens = initialLens == .cashFlow ? .spending : initialLens
  }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        ReportPeriodControl(model: model).frame(maxWidth: .infinity, alignment: .trailing)
        Picker("统计口径", selection: $model.lens) {
          Text("消费").tag(ReportLens.spending)
          Text("负债").tag(ReportLens.debt)
        }.pickerStyle(.segmented)
        ReportingNotice(model: model)
        switch model.lens {
        case .spending: spendingBody
        case .cashFlow: spendingBody
        case .debt: debtBody
        }
      }.padding(16).padding(.bottom, 30)
    }.background(FiscalColor.iOSBackground).navigationTitle("报表")
  }
  @ViewBuilder private var spendingBody: some View {
    if let report = model.spending {
      FiscalCard(radius: 20) {
        VStack(spacing: 0) {
          reportAmountRow("原始消费", report.totals.grossConsumptionMinor, FiscalColor.text)
          Divider().opacity(0.35)
          reportAmountRow("预计个人承担", report.totals.personalExpectedMinor, FiscalColor.reimbursement)
          Divider().opacity(0.35)
          reportAmountRow("实际个人承担", report.totals.personalRealizedMinor, FiscalColor.text)
          Divider().opacity(0.35)
          reportAmountRow("商家退款", report.totals.merchantRefundMinor, FiscalColor.income)
          Divider().opacity(0.35)
          reportAmountRow("已到账报销", report.totals.receivedReimbursementMinor, FiscalColor.income)
        }
      }
      Text("分类构成").font(.headline).padding(.horizontal, 3)
      FiscalCard(radius: 20) { categoryRows(report.categories, model: model, showsBars: false) }
      if let page = model.drillDown { FiscalCard(radius: 20) { drillDownRows(page, model: model) } }
    } else { reportUnavailable }
  }
  @ViewBuilder private var debtBody: some View {
    if let report = model.debt {
      FiscalCard(radius: 20) { ReportMetric(label: "当前信用负债", amount: report.currentCreditDebtMinor, color: FiscalColor.debt, detail: "未来分期毛额已包含在当前债务中") }
      ForEach(report.accounts) { account in debtAccountCard(account) }
      Text("分期 · 未来计划毛额").font(.headline)
      FiscalCard(radius: 20) { installmentRows(report.installmentGroups) }
    } else { reportUnavailable }
  }
  private var reportUnavailable: some View { ContentUnavailableView("报表暂不可用", systemImage: "chart.bar.xaxis") }
}

#if os(macOS)
public struct MacReportingOverviewScreen: View {
  @Bindable var model: ReportingModel
  let navigate: (ReportLens?) -> Void
  public init(model: ReportingModel, navigate: @escaping (ReportLens?) -> Void) { self.model = model; self.navigate = navigate }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack { Text("总览").font(.system(size: 24, weight: .bold)); Spacer(); ReportPeriodControl(model: model) }
        ReportingNotice(model: model)
        if let value = model.overview {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            metricButton("本月消费", value.spending.grossConsumptionMinor, FiscalColor.text) { navigate(.spending) }
            metricButton("现金流净额", value.cashFlow.netMinor, value.cashFlow.netMinor >= 0 ? FiscalColor.income : FiscalColor.expense) { navigate(.cashFlow) }
            metricButton("信用应还", value.currentCreditDebtMinor, FiscalColor.debt) { navigate(.debt) }
            metricButton("报销待回款", value.reimbursementOutstandingMinor, FiscalColor.reimbursement) { navigate(nil) }
          }
          HStack(alignment: .top, spacing: 16) {
            FiscalCard(radius: 15) {
              VStack(alignment: .leading, spacing: 10) {
                Text("最近流水").font(.headline)
                ForEach(value.recentTransactions) { row in
                  Divider().opacity(0.35)
                  HStack { Text(row.businessDate).font(.caption).foregroundStyle(FiscalColor.tertiary).frame(width: 72, alignment: .leading); Text(row.title).lineLimit(1); Spacer(); Text(Money(minorUnits: row.amountMinor).formatted()).monospacedDigit() }
                }
              }
            }.frame(maxWidth: .infinity)
            VStack(spacing: 16) {
              FiscalCard(radius: 15) { VStack(alignment: .leading, spacing: 9) { Text("消费口径").font(.headline); ReportMetric(label: "预计个人承担", amount: value.spending.personalExpectedMinor, color: FiscalColor.reimbursement); Text("实际承担 \(Money(minorUnits: value.spending.personalRealizedMinor).formatted())").font(.caption).foregroundStyle(FiscalColor.tertiary) } }
              FiscalCard(radius: 15) { VStack(alignment: .leading, spacing: 9) { Text("未来 30 天").font(.headline); if value.forecastEvents.isEmpty { EmptyInline(symbol: "calendar", title: "没有权威日期事件") } else { forecastRows(value.forecastEvents.prefix(2)) } } }
            }.frame(width: 280)
          }
        } else if model.phase == .loading { ProgressView().frame(maxWidth: .infinity).padding(160) }
        else { ContentUnavailableView("总览暂不可用", systemImage: "chart.bar.xaxis") }
      }.padding(20)
    }.background(FiscalColor.macBackground)
  }
  private func metricButton(_ label: String, _ amount: Int64, _ color: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) { FiscalCard(radius: 15) { ReportMetric(label: label, amount: amount, color: color, detail: "查看口径与明细") } }.buttonStyle(.plain)
  }
}

public struct MacCashFlowScreen: View {
  @Bindable var model: ReportingModel
  public init(model: ReportingModel) { self.model = model }
  public var body: some View {
    VStack(spacing: 0) {
      HStack { Text("现金流").font(.system(size: 22, weight: .bold)); Spacer(); ReportPeriodControl(model: model) }.padding(.horizontal, 20).frame(height: 54).background(.white)
      if let report = model.cashFlow {
        HStack(alignment: .top, spacing: 16) {
          FiscalCard(radius: 15) { VStack(alignment: .leading, spacing: 12) { Text("未来现金流").font(.headline); Text("仅显示有正式日期来源的预测").font(.caption).foregroundStyle(FiscalColor.tertiary); if report.forecast.events.isEmpty { ContentUnavailableView("未来 30 天无权威事件", systemImage: "calendar.badge.checkmark") } else { forecastRows(report.forecast.events) } } }.frame(maxWidth: .infinity)
          VStack(spacing: 16) {
            FiscalCard(radius: 15) { VStack(alignment: .leading, spacing: 13) { ReportMetric(label: "未来 30 天预测净额", amount: report.forecast.expectedReceiptInflowMinor - report.forecast.exactDueOutflowMinor, color: FiscalColor.reimbursement); Divider(); HStack { Text("预计到账"); Spacer(); Text(Money(minorUnits: report.forecast.expectedReceiptInflowMinor).formatted()).foregroundStyle(FiscalColor.income) }; HStack { Text("精确应还"); Spacer(); Text(Money(minorUnits: report.forecast.exactDueOutflowMinor).formatted()).foregroundStyle(FiscalColor.expense) } } }
            FiscalCard(radius: 15) { VStack(alignment: .leading, spacing: 10) { Text("本月实际").font(.headline); ReportMetric(label: "实际净额", amount: report.actual.netMinor, color: report.actual.netMinor >= 0 ? FiscalColor.income : FiscalColor.expense); Text("内部转账不膨胀全局流入流出。预测不会写入账本。").font(.caption).foregroundStyle(FiscalColor.tertiary) } }
          }.frame(width: 270)
        }.padding(18)
      } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }.background(FiscalColor.macBackground)
  }
}

public struct MacReportsScreen: View {
  @Bindable var model: ReportingModel
  public init(model: ReportingModel) { self.model = model }
  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Text("报表").font(.system(size: 22, weight: .bold)); Spacer()
        Picker("统计口径", selection: $model.lens) { Text("消费").tag(ReportLens.spending); Text("现金流").tag(ReportLens.cashFlow); Text("负债").tag(ReportLens.debt) }.pickerStyle(.segmented).frame(width: 250)
        ReportPeriodControl(model: model)
      }.padding(.horizontal, 20).frame(height: 58).background(.white)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ReportingNotice(model: model)
          switch model.lens {
          case .spending: macSpending
          case .cashFlow: macCash
          case .debt: macDebt
          }
        }.padding(18)
      }
    }.background(FiscalColor.macBackground)
  }
  @ViewBuilder private var macSpending: some View {
    if let report = model.spending {
      HStack(alignment: .top, spacing: 16) {
        FiscalCard(radius: 15) { VStack(alignment: .leading, spacing: 14) { ReportMetric(label: "原始消费", amount: report.totals.grossConsumptionMinor, color: FiscalColor.text); HStack { ReportMetric(label: "预计个人承担", amount: report.totals.personalExpectedMinor, color: FiscalColor.reimbursement); ReportMetric(label: "实际个人承担", amount: report.totals.personalRealizedMinor, color: FiscalColor.text) }; Text("信用消费计入一次；还款与转账不重复计入。").font(.caption).foregroundStyle(FiscalColor.tertiary) } }.frame(width: 310)
        FiscalCard(radius: 15) { VStack(alignment: .leading) { Text("消费趋势").font(.headline); spendingChart(report.trend).frame(height: 190) } }.frame(maxWidth: .infinity)
      }
      FiscalCard(radius: 15) { VStack(alignment: .leading, spacing: 12) { HStack { Text("分类构成").font(.headline); Spacer(); Text("点击下钻贡献明细").font(.caption).foregroundStyle(FiscalColor.tertiary) }; categoryRows(report.categories, model: model) } }
      if let page = model.drillDown { FiscalCard(radius: 15) { drillDownRows(page, model: model) } }
    }
  }
  @ViewBuilder private var macCash: some View {
    if let report = model.cashFlow {
      HStack(alignment: .top, spacing: 16) {
        FiscalCard(radius: 15) { VStack(alignment: .leading, spacing: 12) { ReportMetric(label: "实际现金流净额", amount: report.actual.netMinor, color: report.actual.netMinor >= 0 ? FiscalColor.income : FiscalColor.expense); HStack { ReportMetric(label: "流入", amount: report.actual.inflowMinor, color: FiscalColor.income); ReportMetric(label: "流出", amount: report.actual.outflowMinor, color: FiscalColor.expense) } } }.frame(width: 310)
        FiscalCard(radius: 15) { cashChart(report.trend).frame(height: 190) }.frame(maxWidth: .infinity)
      }
      FiscalCard(radius: 15) { VStack(alignment: .leading) { Text("按账户").font(.headline); accountRows(report.accounts, model: model) } }
      if let page = model.drillDown { FiscalCard(radius: 15) { drillDownRows(page, model: model) } }
    }
  }
  @ViewBuilder private var macDebt: some View {
    if let report = model.debt {
      HStack(alignment: .top, spacing: 16) {
        FiscalCard(radius: 15) { ReportMetric(label: "当前信用负债", amount: report.currentCreditDebtMinor, color: FiscalColor.debt, detail: "未来计划毛额已包含，不重复相加") }.frame(width: 280)
        VStack(spacing: 14) { ForEach(report.accounts) { debtAccountCard($0) } }.frame(maxWidth: .infinity)
      }
      FiscalCard(radius: 15) { VStack(alignment: .leading) { Text("分期 · 未来计划毛额").font(.headline); installmentRows(report.installmentGroups) } }
    }
  }
}
#endif

@ViewBuilder private func forecastRows<S: Sequence>(_ events: S) -> some View where S.Element == ForecastEvent {
  VStack(spacing: 0) {
    ForEach(Array(events)) { event in
      HStack(spacing: 10) {
        FiscalIconTile(event.direction == .inflow ? "arrow.down.left" : "calendar.badge.clock", color: event.direction == .inflow ? FiscalColor.income : FiscalColor.debt)
        VStack(alignment: .leading, spacing: 2) { Text(event.title).font(.subheadline.weight(.semibold)); Text("\(event.date) · \(event.certainty == "expected" ? "预计" : "应还")").font(.caption).foregroundStyle(FiscalColor.tertiary) }
        Spacer(); Text(Money(minorUnits: event.amountMinor).formatted(showPositiveSign: event.direction == .inflow)).font(.subheadline.bold()).monospacedDigit().foregroundStyle(event.direction == .inflow ? FiscalColor.income : FiscalColor.expense)
      }.frame(minHeight: 52)
      Divider().padding(.leading, 45).opacity(0.35)
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
  .font(.caption2.monospacedDigit()).foregroundStyle(FiscalColor.tertiary)
}

private var currencyAxis: some AxisContent {
  AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
    AxisGridLine().foregroundStyle(Color.black.opacity(0.09))
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
      .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
  }.frame(minHeight: 46)
}

private func reportColor(_ hex: String?, fallback: Color = FiscalColor.tertiary) -> Color {
  guard let hex, let value = UInt(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
  else { return fallback }
  return Color(hex: value)
}

private func categoryRows(
  _ values: [SpendingCategoryRow], model: ReportingModel, showsBars: Bool = true
) -> some View {
  let maximum = max(1, values.map(\.rollup.personalRealizedMinor).max() ?? 1)
  return VStack(spacing: 0) {
    ForEach(values) { row in
      Button { model.lens = .spending; Task { await model.loadDrillDown(categoryID: row.categoryID) } } label: {
        HStack(spacing: 10) {
          FiscalIconTile(row.icon ?? "questionmark", color: reportColor(row.colorHex))
          VStack(alignment: .leading, spacing: showsBars ? 6 : 0) {
            HStack { Text(row.name).font(.subheadline.weight(.semibold)); Spacer(); Text(Money(minorUnits: row.rollup.personalRealizedMinor).formatted()).monospacedDigit() }
            if showsBars {
              GeometryReader { proxy in Capsule().fill(Color.black.opacity(0.055)).overlay(alignment: .leading) { Capsule().fill(reportColor(row.colorHex, fallback: FiscalColor.accent)).frame(width: proxy.size.width * CGFloat(max(0, row.rollup.personalRealizedMinor)) / CGFloat(maximum)) } }.frame(height: 7)
            }
          }
          Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary)
        }.padding(.vertical, 9).contentShape(.rect)
      }.buttonStyle(.plain)
      Divider().padding(.leading, 45).opacity(0.35)
    }
  }
}

private func accountRows(_ values: [CashFlowAccountRow], model: ReportingModel) -> some View {
  VStack(spacing: 0) {
    ForEach(values) { row in
      Button { model.lens = .cashFlow; Task { await model.loadDrillDown(accountID: row.accountID) } } label: {
        HStack { Text(row.name).font(.subheadline.weight(.semibold)); Spacer(); Text("+\(Money(minorUnits: row.metrics.inflowMinor).formatted())").foregroundStyle(FiscalColor.income); Text("−\(Money(minorUnits: row.metrics.outflowMinor).formatted())").foregroundStyle(FiscalColor.expense); Image(systemName: "chevron.right").font(.caption).foregroundStyle(FiscalColor.tertiary) }.padding(.vertical, 11)
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
          .background(Color.black.opacity(0.055), in: .circle)
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
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(
              [item.businessDate, item.accountName, item.categoryName]
                .compactMap { $0 }.joined(separator: " · "))
              .font(.caption).foregroundStyle(FiscalColor.tertiary).lineLimit(1)
          }
          Spacer()
          Text(
            Money(minorUnits: item.signedAmountMinor).formatted(
              showPositiveSign: model.lens == .cashFlow && item.signedAmountMinor > 0))
            .font(.subheadline.bold()).monospacedDigit()
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

private func debtAccountCard(_ account: DebtAccountRow) -> some View {
  FiscalCard(radius: 16) {
    VStack(alignment: .leading, spacing: 10) {
      HStack { Text(account.name).font(.headline); Spacer(); Text(Money(minorUnits: account.currentDebtMinor).formatted()).font(.headline).monospacedDigit().foregroundStyle(FiscalColor.debt) }
      if account.openingConfigurationRequired { Label("期初欠款尚未配置日期，不推测到期事件", systemImage: "calendar.badge.exclamationmark").font(.caption).foregroundStyle(FiscalColor.debt) }
      ForEach(account.cycles.filter { $0.remainingMinor > 0 }.prefix(4)) { cycle in
        HStack { VStack(alignment: .leading) { Text("还款日 \(cycle.dueDate)").font(.caption); Text(cycle.overdue ? "已逾期" : cycle.status).font(.caption2).foregroundStyle(cycle.overdue ? FiscalColor.expense : FiscalColor.tertiary) }; Spacer(); Text(Money(minorUnits: cycle.remainingMinor).formatted()).monospacedDigit() }.padding(.top, 7)
      }
    }
  }
}

private func installmentRows(_ groups: [DebtInstallmentGroup]) -> some View {
  VStack(spacing: 0) {
    ForEach(groups) { group in
      HStack { Text(group.month).font(.subheadline); Text("\(group.periodCount) 期").font(.caption).foregroundStyle(FiscalColor.tertiary); Spacer(); Text(Money(minorUnits: group.totalScheduledGrossMinor).formatted()).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(FiscalColor.debt) }.padding(.vertical, 10)
      Divider().opacity(0.35)
    }
    if groups.isEmpty { EmptyInline(symbol: "calendar", title: "没有未来分期计划") }
  }
}
