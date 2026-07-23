# Native Host 卸载

卸载前先运行只读计划（必须显式选择浏览器）：

```bash
./scripts/native-host/uninstall-plan.sh --browser chrome
./scripts/native-host/uninstall-plan.sh --browser brave
./scripts/native-host/uninstall-plan.sh --browser edge
```

Chrome 与 Brave 的任一计划都会显示同一个 active leaf：
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.syc.linkdigest.v01.json`。
因此人工实际删除这个 leaf 会同时影响 Chrome 和 Brave 两个支持行；先确认计划输出，再决定是否执行。
Edge 继续使用独立的 `~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/`；只有显式
`--browser edge` 才会显示它。脚本不扫描未选浏览器目录，也不会自动处理旧
`BraveSoftware/Brave-Browser` leaf、其 backup 或 legacy receipt entry。

`uninstall-plan.sh` 永远只读：它只打印目标存在状态、同一 basename 的备份和人工
`rm`/恢复命令，不执行任何删除、覆盖或恢复。请先检查计划输出，再由人工执行命令。

如果安装脚本在临时文件写入或同目录 rename 期间失败，`EXIT` trap 会保留并打印
临时文件路径；不会自动清理。请先人工检查该路径，再按项目安全规则决定后续处理。
