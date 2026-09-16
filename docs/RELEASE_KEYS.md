# 发布密钥与签名

汲作正式分发用 Developer ID Application 签名，再用 notarytool 公证。Sparkle 更新通道另有一对签名密钥。

## 这台机器上有什么

- Developer ID Application 身份在本机钥匙串里，不进仓库。
- `notarytool store-credentials` 保存的公证凭据名称由打包命令 `--notary-keychain-profile` 传入。
- Sparkle 更新签名私钥只在本机。

## 硬性规则

- 私钥、公证 App 专用密码、Sparkle 私钥不得写入仓库、日志、截图、诊断导出或测试夹具。
- `config/app-release.json` 只放公开的版本号、bundle id 和更新地址。
- 本文件只说明流程，不含任何密钥材料。
