---
description: "在 agent 循环的请求恢复点做提供方降级：当前提供方报余额、凭证或鉴权失败时，同一个 turn 改由配置好的备用提供方继续。"
kind: "package-reference"
---

# @deepseek-ai/dsh-llm-failover

[English](README.md) | 中文

## 概述

当提供方无法回答、而且重试也解决不了（账户余额不足、密钥被拒、账户需要重新登录）时，`dsh-llm-failover` 让这个 turn 继续活下去。它监听 `agent/request-error`，遇到上述失败码就在 agent 上选中链上的下一个提供方，并向循环返回 `{ kind: 'retry' }`，于是这次重试跑在备用提供方上，而不是把整个 turn 判死。

它是策略监听器，不是提供方：不建立连接、从不见请求体，也改不了模型在上一次失败请求里已经看到的内容——下一步是发给另一家提供方的全新请求。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用本包

```yaml
- id: llm-failover
  name: '@deepseek-ai/dsh-llm-failover'
  config:
    fallback:
      - provider: glm
        model: glm-4.6
    maxHops: 2
```

`codes` 默认取重试治不好的那些失败——`QUOTA`、`ACCOUNT_QUOTA`、`INVALID_CREDENTIAL`、`MISSING_CREDENTIAL`、`ACCOUNT_TOKEN_INVALID`、`ACCOUNT_SIGN_IN_REQUIRED`、`AUTH`。收窄它可减少降级，放宽它可覆盖某家提供方自己的拒绝码。链上每个备用提供方都必须已在 `ctx.llm` 注册，否则切换失败，交由提供方自身的恢复逻辑决定。

<a id="understand-the-implementation"></a>
## 理解实现

监听器挂在循环为失败请求抛出的持久化 agent 步骤边界上。它跳过刚刚失败的提供方（所以单项链也能覆盖双提供方部署），并按 turn 计跳数：超过 `maxHops` 就照没有本插件时那样上报失败，而不是在两个坏提供方之间打转。turn 变化时计数归零，因此一个早早就余额不足的 turn 不会饿死后面的 turn。选中提供方在下一个 `prepareRequest` 生效，这就是重试能离开失败提供方的原因。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- 依据错误码而非健康度选择备用：一直回 500 的提供方不会触发切换，因为重试可能治好那一次。
- 不切回。turn 一旦落在备用提供方上就留在那里直到该 turn 结束；新 turn 从配置的默认提供方开始。
- 失败的那次尝试仍作为独立的错误留在记录里，模型因此知道第一次请求没走通。

<a id="dev-note"></a>
## 开发备注

全部机制就是 `agent.model.select()`，插件不持有别的东西。若提供方 id 未注册，该调用会抛错，因此链上只列出组合里真的挂载了的提供方，否则只会得到一条告警，turn 照原样结束。