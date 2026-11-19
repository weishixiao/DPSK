---
description: "把代码送进目标的两个工具：reverse_hook_install 装一个 Substrate hook，reverse_inject_dylib 做 dylib 注入——两者都前置一次审批。"
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-tweak

[English](README.md) | 中文

## 概述

参数本身就是代码的两个工具。`reverse_hook_install` 接收 pid、映像、符号、模式（`replace` 或 `log-only`）与完整的 hook 源码——替换函数及其 `MSHookFunction`/`MSHookMessageEx` 语句——请求常驻端安装它。`reverse_inject_dylib` 接收 pid 与设备上的 dylib 路径。两者都会改变运行中的进程，因此都走 `ctx.reverse.mutate()`：审批提示在任何帧发出之前写明进程并显示源码，只有"允许一次"才放行。本构建的常驻端对二者都回答 `unsupported`，模型因此明确得知这一点而不是去猜；它写下的源码仍留在记录里，可以交给 Theos 构建。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## 使用本包

先用 `reverse_symbols` 解析符号，然后：

```json
{ "tool": "reverse_hook_install",
  "arguments": {
    "pid": 1234,
    "image": "App",
    "symbol": "-[VIPManager isVip]",
    "mode": "log-only",
    "source": "……替换函数与其 MSHookMessageEx 语句……"
  } }
```

审批提示会写明进程并显示源码（超过二十来行即省略）。生成的 tweak 用 Theos 构建安装——见部署页；本工具不跑编译器。

<a id="understand-the-implementation"></a>
## 理解实现

源码在发出前先校验形状与长度，并以字符串形式传输：harness 里没有任何地方编译或求值它。这两个操作是此处仅有的能改变行为（而非数据）的操作，所以即使常驻端会拒绝，审批也不能省。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- 运行时安装未实现：常驻端对 `hook.install` 与 `inject.dylib` 回答 `unsupported`。受支持的路径是这里生成、用 Theos 构建、用包管理器安装。
- 不对照目标头文件做类型检查；能编译的 hook 不等于有效的 hook。
- harness 不驱动交叉编译器，因此不会有构建结果回到记录里。
- `inject.dylib` 接收设备上已存在的路径，本工具不上传库文件。