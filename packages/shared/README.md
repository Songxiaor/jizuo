# Shared Contracts

`@linkdigest/shared` 是旧 TypeScript 主干建立的协议原型。SwiftUI 路线确认后，它**不再是跨语言合同的唯一真相源**；在 V0.1 实施前，需要迁移为 JSON Schema 或“语言中立 schema + 同一组 Swift/TypeScript fixtures”。

## 职责

- `src/common.ts`：ID、时间、消息元数据与可解释错误。
- `src/local.ts`：当前页捕获、任务、快照、运行和结果。
- `src/cloud.ts`：旧远期云端模型原型；不进入 P0 实现。
- `test/contracts.test.ts`：成功、版本不兼容、字段不一致和秘密字段拒绝测试。

这个包当前只定义 TypeScript 侧数据形状和运行时校验，不读取页面、不访问数据库、不调用模型，也不包含 API Key、Cookie 或真实账号数据。Swift 端不能通过复制这些类型形成第二套真相源。

## 验证

```bash
pnpm --filter @linkdigest/shared typecheck
pnpm --filter @linkdigest/shared test
```
