---
description: "逆向能力包组：通往设备常驻端的能力缝、其本地套接字提供者、线路协议，以及面向模型的进程、映像、符号、Mach-O 与内存工具。"
kind: "package-group"
---

# reverse/ — 设备逆向能力家族

[English](README.md) | 中文

## 概述

reverse 组让一个组合能够读取所运行越狱设备上的进程与内存，外加一次写入与两项必须由人决定的高危操作。该组本身不持有任何特权原语：`protocol` 固定线路词汇，`bridge` 拥有 `ctx.reverse` 能力缝并连接常驻端的 Unix 套接字，`tool-reverse-*` 各包把模型调用变成经过校验的协议请求。特权的那一半——`task_for_pid`、`mach_vm_*`、hook 安装——是本仓库 `native/reverse-resident/` 下的一个 SpringBoard tweak，不是本仓库的包。本页列出该组；每个包 README 负责各自的包级约定，部署见 [`docs/reverse/readme.zh.md`](../../docs/reverse/readme.zh.md)。

## 目录

- [包](#packages)
- [相关文档](#related-documentation)
- [开发备注](#dev-note)

-----

<a id="packages"></a>
## 包

| 包 | 作用 | ctx 键 |
|---|---|---|
| [`protocol/`](protocol/README.md) | 操作表、帧、错误码、参数校验、按行分帧 | — |
| [`bridge/`](bridge/README.md) | 定义 `ctx.reverse` 并经常驻端的 Unix 套接字提供服务，凡是会改变目标的操作先征询审批 | `ctx.reverse` |
| [`tool-process/`](tool-process/README.md) | `reverse_status`、`reverse_logs`、`reverse_process_list`、`reverse_process_images` | 注册工具 |
| [`tool-macho/`](tool-macho/README.md) | `reverse_macho_analyze`：加载命令、段与节、依赖、加密标志、名称、字符串 | 注册工具 |
| [`tool-symbol/`](tool-symbol/README.md) | `reverse_symbols`：从目标映像的符号表取运行时地址 | 注册工具 |
| [`tool-memory/`](tool-memory/README.md) | `reverse_memory_read`、`reverse_memory_scan`，以及需要审批的 `reverse_memory_write` | 注册工具 |
| [`tool-tweak/`](tool-tweak/README.md) | `reverse_hook_install`、`reverse_inject_dylib`：生成 Substrate 源码，两者前置审批 | 注册工具 |
| [`scripts/`](scripts/README.md) | `reverse_script_save`、`reverse_script_list`、`reverse_script_read`、`reverse_script_delete`：把 hook、内存脚本与笔记当文件存起来 | 注册工具 |

列出这些行的 bundle 是 [`packages/bundle/reverse`](../bundle/reverse/README.md)；常驻端的源码、构建与安装见 [`native/reverse-resident`](../../native/reverse-resident/README.md)。

-----

<a id="related-documentation"></a>
## 相关文档

- [部署与运行](../../docs/reverse/readme.zh.md)：Theos 构建、套接字权限、能力开关、模型路由。
- [架构](../../docs/architecture.zh.md)：能力缝在组合中的位置。

## 开发备注

新增一个操作是五处改动，由编译器保持同步：`protocol` 里的操作表、它的校验、`bridge` 的 `normalize.ts` 分支、工具 schema，以及常驻端 `RVServer.m` 的 handler 行。