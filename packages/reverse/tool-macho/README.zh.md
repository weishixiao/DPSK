---
description: "reverse_macho_analyze：对设备上单个 Mach-O 文件做静态分析——加载命令、段与节、依赖、加密、符号与字符串。"
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-macho

[English](README.md) | 中文

## 概述

`reverse_macho_analyze` 读取设备上的一个二进制，报告逆向首先要看的那些：架构、文件类型、标志、是否加密（以及 cryptid）、依赖的 dylib 与 rpath、各段节及大小、可选的符号名列表、可选的字符串样本。它读文件而非运行中的进程，所以 App 启动前就能用。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## 使用本包

```json
{ "tool": "reverse_macho_analyze", "arguments": { "path": "/var/containers/Bundle/Application/…/App.app/App", "stringsLimit": 100 } }
```

<a id="understand-the-implementation"></a>
## 理解实现

文件由常驻端一趟读完：fat 文件取 arm64 切片，带边界检查地遍历加载命令，符号与字符串段只在被要求时读。调用方给的数量都有上限，提前停下时答案会说明。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- fat 文件只报 arm64 切片；同一 fat 文件中 arm64e 的差异不列出。
- 链式 fixup 的绑定信息不解析成名字：名字来自 `LC_SYMTAB` 与字符串表。
- 字符串提取是可打印字符游程扫描，不是对 URL 或密钥的语义搜索。
