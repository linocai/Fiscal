# V2.2.0 build 40 · 完整 Review

2026-09-06（Asia/Shanghai）。以下为**修复前的完整 Review 原始记录**：确认 8 项 P2、1 项 P3 及 1 项设计验收偏差，未发现 P0/P1。

**修复状态：R1–R9 与 D1 已修复并通过针对性回归、完整单测及双端 App 构建。** 原发现保留用于溯源；修复后的事实、截图与限制见 [FIX_REPORT.md](FIX_REPORT.md)。尚未发布。

## 范围与证据

比较已发布实现 `353c381` 与当前工作区（HEAD `96d2f9a`），以 `PROJECT_PLAN.md` 的 V2.2.0 全应用要求为准。Reviewer 已逐一检查 30 个改动源码文件（含新增共享组件、两根、全部改动专项页、连接和状态组件）；主会话交叉核对调用链、参考图、实际截图、构建与测试产物，并补查 Mac 真实窗口交互。受保护的六个 scheme 为用户原有状态，排除归因。

已有 408 项单测、35 项不同 UI 用例及双端 App 构建的记录已核对，不能据此认定下列路径已覆盖。Mac 账户浮层的连续原生按键整窗回放通过；XCTest 启动框架超时，没有将其计为自动测试通过。详细方法和边界见 [REVIEW_EVIDENCE.md](REVIEW_EVIDENCE.md)，审查文件指纹见 [review-source-manifest.json](review-source-manifest.json)。

## R1 · P2 · Mac 从设置或专项页直接回总览/账户，仍显示写入前的数据

- 定位：[V151MacWorkspace.swift:1319](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151MacWorkspace.swift:1319)。
- 触发：在设置保存、归档账户，或在信用、分期、报销、现金流页面完成写入，然后直接点侧栏“总览”或“账户”。
- 原因与影响：`navigateRoot` 只在目标为 `.timeline` 时刷新根模型。专项页各自更新自己的 model；账户根页继续使用旧 `ledger.accounts`，总览继续使用旧 `facts/ledger`。用户会看到旧余额、已归档账户或缺少新账户，直到进入交易页或重启等其他路径触发刷新。
- 修复方向：向根传递已确认写入通知，或在离开可变模块回任一阅读空间时刷新受影响的共享数据，保留当前选择与范围。
- 回归：新增/归档账户、报销到账或还款后，分别直接点总览和账户，核对列表、余额、净额与月报更新。

## R2 · P2 · Mac 总览最近交易继承交易页筛选，点击行也不打开该笔详情

- 定位：[V151MacWorkspace.swift:1903](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151MacWorkspace.swift:1903)；行操作在 1909 行，根回调在 1256 行。
- 触发：在交易页或侧栏浮层选择账户、月份或搜索范围，再进入总览；随后点击某条最近交易。
- 原因与影响：新总览直接读取共享 `ledger.items.prefix(3)`，并未定义独立的全账本最近交易查询。上方金额维持全账本口径，下方交易却被旧筛选限制。“查看全部”与每条交易都调用不带 ID 的 `openLedger`，不能定位点击的交易。
- 实测：总览初始有两笔交易，浮层选择“测试账户5”再返回总览，显示“当前范围暂无正式交易”；总览没有提示该账户筛选。
- 修复方向：独立读取全账本最近交易；行跳转明确携带交易 ID，列表入口与详情入口分别处理。
- 回归：账户/月份/关键词筛选后，总览近期结果保持正确；点击第二笔后展示第二笔详情而非列表或旧 inspector。

## R3 · P2 · iPhone 交易 Tab 加载后，总览最近交易跳转不再消费目标 ID

- 定位：[V151IOSWorkspace.swift:68](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151IOSWorkspace.swift:68)；刷新分支在 1069–1071 行，详情初始加载在 1431 行。
- 触发：先进入交易 Tab，再回总览点击任意最近交易；或查看一笔后返回，再点另一笔。
- 原因与影响：原生 `TabView` 保留交易页 State；`hasLoadedInitialContent` 变为 true 后，新的 `focusID` 虽触发 `.task(id:)`，但只执行 `refreshPreservingContext()`。该函数重载旧 `selectedID`，不消费新 `focusID`。旧 switch 根会重建交易页，本次导航改造使这一假设失效。
- 修复方向：区分“保留上下文的数据刷新”和“打开指定交易”的新导航意图；新意图必须更新选择并加载对应详情。同一笔重复打开也应可用，不能仅靠未变化的 ID 充当触发器。
- 回归：先逛交易、关闭详情后重复点同一笔、再点另一笔，均应打开正确详情且没有旧选择覆盖。

## R4 · P2 · Mac 总览待办打开失败无反馈，成功后的返回空间也不正确

- 定位：[V151MacWorkspace.swift:1259](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151MacWorkspace.swift:1259)；打开逻辑在 692–710 行，总览行在 1952 行。
- 触发：从总览点“接下来要处理”中的信用账期、报销或现金流事项。
- 原因与影响：回调复用固定以 `.timeline` 为来源的 `openKnownFuture`。成功打开专项页后返回“交易”，丢失总览来源；离线、网络失败或归属变化时，错误只保存在 `knownFutureOpenPhase`，其展示组件只存在于交易页。总览按钮没有进度和错误，表现为点了没反应。
- 实测：在不提供所属账期接口的隔离 fixture 中点“信用卡还款”，保持在总览且没有可见反馈。正常所属页成功路径未在该 fixture 验证，返回错误来源由源码确定。
- 修复方向：传递真实打开来源，并把该次请求的加载、失败和重试状态展示在总览对应事项附近。
- 回归：总览事项成功打开后回总览；离线、接口失败、来源变化均可读到原因并能安全重试。

## R5 · P2 · Mac 账户页把读取失败和真实空账本当作搜索无结果

- 定位：[V151MacWorkspace.swift:2048](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151MacWorkspace.swift:2048)；空态分支在 2061–2065 行。
- 触发：账户引用加载中、请求失败或真实没有账户时进入新账户页。
- 原因与影响：页面直接过滤 `ledger.accounts`，不判断 `ledger.referencePhase`。空数组统一显示“没有符合当前搜索条件的账户”，即使没有输入任何搜索；读取失败也没有错误和重试。已有数据时则可能无提示地继续显示旧列表。
- 修复方向：先处理 loading/error/retry/true-empty，再在成功数据内处理搜索空态；可参考同文件 `accountBalanceBoard` 与 iPhone 账户页的状态分支。
- 回归：慢请求、失败重试、零账户、成功但搜索无结果分别呈现正确状态。

## R6 · P2 · iPhone 空账本的最近交易永远显示加载骨架

- 定位：[V151IOSWorkspace.swift:390](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151IOSWorkspace.swift:390)。
- 触发：最近交易请求成功返回空数组，例如尚无交易的新账本。
- 原因与影响：`V15LedgerModel.load()` 在空数组时设置 `.empty`，但新首页只在 `.loaded` 内检查 `items.isEmpty`；真实 `.empty` 落入 default 的 `V15LoadingSkeleton`。成功空结果因此一直显示成加载中。
- 修复方向：显式处理 `.empty`，仅在 `.idle/.loading` 展示骨架。
- 回归：空账本读取完成后显示真实空态，创建第一笔并刷新后显示交易。

## R7 · P2 · iPhone 最近交易没有加载分类引用，正常分类也显示不可读取

- 定位：[V151IOSWorkspace.swift:469](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151IOSWorkspace.swift:469)；分类显示在 378–379 行。
- 触发：总览最近交易含有非空 `categoryID`。
- 原因与影响：新增 `recentLedger` 只调用 `load()`，没有调用 `loadReferences()`；其 `categories` 始终为空。`categoryName(_:)` 对正常分类 ID 返回“分类信息不可读取”，让本来完整的交易看起来数据异常。
- 修复方向：同时加载所需引用，或使用包含显示名称的既有可信读结果；真正的引用失败应有清楚的降级状态。
- 回归：正常分类、未分类、引用失败三种情况分别显示正确名称/状态。

## R8 · P2 · iPhone 大字体下，最近交易的金额被截断

- 定位：[V151IOSWorkspace.swift:373](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151IOSWorkspace.swift:373)，金额在 382 行。
- 触发：iPhone 使用辅助功能大字体，最近交易带较长标题或大金额。
- 证据：[实际 AX5 截图](screenshots/ios-overview-ax5.png) 中工资金额显示为“+9,99…”，标题和日期也被挤成“午…”、“2026…”。
- 原因与影响：新增行固定使用横向 HStack，标题和金额争夺宽度；金额组件的单行文字被截断。语音标签保留完整金额不能替代大字体用户的视觉阅读，且违背项目明确的金额不截断要求。
- 修复方向：大字体时切换纵向排版，使用完整可读取的金额呈现；沿用首页已有金额横向滚动方案或同等可达方案。
- 回归：AX5、长标题与极大正负金额，肉眼可读出完整金额；不能只断言元素存在或按钮可点击。

## R9 · P3 · Mac 总览缺少离线快照及待同步说明

- 定位：[V151MacWorkspace.swift:1794](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151MacWorkspace.swift:1794)。
- 触发：Mac 正在使用离线快照或存在待同步写入时停在新总览。
- 原因与影响：总览只根据 `factsPhase` 显示金额，未展示已有的离线/待同步说明；用户难以判断金额是否实时、是否包含尚未同步的记账。交易页已有相关 banner，iPhone 总览也保留了提示。
- 修复方向：在总览可见位置展示快照时间、离线状态及待同步数量，明确金额是否包含待同步变更。
- 分级理由：没有发现绕过底层离线写入限制，问题属于信息表达，不按记账安全失效升级。

## D1 · 设计验收偏差 · Mac 首页没有兑现待办优先级

- 定位：[V151MacWorkspace.swift:1809](/Users/linotsai/Lino/Fiscal/App/Sources/FiscalKit/V15/AppShell/V151MacWorkspace.swift:1809)。
- 已确认参考要求第一眼读到钱、债务、月度流动和下一笔事项；计划 3.2 的顺序也将“接下来要付”放在“最近交易”之前。
- 实际 [1280×820 深色截图](screenshots/mac-overview-dark.png) 中，净额卡固定占较大高度，随后是一整行月报及图表；首屏底部才露出最近交易标题，待办还在后面。不是颜色问题，而是工作台内容优先级没有落地。
- 建议收紧顶部指标，将月度图与近期待办在适当窗口宽度下并列，确保“下一件要处理的事”进入正常窗口首屏；窄窗口至少保持待办先于历史流水。这里依据内容与阅读任务验收，不要求逐像素复刻生图。

## 后续门禁

先修复 R1–R8 并补相应重复导航、失败/空态及视觉断言，再处理 R9 和 D1；完成后进行针对性复审。已通过的账户浮层整窗人工回放不再列为未验证交互，但自动化框架初始化问题仍须与产品缺陷分开记录。

本次没有提交、推送、发布或替换客户端，也未运行真实账本写入。已有单测、Gallery 与隔离宿主验收不能代替全部真实设备/服务路径；这些边界保留在证据记录中。
