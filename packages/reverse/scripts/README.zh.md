---
description: "把逆向脚本当工具存起来：hook 或内存脚本落盘、列目录、读回来、删掉。"
kind: "package-reference"
---

# @deepseek-ai/dsh-reverse-scripts

[English](README.md) | 中文

## 概述

四个工具把一次会话的产物留住，下一次不必重做：`reverse_script_save`、`reverse_script_list`、`reverse_script_read`、`reverse_script_delete`。为某个目标写的 hook、一份可重放的地址操作清单、一段"这个偏移原来是干什么的"笔记——都是某个目录里的一个文件，而不是数据库里的一行，因为脚本的下一步往往是人把它丢进编辑器，或者交给 Theos。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## 使用本包

```json
{ "tool": "reverse_script_save", "arguments": { "name": "vip-check-bypass", "kind": "tweak", "source": "%hook ..." } }
{ "tool": "reverse_script_list", "arguments": { "kind": "tweak" } }
{ "tool": "reverse_script_read", "arguments": { "name": "vip-check-bypass", "kind": "tweak" } }
{ "tool": "reverse_script_delete", "arguments": { "name": "vip-check-bypass", "kind": "tweak" } }
```

同名再保存会覆盖文件并回答 `replaced: true`；改过的脚本就是这样写回磁盘的。

| kind | 扩展名 | 装什么 |
|---|---|---|
| `tweak` | `.xm` | Logos 源码，`make package` 的起点 |
| `memory` | `.json` | 一份可重放的地址操作清单 |
| `note` | `.md` | 某个符号、偏移、数值最后被确认成什么 |

目录默认是 `<dsh home>/reverse/scripts`，在插件行上设 `directory` 可以换。四个工具能各自单独关（`save`、`list`、`read`、`delete`），`enabled: false` 关掉整包。

<a id="understand-the-implementation"></a>
## 理解实现

碰磁盘之前先校验名字：字母、数字、点、横线、下划线，最长 64 字符，且不许出现路径分隔符——所以模型给的名字不可能指向库外的文件。扩展名由 kind 决定，同一个名字没法冒充成另一种文件。读取有上限，超过时回答 `truncated: true`，而不是把一个无界的文件整个塞回模型。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- 脚本是文本而不是记录：没有历史版本、没有作者，时间只有文件自己的 `mtime`（`list` 把它报成 `updatedAt`）。
- 本包不编译任何脚本。`tweak` 脚本由操作者交给 Theos；常驻端不驱动编译。
- 库是按机器、按目录的。两个 `directory` 不同的检出互相看不到对方的脚本。
