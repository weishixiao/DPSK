---
description: "进程发现类工具：reverse_status、reverse_logs、reverse_process_list 与 reverse_process_images。"
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-process

[English](README.md) | 中文

## 概述

`ctx.reverse` 上的四个只读工具：`reverse_status` 报常驻端是否可达、说的是哪版协议，`reverse_logs` 读常驻端的近期应答日志（哪个操作、成败、耗时、失败文本），`reverse_process_list` 列出活进程及其 pid 与路径，`reverse_process_images` 列出映射进某一进程的 Mach-O 映像及其基址。这里不改变目标，因此不问审批。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## 使用本包

挂载 `@deepseek-ai/dsh-reverse-bridge` 与本包。调用形如：

```json
{ "tool": "reverse_process_images", "arguments": { "pid": 1234 } }
```

<a id="understand-the-implementation"></a>
## 理解实现

`reverse_process_list` 按进程名或路径做子串过滤，过滤串在到达套接字前先校验（类型与长度）。`reverse_process_images` 需要调用方先找到 pid——工具不做猜测。结果渲染为紧凑表格，被截断的列表会明说，而不是悄悄停下。

`reverse_logs` 读常驻端内存里的 200 条环形缓冲，`limit` 先按 1..200 校验，默认 50；条目按时间升序渲染，带失败文本，并在有旧条目被丢弃时说明丢弃数。它只读日志，不改变目标，所以与另外三个工具一样不问审批。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- 只能看到常驻端身份看得见的进程；iOS 上有些系统进程即使从 SpringBoard 也枚举不到。
- 映像来自常驻端的 region 遍历，因此"已映射但尚未加载"与"已加载"不可区分。
