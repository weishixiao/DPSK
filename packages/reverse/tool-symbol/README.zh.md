---
description: "reverse_symbols：从已加载映像取符号名与运行时地址，按目标自身的加载基址重定位。"
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-symbol

[English](README.md) | 中文

## 概述

`reverse_symbols` 回答 hook 需要的那个问题：这个函数在运行中的 App 里叫什么、地址在哪。输入 pid、映像选择器与可选的名字过滤，返回每个符号以及按该映像在目标中的加载基址算出的运行时地址。过滤在设备侧完成，大映像不必整份过套接字。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## 使用本包

```json
{ "tool": "reverse_symbols", "arguments": { "pid": 1234, "image": "App", "filter": "isVip", "limit": 50 } }
```

<a id="understand-the-implementation"></a>
## 理解实现

映像选择器匹配路径末段或其子串，所以 `App` 与 `Frameworks/Foo.framework/Foo` 都可用。地址做了重定位：文件符号偏移加上该映像在目标中的 slide。结果会说明列表是否被截断。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- 符号来自映像的文件符号表与导出名；被 strip 的二进制（如 App Store 构建）所得甚少，Objective-C 方法名不会从运行时元数据重建。
- 地址只在进程存活且映像未移动时有意义；重启进程即失效。
