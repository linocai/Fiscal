# Apple 测试与资源收尾

在仓库根目录执行。这里只管理测试产物，不改 App 版本、业务代码或线上数据。

## 开始测试

先确认没有另一组 Apple 构建正在运行。`--directory` 必须是 `build/` 下的新目录，`--scope` 写具体测试范围，`--purpose` 为 `regression`、`visual-acceptance` 或 `diagnosis`。

```sh
python3 scripts/test_artifacts.py run \
  --directory build/test-runs/current-fiscalkit \
  --purpose regression --scope FiscalKitTests \
  -- xcodebuild -project App/Fiscal.xcodeproj -scheme FiscalmacOS \
  -destination 'platform=macOS' \
  -derivedDataPath /Users/linotsai/Library/Developer/Xcode/DerivedData/Fiscal-gxhyzwdownkctphiwckdkhzmywou \
  -only-testing:FiscalKitTests test
```

脚本记录源码commit、App未提交差异指纹、目的、日志、原始结果、按测试项摘要。成功、失败和可处理的中断都会落状态；强制结束后留下的 `pending` 也会被收尾检查发现。结果默认不导出附件；视觉检查只导出需要的测试，失败排查可加 `xcresulttool export attachments --only-failures`。不要修改用户scheme或另建DerivedData来绕过入口。

## 完成一轮问题修复或发布

先读取实际结果并提取摘要到当前版本 `archive`。判断哪些结果仍承担验收或未解决问题证据，不能根据名称、时间或单个成功标记自动推断替代关系。`keep` 要覆盖已有保留结果和本轮新增最终结果；`delete` 只列已授权的精确结果包/导出媒体路径。日志、运行摘要和发布物独立保留。

```json
{
  "keep": [
    {"path": "build/test-runs/final/tests.xcresult", "reason": "最终完整回归"}
  ],
  "delete": [
    {
      "path": "build/test-runs/old/tests.xcresult",
      "reason": "缺陷已修复并由最终回归覆盖",
      "evidence": ["archive/releases/<version>/qa/test-summary.json"]
    }
  ]
}
```

```sh
python3 scripts/test_artifacts.py plan --decisions <清单.json> --output <当前版本删除计划.json>
python3 scripts/test_artifacts.py apply --plan <当前版本删除计划.json> --receipt <当前版本删除回执.json>
python3 scripts/test_artifacts.py check --plan <当前版本删除计划.json> --output <当前版本清理核验.json>
```

`plan` 和 `apply` 分开，便于核对清单；已有用户授权时 agent 自行推进。删除前整批核验内容、位置、源码跟踪、证据和在用状态，再逐项删除并记录。根目录、符号链接路径、安装包/dSYM等不允许作为候选。`apply` 成功后把标准测试运行标为 retained/retired；`check` 对新出现未分类的结果/媒体、未收尾运行、保留件变化、未完成删除返回非零。

设备调试支持另执行全局 `~/.codex/scripts/apple_device_support.py`，按设备实际版本和新版服务/符号的就绪情况清理。构建目录与设备支持目录分别报告；目录占用下降与整盘可用空间变化分别计量，不能把APFS共享块当作确定释放量。

验证清理脚本：`python3 -m unittest discover -s scripts/tests -v`。该测试只使用临时合成文件，不启动App、不接触真实账本。
