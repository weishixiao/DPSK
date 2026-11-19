# reverse-resident — 逆向能力的设备端

[English](README.md) | 中文

## 这是什么

一个注入 SpringBoard 的 tweak，在设备本身提供 harness 的逆向操作：进程枚举、映像与符号枚举、静态 Mach-O 分析，以及内存读/扫/写。本项目里 `task_for_pid`、`mach_vm_*` 与 hook 安装只存在于这里；harness 进程从不打开任务、从不写内存、从不加载 dylib。

做成 tweak 而不是守护进程是有意的：对第三方 App 执行 `task_for_pid` 需要 SpringBoard 已持有的平台身份，而 SpringBoard 任务内的 dylib 继承它。受沙箱约束的辅助进程得自己申请相应的 entitlement，会被直接拒绝。

不属 pnpm workspace：它用 Theos 构建，不用 harness 的构建。

## 线路

一个 Unix 域套接字 `/var/mobile/Library/DSHReverse/rvd.sock`，NDJSON 帧，协议版本 `1`。词汇——操作名、参数校验、错误码——属于 `@deepseek-ai/dsh-reverse-protocol`；`RVPrelude.h` 刻意不含 TypeScript 词汇，只重复那些字符串。

一行格式错误就断开该连接而不重新同步，因此半截写入永远不会被当成另一个操作解读。

## 构建与安装

```sh
THEOS=/opt/theos make package            # rootless / rootful
THEOS=/opt/theos THEOS_PACKAGE_SCHEME=roothide make package
```

用你的包管理器安装产出的 `.deb`，然后注销：监听由 tweak 的构造函数启动，首次启动会以 `0700` 创建 `/var/mobile/Library/DSHReverse`。

要确认它起来了，看它自己的日志行 `rv: resident listening on …`，以及 harness 的 `reverse_status`。[部署页](../../docs/reverse/readme.zh.md)写明套接字权限、能力开关与模型路由。

## 操作

| 操作 | 状态 |
|---|---|
| `system.hello` | 回答协议版本与操作列表 |
| `process.list`、`process.images` | `proc_listpids`，再沿目标自己的 `vm_region_recurse` 找 Mach-O 头 |
| `process.symbols` | 映像文件的 `LC_SYMTAB` 与导出名，按该映像在目标中的加载基址重定位 |
| `macho.analyze` | 磁盘文件：加载命令、段与节、依赖 dylib、加密标志、字符串 |
| `memory.read`、`memory.scan` | 在目标各 region 上用 `mach_vm_read_overwrite` 读 |
| `memory.write` | `mach_vm_protect` + `mach_vm_write`，事后恢复原保护 |
| `hook.install`、`inject.dylib` | **`unsupported`**：跨进程 hook 与注入未在此实现 |

`unsupported` 是真实回答而非占位：该操作在表里，客户端因此得知能力缺失，而不是等到一次静默超时；`system.hello` 列出同一份表。

## 备注

- 套接字建在 `0700` 目录里、权限 `0600`：只有 `mobile`（与 `root`）能连。能连上它就能写别的进程的内存——把它当作等价于 root 的能力对待。
- `memory.write` 即使写失败也恢复原保护，并报告写入前的值。
- 读与扫受 `RV_MAX_FRAME_BYTES`（8 MiB）与 `RV_MAX_READ_LENGTH`（1 MiB）限制；客户端先验证同一组限制，所以被拒的请求在到达设备前就失败。
- 四个操作文件在 iOS 18.5 SDK 上以 `-Wall -Wextra` 干净编译并链接；`Tweak.xm` 另需 Logos 与 `libsubstrate`，只有 Theos 工具链提供。