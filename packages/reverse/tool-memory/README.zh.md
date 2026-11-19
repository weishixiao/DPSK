---
description: "经 ctx.reverse 的内存操作：读取、扫描，以及需要审批的写入——这里唯一会改变运行中 App 的操作。"
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-memory

[English](README.md) | 中文

## 概述

`reverse_memory_read` 把某地址的字节渲染为十六进制与 ASCII，`reverse_memory_scan` 在某个进程里搜索一个带类型的值（u8…i64、float、double）并返回命中的地址，`reverse_memory_write` 覆写该类型形状的一个值。前两个是读，不问即行；写入是 harness 里最锋利的一刀，走 `ctx.reverse.mutate()`，审批里写明进程、地址、类型与新值。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## 使用本包

```json
{ "tool": "reverse_memory_scan", "arguments": { "pid": 1234, "type": "i32", "value": "99999", "limit": 20 } }
{ "tool": "reverse_memory_write", "arguments": { "pid": 1234, "address": "0x104a1c2d0", "type": "i32", "value": "999999" } }
```

写入会返回写入前的值，因此同一次调用可以把改动还原。

<a id="understand-the-implementation"></a>
## 理解实现

扫描遍历目标的可读 region，按类型逐字节精确匹配，遵守可选的地址范围与结果上限。写入先把所在 region 改为可写，写入，再恢复原保护——失败时也恢复。长度与数量先在 harness 侧校验，过大请求不会到达设备。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- 扫描只做单一宽度、单一精确值的匹配；没有范围匹配、没有"两次快照之间变化"的模式、没有指针链解析。
- 写目标未映射、或改保护后仍不可写的内存，会带着常驻端给出的原因失败；不存在部分写入且不作声的情况。
- 除会话自身的工具结果外，不保留历史写入记录：撤销由调用方负责。
