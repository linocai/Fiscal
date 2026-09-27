# V2.4.0 Build50 快修验证

用户于 2026-09-27 授权修复独立复审的两项 P2；累计基线仍为 `2d5cc840c4a558ced3fa5753606a9542c0f92618`，完整工作区未提交。仅本地实现/验证/复查，不发布。

## 后端

- 两条 P2 的服务/HTTP 回归：商户精确建议→确认/纠正/解除→v2 月报 merchants 归类；同 key 重放、版本冲突和 ABA；回款 A/B 重排、其他回款、同额备注、调减/调增、作废恢复。
- 本机隔离 PostgreSQL 全量 438 passed / 0 failed / 0 skipped，114.30 秒；Ruff、format（204 files）、Pyright 0/0、diff check 通过。
- 唯一新建测试库 `fiscal_v240_build50_backend_927a` 删除前 29,715,803 bytes、0 活跃连接；drop 后 pg_database 查询数量 0。无远端操作，无后端临时文件保留。

## Apple

- `v240-build50-fiscalkit-verified`：335/335；最终新增别名框采用空白默认值后 `v240-build50-merchant-final` 6/6，旧别名不会随商户更正被误提交。
- 首轮编译发现 DELETE 版本编码 Int/Int64 不匹配，已修复；`v240-build50-fiscalkit` 被后续通过测试替代。
- 最终 `v240-build50-merchant-lifecycle` 6/6；`v240-build50-merchant-ios-final` 和 `v240-build50-merchant-macos-final` 均 1/1，正式交易详情→识别建议→确认→成功回执可见。双端截图已目视检查，原件保留于对应结果包。
- 最终 FiscaliOS generic iOS Simulator 与 FiscalmacOS App target 的 Debug 构建均成功；实包核验版本 2.4.0、Build50、最低 27.0，见 `build50-products.json`。此前 iOS Release Simulator 构建成功，但早于最终生命周期小改，不将它算作最终 Release 验收。
- macOS UI 首轮 `v240-build50-merchant-macos`：runner 开启 automation 超时，未到业务断言；最终重试已通过。
- iOS UI 首轮 `v240-build50-merchant-ios`：确认后全局刷新让底层详情暂时移除，嵌套编辑页消失，成功回执断言失败。已把全局刷新推迟到 editor.onDisappear，原子记录是否有已确认写入，finishEditing 幂等发布一次；最终 6 项单测与双端 UI 均通过，未弱化页面断言。
- 设备支持只读审计 `device-support-build50.json`：audited，deleted=[]，pending_devices=[]。真机选图、通知、快捷指令未新增验证。

## 独立复查与资源

独立 reviewer 已确认原两项 P2 的实现闭环，最终 editor 生命周期变更也已单独复查无 finding。复查限两项修复与直接影响范围，未进行生产迁移或真机安装。最终 App+Backend（tracked/untracked、含删除标记）的代码 SHA256 为 `648e00bdcbf6b0a34a2cbdfde5bca990ee6fba3d0a0823c6994e12acc055bc86`，统计见 `build50-metrics.json`。

- `cleanup-build50-check.json` complete，无未分类产物、未收尾运行、变化的保留证据或剩余待删项。
- 两次精确 plan→apply→check 删除 4 份被替代结果包及 3 份截图导出副本；保留本轮全量/最终针对性/双端 UI 共 4 份结果包及既有历史证据。保留每轮日志和结构化摘要。
- `scratch-build50-plan.json`/receipt 核对指纹及 lsof 后清理 12 份副本/索引/合成文件，共 23,866 bytes，其中系统临时目录 3 份文件均逐字节匹配测试夹具。任务相关临时文件复查为空，无任务运行进程、无远端目录；用户 AGENTS 与六份 scheme 7/7 原哈希不变。
- `build/test-runs` 逻辑占用 228,005,469→103,803,764 bytes；`build/v240/build50` 1,639,236→442,642 bytes。最终 App 留在既有 DerivedData，未替换正式安装；设备支持审计无待处理设备。
