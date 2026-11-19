---
description: "ctx.reverse 能力缝及其本地套接字提供者：一条通往 SpringBoard 常驻端的 NDJSON 连接，凡是会改变目标的操作先经审批。"
kind: "package-reference"
---

# @deepseek-ai/dsh-reverse-bridge

[English](README.md) | 中文

## 概述

`dsh-reverse-bridge` 定义 `ctx.reverse`，并经常驻端的 Unix 域套接字提供它。三个调用：`state`（常驻端是否可达）、`status()`（常驻端自述：协议版本、操作列表、运行时长）与读操作的 `call(op, args)`。第四个 `mutate(op, args, options)` 只用于改变运行中目标的操作——内存写、hook、注入——它在打开的 turn 内先问审批服务。提供者是本包的默认导出，把包装进组合即按默认套接字路径挂载。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用本包

```yaml
- id: reverse-bridge
  name: '@deepseek-ai/dsh-reverse-bridge'
  config:
    socketPath: /var/mobile/Library/DSHReverse/rvd.sock   # 默认值
```

其它插件经能力缝读取：

```ts
const { processes } = await ctx.reverse.call('process.list', {})
```

<a id="understand-the-implementation"></a>
## 理解实现

连接惰性建立并复用；常驻端掉线报 `not-connected` 而不排队——关于某个进程的过期回答比没有回答更糟。`mutate` 用调用方写的摘要（进程、地址、类型、新旧两个值）调用 `ctx.approval.request()`，只有 `allowed-once` 才放行该帧；拒绝变成 `denied`，并带上用户看到的原因。每次调用都受截止时间与调用方的 `AbortSignal` 约束。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- 没有重连退避：harness 启动后才装好的常驻端会在下一次调用时被用上，而不是由监听器发现。
- 即使常驻端会回答 `unsupported`，改写类操作仍先请求审批，所以用户会在一次空操作前被问。这两个操作的工具在各自 README 里已注明。

<a id="dev-note"></a>
## 开发备注

`normalizeArguments` 在这里也跑一遍，不只跑在工具里，因此手写的 `ctx.reverse.call` 与模型调用得到同样的校验。任何会改变目标的新操作都必须加进协议包的 `DangerousOp`，否则 `mutate` 会拒绝它。
