# Native Host 卸载

卸载前先运行只读计划（必须显式选择浏览器）：

```bash
./scripts/native-host/uninstall-plan.sh --browser chrome
./scripts/native-host/uninstall-plan.sh --browser brave
./scripts/native-host/uninstall-plan.sh --browser edge
```

Brave 150 的当前 macOS 用户级查找会映射到 Chrome 的
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`，因此
`--browser brave` 与 `--browser chrome` 打印同一个精确目标；不扫描或删除
`BraveSoftware` 目录。Edge 只有显式 `--browser edge` 才会显示其目标。

`uninstall-plan.sh` 永远只读：它只打印目标存在状态、同一 basename 的备份和人工
`rm`/恢复命令，不执行任何删除、覆盖或恢复。请先检查计划输出，再由人工执行命令。

如果安装脚本在临时文件写入或同目录 rename 期间失败，`EXIT` trap 会保留并打印
临时文件路径；不会自动清理。请先人工检查该路径，再按项目安全规则决定后续处理。
