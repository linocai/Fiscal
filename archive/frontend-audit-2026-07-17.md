# Fiscal 前端 Bug 审查报告（2026-07-17）

> 范围：`apple/Sources/FiscalKit` 全部前端代码（约 1.4 万行）+ Apps 入口。
> 方式：五路并行细读审计，逐条在代码中核实。共 46 项问题（4 高 / 13 中 / 其余低）+ 3 处死代码。
> 本报告是 v1.2.0 修复施工的输入材料。行号为审查时快照，施工时以符号定位为准。

## 一、高严重度（4）

### H1 iOS 报销列表：筛选出空结果后被困在空态（确定）
`Features/ReimbursementScreens.swift:59-71`
`filterChips` 只渲染在 `model.claims` 非空的 ScrollView 分支里；一旦状态筛选（如「已取消」）返回 0 条，body 切到 `ContentUnavailableView` 空态分支，筛选条消失，而 `model.statusFilter` 仍保留。空态不可滚动、`.refreshable` 无从触发，无任何 UI 可清除筛选。空态文案还误导性显示「新建报销单后…」。

### H2 iOS 报销紧凑编辑器完全不展示错误信息，失败静默（确定）
`Features/ReimbursementScreens.swift:621-756`
`macEditor` 有 `macMessageBanner(model.message)`（约 778 行），iOS `compactEditor` 全篇没有渲染 `model.message`。`create()`/`preview()`/`update()` 失败（版本冲突、金额超限、网络错误）时 sheet 不关闭、无任何反馈。

### H3 报表页在 View init 里改共享模型，口径选择被随机重置（确定）
`Features/ReportingScreens.swift:285-288`（`IOSReportsScreen.init`）
`model.lens = initialLens == .cashFlow ? .spending : initialLens` 写在 init 里。该 View 由 `IOSRootView` 的 `navigationDestination` 闭包构造，父视图任何一次 body 重算（如 `aiProposals.pendingCount` 变化）都会重新构造它、init 重跑，把用户切到「负债」的选择器拨回「消费」。同时是「视图更新期间修改 @Observable 状态」反模式。

### H4 切换交易类型残留不兼容分类/账户，validate 只查非空（确定）
`Features/TransactionModels.swift:252-261`（`changeKind`）、`284-301`（`validate`）
支出↔收入切换保留 `categoryID`（方向已错）；转账↔还款保留 `destinationAccountID`（信用/非信用错配）；收入→信用消费保留非信用 `accountID`。validate 对这些只查非空。Picker 因 selection 不在选项列表显示为空，用户难察觉；最坏写入方向错误的流水。

## 二、中严重度（13）

### 交易
- **M1 iOS 已作废流水仍可编辑/再作废/创建分期（确定）** `Features/TransactionScreens.swift:486, 535-541`。条件只有 `item.isUserEditable && item.installmentPlanID == nil`，`isUserEditable` 不看 `voidedAt`。对照 `MacTransactionWorkbench.swift:257, 261` 有 `voidedAt == nil`，iOS 是漏的一侧。
- **M2 高级筛选双向绑定 model，不点「应用」关闭后筛选与列表脱节（确定）** iOS `TransactionScreens.swift:585-641`、mac `MacTransactionWorkbench.swift:315-356`。筛选项直接绑 `$model.xxx`，只有「应用」才 `load()`；关掉 sheet/popover 后图标显示激活、列表还是旧结果，后续 `refreshAfterMutation` 会突然用新筛选重载。
- **M3 iOS 批量选择 selectedIDs 不随刷新收敛（确定）** `TransactionScreens.swift:388, 568, 751, 762-771`。mac 有 `selection.formIntersection`（Workbench:80-82），iOS 没有；「已选 N 笔」虚高，全失效时 `batchClassify` 因 `items.isEmpty` 返回 false 且无提示。
- **M4 iOS 批量分类失败错误被 sheet 遮挡（确定）** `TransactionScreens.swift:659-690, 762-771`。错误写进主界面 banner / alert（挂在 437 行主视图），sheet 在上层看不到；sheet 内无错误展示区。

### 报销
- **M5 iOS「确认保存」不校验 valid，非法金额文本不使预览失效（确定）** `ReimbursementScreens.swift:747, 1255-1258, 752-754`。`amountTextBinding` 非法文本只改 `amountTexts` 不动 `parties`，`onChange(of: parties)` 不触发、`claimPreview` 不失效；iOS「确认保存」只 `.disabled(model.isMutating)`。mac 端（926 行 `.disabled(!valid || …)`）不受影响。
- **M6 预览状态跨编辑会话泄漏（确定）** `ReimbursementScreens.swift:470-484, 501, 505, 521-525, 722-736`；`ReimbursementModel.swift:317-326`。`receiptPreview`/`claimPreview` 是模型全局状态，编辑器 dismiss 不清；重开 sheet 显示上一张单的预览、按钮直接变「确认到账」。
- **M7 回款编辑器按「分」输入、报销单编辑器按「元」（确定）** `ReimbursementScreens.swift:433, 458, 543`。回款金额框 `Int64(amount)` 当分、预填 `String($0.amountMinor)`；相邻表单单位不一致，极易 100 倍录错；iOS numberPad 无法输小数点。应统一走 `CNYAmountParser` 按元。

### 报表
- **M8 切换 lens 不清 drillDown，跨口径数据混列（确定）** `ReportingModel.swift:18`（lens 无 didSet）、`ReportingScreens.swift:505, 537`、`ReportingModel.swift:124-126`。mac「消费」下钻后切「现金流」，旧下钻列表仍渲染，「加载更多」用新 lens + 残留 `drillCategoryID` 发请求，两种口径混入同一列表。
- **M9 总览页出现即重置报表月份（确定）** `ReportingScreens.swift:117`（iOS）、`:399`（mac）。总览 `.task { await model.ensureCurrentMonth() }` 作用于与报表页共享的 ReportingModel，用户翻到历史月→瞄总览→月份被重置、下钻被清。修复方向：总览与报表页月份状态解耦，或 ensureCurrentMonth 不动报表已选月份。

### 主数据 / 分期 / 现金流
- **M10 新建信用账户不动 Stepper 必然校验失败（确定）** `MasterDataScreens.swift:174-176` + `MasterDataModels.swift:75`。`AccountDraft.statementDay/dueDay` 初始 nil，Stepper Binding `?? 1` 只做显示回退不回写；UI 显示「账单日：1」但 validate guard 失败。
- **M11 分期创建页复用上一笔消费的过期 eligibility（确定）** `InstallmentScreens.swift:133, 142-149`。`InstallmentModel.eligibility` 从不清空、不校验 `purchaseTransactionID == purchase.id`；对消费 B 的请求失败时沿用消费 A 的额度与起始账单日选项。
- **M12 现金流历史月份翻页响应乱序竞态（确定）** `CashFlowModel.swift:31-42`。`loadHistory()` 无 generation 守卫、不校验 `history.month == historyMonth`；连续翻页时标题新月份、列表旧月份。同文件其他模型均有守卫。
- **M13 编辑手动现金流项丢备注（疑似）** `CashFlowScreens.swift:363-462`（draft 构造 452-458）。`CashFlowEditorSheet` 无备注输入、`seed()` 不读 `item.note`，draft note 恒 nil，请求走 PUT 全量替换（`FutureCashFlowReplace`），带备注的手动项编辑一次备注可能被清。系统项编辑器反而有备注框。修复：编辑器补备注框或至少透传原 note。

### 基础设施
- **M14 在途 GET + 变更并发击穿缓存失效不变量（确定）** `API/APITransport.swift:87, 145-164`（对照 `HTTPResponseCache.swift:15-16` 注释承诺）。(a) 变更成功 `removeAll()` 后，变更前发出的在途 GET 完成时把旧响应写回缓存，旧数据可再活 30 秒；(b) 变更后同 URL GET 会并入变更前的在途 GET 任务。例：撤销设备后列表仍显示它。
- **M15 GET 先入缓存后解码，坏报文被缓存且无法踢除（确定）** `APITransport.swift:87-89, 77-78`。解码失败的报文已 store；30 秒内同键全走缓存路径抛 `invalidResponse`，不删坏条目、不回退网络。修复：解码成功后再 store；缓存路径解码失败时删条目并回源。

## 三、低严重度（19）

- **L1 分期编辑器强解包（疑似崩溃）** `InstallmentScreens.swift:180`：`purchase.accountID!` / `categoryID!`，DTO 均为 `UUID?`。
- **L2 OCR 行排序比较器违反严格弱序（疑似）** `OCRInputService.swift:32-35`：`abs(verticalDifference) > 0.02` 容差比较不传递，`sorted(by:)` 行为未定义，密集小字可能错序、debug 断言崩溃。修复：先按容差聚类分行再排序，或用确定性主键排序。
- **L3 AI 提案 loadMore 不过滤 CancellationError（确定）** `AIProposalModel.swift:64-74`：视图销毁取消分页会弹「AI 提案暂时无法读取」红色横幅。对照 Credit/InstallmentModel 均有 `catch is CancellationError {}`。
- **L4 AI 提案编辑器金额无效保存静默（确定）** `AIProposalScreens.swift:348-352`：guard return 无任何提示。
- **L5 AI 设置保存后补充 GET 失败误报「保存失败」；saveProvider 缺 generation（确定/疑似）** `AISettingsModel.swift:61, 88, 66-93`：设置已保存成功但返回 false，重试撞 `expected_version` 冲突。
- **L6 现金流转账入账缺转入账户校验（确定）** `CashFlowScreens.swift:512-517`：`destinationID` 可 nil 或与 `accountID` 相同即提交（对照 EditorSheet:451 有校验）。
- **L7 新建还款 cycleID 不在 cycleOptions 时超额校验被跳过（疑似）** `TransactionScreens.swift:43, 294-300, 336`：`cyclesForRepayment(retaining:)` 只对编辑保留账期。
- **L8 系统现金流项编辑器把 expected 静默改 confirmed（疑似）** `CashFlowScreens.swift:313-314`：`initialValue: item.status == .completed ? .completed : .confirmed`。
- **L9 已取消报销单仍可编辑/作废回款（疑似）** `ReimbursementScreens.swift:338-349`：菜单只看 `archivedAt == nil` 不看 cancelled 态（对照矩阵编辑 `matrixFrozen` 与「恢复回款」345 行均拦截）。
- **L10 回款预览无 generation 守卫（确定）** `ReimbursementModel.swift:230-243, 264-279`：`previewReceipt`/`previewReceiptReplacement` 迟到响应覆盖已失效预览（提交侧有 request 相等守卫兜底，仅 UI 误导）。
- **L11 iOS 交易「清除筛选」不重置 kind、不触发 reload（确定）** `TransactionScreens.swift:425, 701-706` + `TransactionModels.swift:53-57`：`hasAdvancedFilters` 含 `kind != nil` 但 sheet 无 kind 控件，图标常亮。
- **L12 loadOptions 重试成功后偏好覆盖用户已手选类型/账户（确定）** `TransactionScreens.swift:322-325`：首载失败时 `didApplyPreferences` 仍 false，重试成功回调 `apply(preferences:)` 重置类型。
- **L13 CancellationError 分支重置 phase 缺 generation 守卫（确定）** `InstallmentModel.swift:63`、`CreditModel.swift:41, 52`：旧请求取消把新请求的 phase 打回 `.idle`（对照 `InstallmentModel.loadAccount:51` 有守卫）。附带：`CreditModel.task` 从未赋值、`task?.cancel()` 是死代码。
- **L14 分页 isLoadingMore 竞态窗口（疑似）** `TransactionModels.swift:91-104, 187-189`：被取消旧请求的 defer 清掉新请求置的 true，短窗允许第三个并发分页。有去重兜底。
- **L15 查询参数 `+` 不转义（确定）** `APITransport.swift:67`：`URLComponents.queryItems` 保留字面 `+`，FastAPI `parse_qsl` 解成空格；搜「7+1」「C++」结果错。入口 `TransactionRepository.swift:44`、`ReimbursementRepository.swift:116`。
- **L16 网络请求不响应调用方取消（确定）** `APITransport.swift:147-164`：非结构化 Task + `task.value` 吞取消，视图销毁后请求拖到完成/15s 超时；152-155 行的取消映射永远等不到调用方取消。`requestNoContent` 路径反而可取消，行为不一致。
- **L17 TransactionDTO 用 `decode(Optional.self)` 而非 `decodeIfPresent`（疑似）** `TransactionDTO.swift:69-77`：后端某天省略键（而非发 null）则整页解码失败。
- **L18 removeCurrentDevice 部分失败留死 token 且提示误导（确定）** `DeviceSecurityModel.swift:130-140`：服务器已撤销、Keychain 删除失败时 phase/status 不变，此后全部 401 无引导。
- **L19 显示细节一组（确定）**：
  - CSV 导出文件名 UTC 日期，北京时间 0-8 点差一天：`SettingsScreens.swift:233, 665`（`Date.now.ISO8601Format().prefix(10)`），应用 Asia/Shanghai。
  - 「净额才显示 +」靠 `label.contains("净额")` 字符串 hack，双端不一致：`ReportingScreens.swift:59`。
  - 负号双端不一致：iOS U+2212（`TransactionScreens.swift:13`）vs mac/Money ASCII `-`（`MacTransactionWorkbench.swift:467`、`MoneyFormat.swift:13`）。
  - Workbench 检查器按钮三元两支同图标：`MacTransactionWorkbench.swift:147`（`"sidebar.right" : "sidebar.right"`）。
  - iOS 报销 compactEditor 误用 `FiscalColor.macBackground`：`ReimbursementScreens.swift:738`。
  - 现金流日期钉死 Asia/Shanghai 与 DatePicker 本地时区可差一天：`CashFlowModel.swift:124-143`（东八区内使用无实际影响）。
  - 负债页 `cycles.prefix(4)` 形同虚设，DTO 只装 `nextDueCycle` 单元素：`ReportingDTO.swift:370` + `ReportingScreens.swift:723`；`DebtReport.cycles` 全量数据解码后无 UI 使用（疑似，取决于服务端语义）。

## 四、死代码（建议删除）

- **D1 `MacTransactionsScreen`** `TransactionScreens.swift:775-1003`：全仓无引用（mac 用 Workbench）。内藏 bug：作废可编辑（954）、`sourceName` 缺 "system" 多 "ai"（984）、未选中 chip 硬编码 `.white` 深色模式刺眼（873）、搜索无防抖 + 初载中输入被 `snapshot == currentQuery()` 丢弃致 spinner 卡死（839 + TransactionModels.swift:82）。
- **D2 `IOSCashFlowScreen` / `MacCashFlowScreen`** `ReportingScreens.swift:225, 458`：无构造点；`IOSCashFlowScreen:271` 点击发 drillDown 请求却不渲染结果，还污染共享 lens。
- **D3 总览 fixture 硬编码假数据**：`SharedOverviewComponents.swift:13, 16`（「较上月 ↓ 8.2%」「7月1日–14日」硬编码，`OverviewSnapshot.previousMonthDelta` 从未被读）、`MacOverviewScreen.swift:40-43`、`IOSOverviewScreen.swift:43`（AI 角标恒 "1"）。当前仅 #Preview 引用，接入真实离线路径前必须改为读 snapshot。

## 五、横向规律（修复时按模式统一扫）

1. **双端防护不对称**：作废校验、valid 校验、selection 收敛、错误横幅——漏的几乎都在 iOS 侧。修一处时对照另一端。
2. **预览/派生状态不随输入失效**：报销预览、分期 eligibility、报表 drillDown 同一模式。
3. **缺 generation 竞态守卫**：CashFlow.loadHistory、回款预览、CancellationError 分支。仓里已有正确样板（ReportingModel、InstallmentModel.loadAccount），照抄即可。
4. **错误提示链路**：iOS 多个 sheet 内无错误展示区，错误写在被遮挡的主界面上。

## 六、审查确认无问题的部分（勿重复排查）

分页去重与 generation 守卫（Reimbursement/Reporting load 系列）、乐观版本号传递、`Money.formatted` 与 `CNYAmountParser` 边界（实测）、`.iso8601` 小数秒解码（26.0 目标实测支持）、`Color(hex:)`、Keychain 存取、各薄传输层 Repository、`FutureCashFlowReplace.encode` 双容器写法、AIInputSubmission 幂等键、`installIssuedToken` 的 `expectedVersion: 1`（已对照后端 security.py:216）。
