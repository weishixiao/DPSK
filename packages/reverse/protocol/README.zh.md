---
description: "逆向能力的线路词汇：操作名、参数形状与校验函数、NDJSON 帧、错误码与按行分帧，由 harness 与 SpringBoard 常驻端共用。"
kind: "package-reference"
---

# @deepseek-ai/dsh-reverse-protocol

[English](README.md) | 中文

## 概述

`dsh-reverse-protocol` 是逆向能力两端唯一约定的地方：操作表（`ReverseOp`）以及其中哪些会改变目标（`DANGEROUS_OPS`、`isDangerousOp`）、每个操作的参数与结果、每个参数在成帧之前必须通过的逐字段校验（`validatePid`、`validateAddress`、`validateLength`、`validateImageSelector`、`validateDevicePath`、`validateSource`、`validateValue` 等）、`PROTOCOL_VERSION`、请求与响应帧联合、`ReverseErrorCode`，以及分帧——`encodeFrame`、`parseResponse`、`LineFramer`、`MAX_FRAME_BYTES`。它是库：没有 ctx 键、没有工具、不挂载任何东西。两端都依赖它，彼此不依赖。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用本包

校验函数会抛点名具体字段的 `ReverseArgsError`，因此格式错误的东西永远到不了套接字：

```ts
import { validateAddress, validatePid } from '@deepseek-ai/dsh-reverse-protocol'

const pid = validatePid(raw.pid)
const address = validateAddress(raw.address)
```

工具通常走 `@deepseek-ai/dsh-reverse-bridge` 的 `normalizeArguments(op, raw)`，它把同一批校验组装成"每个操作一个形状"，并返回带类型的参数。

<a id="understand-the-implementation"></a>
## 理解实现

校验是同步且完备的：拒绝会点名具体字段。常驻端用 Objective-C 再校验同一批形状，手写客户端也绕不过契约。帧上限为 `MAX_FRAME_BYTES`（8 MiB），`LineFramer` 遇到更长的行就断开连接而不截断请求——半截写入绝不能被读成另一个操作。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- `hook.install` 与 `inject.dylib` 在表里，但常驻端回答 `unsupported`；保留在表里，是为了让 `system.hello` 能如实报告这个缺口。
- 这里不认识审批：哪些操作需要审批由桥决定，依据是 `isDangerousOp`。

<a id="dev-note"></a>
## 开发备注

操作表就是整套能力的 schema。新增操作先加进 `types.ts`；桥的 `normalize.ts` 与各工具 schema 在达成一致前都编译不过。