---
description: "挂载逆向能力的可选 DSH bundle：ctx.reverse 桥，以及进程、Mach-O、符号、内存与 tweak 工具。"
kind: "package-bundle"
---

# @deepseek-ai/dsh-reverse-bundle

[English](README.md) | 中文

## 概述

`dsh-reverse-bundle` 把设备逆向能力作为一个层挂到以 base 为底的 profile 上：连接 SpringBoard 常驻端的桥，以及到达它的六个工具包。选中这个 bundle 就是唯一的开关——把它从 `dsh.profile.bundles` 里去掉，该组合里就不存在这套能力的任何部分。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [延伸阅读](#further-exploration)
- [模型体验](#model-experience)
- [已知限制与后续工作](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用本包

把它加进 profile 的 bundle 列表：

```yaml
dsh:
  profile:
    bundles:
      - base
      - reverse
```

此外无需配置即可启动：没有安装常驻端 tweak 时，桥回答 `offline`，工具如实转述，而不是让组合装配失败。要把桥指向别处，就给它的行加 config —— bundle 插入的 `reverse-bridge` 使用常驻端的默认套接字路径：

```yaml
- id: reverse-bridge
  name: '@deepseek-ai/dsh-reverse-bridge'
  config:
    socketPath: /var/mobile/Library/DSHReverse/rvd.sock
```

<a id="understand-the-implementation"></a>
## 理解实现

本 bundle 只是 `insert` 行的 patch；它不改写下层任何一行，所以聊天、agent 循环、持久化与审批的行为与没有它时完全一致。行包括桥、`tool-reverse-process`、`tool-reverse-macho`、`tool-reverse-symbol`、`tool-reverse-memory`、`tool-reverse-tweak`、`tool-reverse-theos` 与 `reverse-scripts`。其中任何一行都能用 `config: { enabled: false }` 单独关掉。常驻端不是这里的包：它是 `native/reverse-resident/` 下的 Theos tweak，桥只经它的 Unix 套接字访问。

<a id="further-exploration"></a>
## 延伸阅读

- [逆向能力组](../../reverse/README.zh.md)：各包负责什么。
- [部署](../../../docs/reverse/readme.zh.md)：Theos 构建、套接字权限、模型路由。

<a id="model-experience"></a>
## 模型体验

模型看到十七个名为 `reverse_*` 的工具。读取类（`reverse_status`、`reverse_logs`、`reverse_process_list`、`reverse_process_images`、`reverse_macho_analyze`、`reverse_symbols`、`reverse_memory_read`、`reverse_memory_scan`）不需要询问即可运行；`reverse_theos_scaffold` 同样安静地写工程文件；`reverse_memory_write`、`reverse_hook_install`、`reverse_inject_dylib` 与 `reverse_theos_build` 各自需要在打开的 turn 内点一次"允许一次"，提示里写明进程、地址与值——构建则写明那条 `make` 命令行。失败以协议的稳定错误码返回（`not-connected`、`denied`、`unsupported`），模型因此能区分"常驻端没装"与"`task_for_pid` 被拒"。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- `reverse_hook_install` 与 `reverse_inject_dylib` 由常驻端回答 `unsupported`：本构建尚未实现跨进程 hook 与注入。tweak 工具仍会生成并保存 Substrate 源码，Theos 工具随后把它脚手架成工程并构建——那是受支持的路径。
- `reverse_theos_build` 只在装了带 `make` 的 Theos 的设备上能编译。没有的设备得到 `theos-unavailable` 失败，并点名 `Config.makePath` 与 `Config.theosRoot`；harness 不会替它编译。
- 开关粒度是"整个包"，不是单个工具：一行 `config: { enabled: false }` 关掉该包带来的全部工具（例如 `tool-reverse-process` 的四个），没有更细的开关。

## 开发备注

本 bundle 的 `dependencies` 列出每一行的包名，供 profile 解析器加载；在此新增一行，也必须在依赖里加上。