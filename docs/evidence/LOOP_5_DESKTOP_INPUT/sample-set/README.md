# Loop 5 PRD §12 样本集

本目录是手动链接验收的“验货单”，不是网页内容归档。`sample-manifest.json` 固定 20 条脱敏记录：10 条静态页面（含 GitHub 公开仓库 README 基线）、5 条客户端渲染页面、3 条登录可见页面、2 条故意失败页面。

## 字段语义

- `expectedTitle`：标题应包含的稳定标记。
- `expectedBodyStart` / `expectedBodyEnd`：正文前/后 1,200 个 Unicode scalar 中应出现的标记；故意失败页允许为空。
- `minimumCharacterCount`：成功捕获可接受的最少正文字符数。
- `completenessLabel`：production 手动抓取为 `best_effort`；登录页与故意失败分别记录 `extension_required` / `expected_failure`。
- `allowedDegradationPaths`：主路径不可用时唯一允许的用户体验，不授权放宽 URL/IP/TLS 安全策略。

登录样本使用 `.test` URL 和合成 HTML，只验证“提示改用浏览器扩展”的降级语义；fixture 不含真实账号、Cookie、Token、会话或私有正文。公开网络结果必须来自 `PeerBoundNetworkWebPageFetcher`，fixture 结果不能替代 production 网络成功。

## 验证入口

在 `apps/desktop` 构建目标后运行：

```bash
.build/debug/LinkDigestManualSampleVerifier validate-manifest ../../docs/evidence/LOOP_5_DESKTOP_INPUT/sample-set/sample-manifest.json
.build/debug/LinkDigestManualSampleVerifier verify-network ../../docs/evidence/LOOP_5_DESKTOP_INPUT/sample-set/sample-manifest.json /private/tmp/linkdigest-loop5/network-results.json
.build/debug/LinkDigestManualSampleVerifier verify-fixtures ../../docs/evidence/LOOP_5_DESKTOP_INPUT/sample-set/sample-manifest.json /private/tmp/linkdigest-loop5/fixture-results.json
```

若本机 DNS/代理把公网域名映射到私网、保留或 benchmark/test-net 地址，production policy 必须继续拒绝；报告将该轮标为 `environment-blocked`，不得注入假 resolver 或修改 `PublicWebURLPolicy` 换取通过。
