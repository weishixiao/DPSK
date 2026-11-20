---
description: "在 DeepSeek Harness 上新增的 iOS 逆向 Agent 工作台：桥接插件、SpringBoard 常驻端、协议、装配、开关、部署与排障。"
---

# iOS 逆向 Agent 工作台

中文 | [English](readme.md)

## 概述

这套能力在 DeepSeek Harness 之上**只做新增**：核心的 `packages/core/*`、`packages/client/*`、审批交互包一行未改。新增内容分三层：

1. **harness 侧插件**（`packages/reverse/*`）：一个能力缝定义、一个本地套接字提供者、六个模型可见工具。
2. **profile 层**（`packages/bundle/reverse`）：把上面的行列成一个可选的 bundle，选中即整体启用，不选则完全不存在。
3. **设备侧常驻端**（`native/reverse-resident/`）：注入 SpringBoard 的 Theos tweak，持有平台身份，负责真正碰进程与内存。

harness 进程内**永不**调用 `task_for_pid`、`mach_vm_*`、`dlopen` 注入；它只会把请求写进一个 Unix 域套接字。

## 目录

- [架构](#架构)
- [Node 侧新增清单](#node-侧新增清单)
- [IPC 协议](#ipc-协议)
- [设备侧常驻端](#设备侧常驻端)
- [装配与开关](#装配与开关)
- [模型与 API key](#模型与-api-key)
- [使用流程](#使用流程)
- [安全边界](#安全边界)
- [已知边界](#已知边界)
- [排障](#排障)

-----

<a id="架构"></a>
## 架构

```
模型 ↔ agent-loop（core，未改）
         │ tool.execute
         ▼
   dsh-tool-reverse-*（6 个工具，只做参数整形与审批）
         │ ctx.reverse.call()
         ▼
   dsh-reverse-bridge（能力缝 + 本地套接字提供者）
         │ NDJSON over /var/mobile/Library/DSHReverse/rvd.sock
         ▼
   ReverseResident（SpringBoard 内的 tweak）
         │ task_for_pid / mach_vm_* / Mach-O 解析
         ▼
      目标进程
```

能力缝按既有约定分三角色：`ReverseBridge`（Service Definition，`packages/reverse/bridge/src/seam.ts`）、`LocalSocketReverseBridge`（Provider）、`dsh-tool-reverse-*`（Consumer）。工具不认识套接字，提供者不认识工具。

<a id="node-侧新增清单"></a>
## Node 侧新增清单

| 路径 | 作用 |
|---|---|
| `packages/reverse/protocol/` | 操作表、请求/响应帧、错误码、参数校验（`validate.ts`）与行分帧（`frame.ts`） |
| `packages/reverse/bridge/` | 能力缝 `ReverseBridge` 与套接字提供者；每次高危操作前经 `ctx.approval` 征询 |
| `packages/reverse/tool-process/` | `reverse_status`、`reverse_logs`、`reverse_process_list`、`reverse_process_images` |
| `packages/reverse/tool-macho/` | `reverse_macho_analyze` |
| `packages/reverse/tool-symbol/` | `reverse_symbols` |
| `packages/reverse/tool-memory/` | `reverse_memory_read`、`reverse_memory_scan`、`reverse_memory_write` |
| `packages/reverse/tool-tweak/` | `reverse_hook_install`、`reverse_inject_dylib`（前置一次审批；安装行为本身返回 `unsupported`） |
| `packages/reverse/scripts/` | `reverse_script_save`、`reverse_script_list`、`reverse_script_read`、`reverse_script_delete`：把 hook、内存脚本与笔记当成文件存起来 |
| `packages/bundle/reverse/` | 可选 bundle，`cordis.patch.yml` 只 insert 自己的行 |
| `packages/llm/llm-failover/` | 多模型路由：某个 provider 报余额/凭据失败时，下一步切到配置里的下一个 provider |

登记类改动（非逻辑）：`tsconfig.base.json` 的别名区、`tsconfig.host.json` 的 references、各包 `tsconfig.json` 与 `tsdown.config.ts`。

<a id="ipc-协议"></a>
## IPC 协议

一行一个 JSON 对象，UTF-8，`\n` 结束；单帧上限 8 MiB。

请求：

```json
{"id":"<uuid>","op":"memory.read","args":{"pid":1234,"address":"0x100004000","length":64}}
```

响应（同 `id`）：

```json
{"id":"<uuid>","ok":true,"result":{"address":"0x100004000","length":64,"hex":"...","ascii":"..."},"elapsedMs":3}
{"id":"<uuid>","ok":false,"error":{"code":"denied","message":"task_for_pid(1234) was refused ..."},"elapsedMs":2}
```

操作表：`system.hello`、`system.logs`、`process.list`、`process.images`、`process.symbols`、`macho.analyze`、`memory.read`、`memory.scan`、`memory.write`、`hook.install`、`inject.dylib`。

错误码：`bad-request`、`invalid-args`、`not-connected`、`timeout`、`cancelled`、`denied`、`not-found`、`target-gone`、`unsupported`、`protocol-mismatch`、`remote-error`。

`system.hello` 回答里的 `ops` 是**该常驻端实际服务**的操作列表。当前 resident 构建服务前九个；`hook.install` 与 `inject.dylib` 返回 `unsupported` 并说明原因（见[已知边界](#已知边界)）。

<a id="设备侧常驻端"></a>
## 设备侧常驻端

源码在 `native/reverse-resident/`：

| 文件 | 内容 |
|---|---|
| `Tweak.xm` | `%ctor` 启动监听，不 hook SpringBoard 自身任何行为；启动期异常只记日志，常驻端离线，桌面照常运行 |
| `ReverseResident.plist` | 过滤器，只注入 `com.apple.SpringBoard` |
| `RVServer.m` | 监听、按行分帧、操作表分发、`system.hello`、`system.logs` 的应答日志环形缓冲；每个请求在自己的 autorelease pool 里、在异常边界内执行，抛出的异常变成该请求的 `remote-error` 回包 |
| `RVProcess.m` | 进程枚举（`sysctl` + `proc_pidpath`）、映像枚举（扫描 VM 区域里的 Mach-O 头）、符号表读取与重基 |
| `RVMachO.m` | 文件级 Mach-O 分析：依赖、段与节、加密标志、平台、ObjC 名称、字符串 |
| `RVMemory.m` | `mach_vm_read_overwrite` 读、区域遍历扫描、写前保存原保护并恢复 |

### 故障收敛

常驻端跑在 SpringBoard 里，它放出去的每一个失败都要由桌面来付。三道边界把 bug 关在常驻端这一侧：

| 边界 | 兜住什么 |
|---|---|
| `%ctor` | 启动期异常记日志后吞掉：socket 就是没建起来，`reverse_status` 回答 `offline`，桌面继续跑 |
| 分发层（`RVServer.m`） | 服务某个操作时抛的异常变成该请求的 `remote-error` 回包；回包照常送出，连接不断，下一个请求照常服务 |
| 逐请求 pool（`RVServer.m`） | 每个回包的临时对象在读取下一行之前就释放了，长连接的客户端不会把历次扫描的内存攒起来 |

异常从不被静默吞掉：名字和原因都会记进日志，就是 `log stream --predicate 'eventMessage CONTAINS "rv:"'` 能看到的内容。

Tweak 也是**串接**而不是替换进程原有的未捕获异常处理器，所以别的 tweak 的处理器和系统自带的崩溃上报照常工作。

### 定位目标

`reverse_process_list` 接名字片段，也接 **BundleID**：`com.burbn.instagram` 和 `Instagram` 一样能找到那个 app，返回结果里每个进程都带 `bundleId`。以反域名前缀开头的过滤器会先按 BundleID 校验再发出，格式错的在这里就被拒，而不是回一个空列表、看起来像"app 没在运行"。

### 日志面板

`reverse_logs` 读的是常驻端自己的应答日志：每个请求一行，含时刻（UTC）、操作名、成败、耗时与失败文本。它是"刚才那次调用为什么被拒"的第一手答案——`unsupported`、`invalid-args`、`denied` 都在这里留下原话，不必再去翻 SpringBoard 的 `rv:` 系统日志。

环形缓冲在常驻端内存里，200 条封顶：respring 会清空，被挤掉的旧条目只记一个计数，工具在渲染里说明丢了多少（结果里的 `dropped`）。日志不落盘，因此不含任何跨会话历史。

### Theos 环境

需要一个能编 arm64/arm64e tweak 的 Theos（设备上用 `theos` + `ldid`，或在 Mac 上交叉编译）：

```sh
export THEOS=$HOME/theos
cd native/reverse-resident
make package            # 产出 packages/*.deb
make install            # 或把 deb 交给用户的包管理器
```

`control` 里 `Depends: mobilesubstrate`：常驻端以 Substrate/ElleKit 的注入为前提。

### 安装与运行

1. 安装 deb 后 respring（`killall -9 SpringBoard` 或包管理器提供的重启）。
2. 常驻端在 SpringBoard 启动时创建 `/var/mobile/Library/DSHReverse/rvd.sock`（0666）。
3. 用日志确认：`log stream --predicate 'eventMessage CONTAINS "rv:"'`，应看到 `rv: resident listening on ...`。

<a id="装配与开关"></a>
## 装配与开关

逆向能力**整体**由一个 bundle 开关控制：把 `@deepseek-ai/dsh-reverse-bundle` 加进 profile 的 `dsh.profile.bundles` 就启用，去掉即彻底不存在。

单项能力也可以单独关掉：给那一行加 `config: { enabled: false }`，该包就一个工具都不注册。模型没有可调的东西，也就不会有它的审批弹窗。想"保留进程与内存分析，去掉 hook 生成器"时用这一层。

```yaml
    - id: tool-reverse-tweak
      name: '@deepseek-ai/dsh-tool-reverse-tweak'
      config:
        enabled: false        # 不再有 reverse_hook_install / reverse_inject_dylib
```

| 行 | 能力 | 带来的工具 |
|---|---|---|
| `reverse-bridge` | 桥本身 | — |
| `tool-reverse-process` | 运行中的进程与应答日志 | `reverse_status`、`reverse_logs`、`reverse_process_list`、`reverse_process_images` |
| `tool-reverse-macho` | 静态文件分析 | `reverse_macho_analyze` |
| `tool-reverse-symbol` | 符号查找 | `reverse_symbols` |
| `tool-reverse-memory` | 目标内存读、扫描、写 | `reverse_memory_read`、`reverse_memory_scan`、`reverse_memory_write` |
| `tool-reverse-tweak` | Hook 与注入请求 | `reverse_hook_install`、`reverse_inject_dylib` |
| `reverse-scripts` | 落盘的脚本 | `reverse_script_save`、`reverse_script_list`、`reverse_script_read`、`reverse_script_delete` |

自分 profile 片段：

```yaml
# ~/.dsh/profiles/reverse.yml（示例，按你现有 profile 的写法合并）
dsh:
  profile:
    bundles:
      - base
      - reverse            # 本工作台
```

`reverse-bridge` 的可调项（`cordis.yml` 里同名插件行的 config）：

| 字段 | 默认 | 含义 |
|---|---|---|
| `enabled` | `true` | 关闭后所有调用直接失败、不发包，但各行仍挂载 |
| `socketPath` | `/var/mobile/Library/DSHReverse/rvd.sock` | 与常驻端一致 |
| `timeoutMs` | `20000` | 单个请求总时限 |
| `connectTimeoutMs` | `2000` | 单次连接时限 |

`reverse-scripts` 把内容写进 `<dsh home>/reverse/scripts`，一个脚本一个文件：hook 是 `.xm`，内存脚本是 `.json`，笔记是 `.md`。把该行的 `directory` 指向编辑器或 Theos 能读到的目录即可改用别处。同名再保存就是覆盖旧文件，这也是改完脚本写回去的方式。

设备上没有装常驻端时，`reverse_status` 会回答 `offline` 并给出原因，而不是让整个组合装配失败。

<a id="模型与-api-key"></a>
## 模型与 API key

`packages/llm/llm-failover` 是独立的可选插件：它监听 `agent/request-error`，当失败属于**可换 provider 的类别**（`QUOTA`、`ACCOUNT_QUOTA`、`INVALID_CREDENTIAL`、`MISSING_CREDENTIAL`、`AUTH`、`ACCOUNT_SIGN_IN_REQUIRED`、`ACCOUNT_TOKEN_INVALID`）时，用 `agent.model.select({provider, model})` 把下一步切到候选里下一个 provider，并返回 `{kind:'retry'}`。切换只对**后续 step** 生效，这是 `agent/request`  waterfalls 的语义。

配置：

```yaml
- id: llm-failover
  name: '@deepseek-ai/dsh-llm-failover'
  config:
    enabled: true
    candidates:
      - provider: deepseek
        model: deepseek-chat
      - provider: zhipu          # GLM 适配器
        model: glm-4.6
    loopGuard: 100
```

密钥仍由既有 credentials/settings 管理：`DEEPSEEK_API_KEY`（或 `deepseek` provider 的凭据条目）、GLM 的 key 同样是 provider 凭据，不写进 cordis.yml。

<a id="使用流程"></a>
## 使用流程

1. `reverse_status` —— 确认常驻端在线、协议版本一致、可用操作。
2. `reverse_process_list {filter:"SpringBoard"}` —— 拿 pid。
3. `reverse_process_images {pid}` —— 看加载了什么（结果为 `path` 可为空的映像时，用 `base` 作选择器）。
4. `reverse_symbols {pid, image:"/usr/lib/libobjc.A.dylib", filter:"class_"}` —— 拿运行地址。
5. `reverse_macho_analyze {path:"/var/containers/.../App.app/App"}` —— 判断是否加壳、依赖什么、有无 ObjC 名称表。
6. `reverse_memory_scan {pid, type:"u64", value:"0"}` —— 找数值（金币、剩余次数）。
7. `reverse_memory_write {pid, address:"0x...", type:"u64", value:"999999"}` —— 每次写都要在打开的 turn 内点一次"允许一次"。
8. `reverse_hook_install` —— 把你写好的 hook 源码经审批交给常驻端；本版本常驻端返回 `unsupported`，因此留下来的就是源码本身（见下方边界）。

<a id="安全边界"></a>
## 安全边界

- **审批由桥强制**：`ReverseBridge.mutate()` 在发包前调用 `ctx.approval`，拿不到批准就不发。工具层没有"跳过审批"的参数。
- **审批必须在打开的 turn 内发起**：否则 `approval.request()` 抛 `outside an open turn`，这是既有实现的行为，不是本插件引入的。
- **harness 进程不碰目标**：没有 `task_for_pid`、没有 `mach_vm_*`、没有注入。
- **常驻端不做二次判断**：它只执行被批准的帧。它的权限就是 SpringBoard 的权限，因此装与不装、开与不开以 bundle 为准。
- **参数在桥里先校验**：地址、长度、limit、值宽度、路径都在 `normalize.ts` 里规范化并拒绝不合理值，避免把荒谬请求做成一个人要回答的问题。

<a id="已知边界"></a>
## 已知边界

| 项 | 现状 |
|---|---|
| `hook.install` | 常驻端返回 `unsupported`。跨进程 inline hook 需要目标进程内的 hook 引擎，本版本没有内置；`reverse_hook_install` 仍会把你写的源码送去审批，所以会话里的源码就是 Theos 编译 tweak 的起点 |
| `inject.dylib` | 同上，返回 `unsupported`。用越狱自带的 dylib 注入器或 tweak 过滤器加载 |
| 远程 Theos 编译 | `system.hello` 的 `theos` 字段只报告设备上是否可见 Theos；resident 尚未驱动编译 |
| `objc-method` 符号 | 仅从文件符号表与名称表推断，尚未从目标运行时读取 class/method 列表 |
| 异常保护的范围 | 兜住的是 ObjC 异常与可返回的 mach 错误码。野指针、`SIGSEGV` 这类进程级崩溃无法在库内兜住——那种情况 Tweak 只保证不会因为"监听没起来"而拖垮桌面 |
| 文档配对记录 | 本目录的中英配对 `readme.i18n.yaml` 尚未生成：在有 Node 的机器上执行 `pnpm run verify-translation-pairing --write docs/reverse/readme.md` |

<a id="排障"></a>
## 排障

| 现象 | 原因与处理 |
|---|---|
| `reverse_status` 报 `offline` / `not-connected` | 常驻端未加载或 socket 不在：确认 deb 已安装并 respring，检查 `/var/mobile/Library/DSHReverse/rvd.sock` 是否存在 |
| `denied: task_for_pid(...) was refused` | 目标是 hardened/平台进程，或 tweak 未获得平台身份；确认注入的是 SpringBoard |
| `protocol-mismatch` | 两端 `PROTOCOL_VERSION` 不一致：同步更新 harness 与常驻端 |
| 写内存后立刻回滚 | 目标把该页重新映射或校验了保护位；改用 hook 路径，或换可写页 |
| 扫描结果很多 | 用 `range` 收窄窗口，或先 `reverse_symbols` 定位再 `reverse_memory_read` |

## 开发备注

新增一个操作的做法：在 `protocol/src/types.ts` 的操作表加一行（名字、参数、结果），`validate.ts` 加校验，桥的 `normalize.ts` 加分支，工具包加 schema，常驻端在 `RVServer.m` 的操作表加 handler。五处都由编译器或类型检查盯着。