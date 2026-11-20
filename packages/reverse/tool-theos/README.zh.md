---
description: "基于 ctx.shell 的 Theos 调度：reverse_theos_build 在一次审批后调用本机 make，reverse_theos_scaffold 写出可直接构建的纯 Objective-C tweak 工程。"
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-theos

[English](README.md) | 中文

## 概述

把模型写下的 hook 变成设备真能加载的东西，就靠这两个工具。`reverse_theos_scaffold` 在用户指定的绝对路径写出一个 Theos 工程——Makefile、control、过滤 plist，以及一个用 `MSHookMessageEx`（不用 Logos）的 Objective-C hook 源码。`reverse_theos_build` 随后在该目录里通过 `ctx.shell` 调用设备自己的 `make`，回报退出码、两路输出的尾部，以及构建写出的 `.deb`。构建执行的是工程的 Makefile，也就是代码，因此它先走 `ctx.approval`，审批提示写明完整命令行；没有任何配置能跳过这一问。两个工具都不安装任何东西：把 `.deb` 交给包管理器是用户的步骤，运行时路径仍是常驻端的 `hook.install`，在它实现之后。

## 目录

- [使用本包](#use-this-package)
- [理解实现](#understand-the-implementation)
- [已知限制与后续工作](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## 使用本包

先由解析出的符号生成工程，再构建：

```json
{ "tool": "reverse_theos_scaffold",
  "arguments": { "path": "/var/mobile/Tweaks/VIPHook",
                 "packageId": "com.example.viphook",
                 "bundleId": "com.example.app",
                 "scheme": "roothide" } }
```

```json
{ "tool": "reverse_theos_build",
  "arguments": { "path": "/var/mobile/Tweaks/VIPHook", "target": "package", "jobs": 2 } }
```

审批提示会写明工程目录、`THEOS` 与命令（`make -C '<dir>' -j2 package`）。拒绝审批、组合里没有审批服务、调用被取消，三者都不碰磁盘。

<a id="understand-the-implementation"></a>
## 理解实现

构建从 `Config.makePath` 取 `make`、从 `Config.theosRoot` 取 `THEOS`、从 `Config.timeoutMs` 取时限，把解析后的 spec 交给 `ctx.shell`，等前台结果。根本没拉起来的进程会变成一条 `theos-unavailable` 的 `HarnessError`，同时点出这两个配置项，所以没装 Theos 的设备读到的是「没有安装 make」，而不是一个坏掉的构建。`package` 或 `do` 成功后，报告 `packages/` 下最新的 `.deb`；没写出包就直说没写出。

脚手架校验目录为绝对路径、两个标识符为反向域名、工程名为字母数字下划线；目录里已有内容且未传 `force` 时拒绝写入，因为覆盖别人改过的 Makefile 不叫修复。hook 源码刻意用纯 Objective-C：`%hook` 需要 Logos，那样记录里的源码就不是编译的那份源码。

<a id="known-limitations-and-deferred-work"></a>
## 已知限制与后续工作

- 本机既没有 Theos 也没有 `make`，所以目前在这里唯一能走到的结果是 `theos-unavailable` 拒绝；成功路径尚未在设备上跑过。
- 构建没有沙箱：审批就是全部门槛，Makefile 能用 harness 用户的身份做任何事。
- 这两个工具不安装 `.deb`；构建出的 tweak 要经包管理器或重载 SpringBoard 才生效。
- 脚手架不生成 Logos 模板、不做 Preferences 面板、不带测试目标；产物是一个过滤到单个 bundle 的 tweak dylib。
- 替换函数的签名与原方法不匹配照样能编译，然后让目标在运行时崩溃。
