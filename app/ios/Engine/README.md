# 本机引擎

App 里跑的 harness：Node 链接进 `DPSK.app`，`host.mjs` 用 CLI 的受支持启动路径
（`runCli()`）起 `web` profile，把界面绑在 `127.0.0.1:8799`，`WKWebView` 打开它。
没有子进程，没有 shell，也没有远程主机。

```
Engine/
  host.mjs            Node 入口：设好环境、argv，调 runCli()
  ios.patch.yml       Loader 覆盖层：去掉 iOS 上跑不了的行
  runtime/harness/    `pnpm deploy --prod` 出来的 @deepseek-ai/dsh（含 node_modules）
  README.md           这份说明
```

`project.yml` 把这个目录整体当资源拷进 `DPSK.app/Engine/`；Node 本体不在里面，它是
嵌入的 `Frameworks/libnode.dylib`。

## 一次性准备（在 Mac 上）

```sh
tooling/ios/prepare-engine.sh      # Node（iPhoneOS arm64）+ harness
```

产出两个位置，都不进 git：

| 路径 | 内容 |
|---|---|
| `app/ios/Vendor/node/include/node/` | Node 公共头，`#include <node.h>` 用 |
| `app/ios/Vendor/node/lib/libnode.dylib` | iOS arm64 共享库，install name 已改成 `@rpath/libnode.dylib` |
| `app/ios/Engine/runtime/harness/` | CLI 与它的 `node_modules` |

**为什么是 dylib 而不是 `libnode.a`**：Node 有 iOS 共享库的先例（nodejs-mobile），
Xcode 会把嵌入的 dylib 一起签名；静态库要靠 `-force_load` 拉进全部对象，容易和
Node 自带的依赖打重复符号，也不便替换。代价是 dylib 必须真的被签——签名工具要处理
`Frameworks/` 目录，Sideloadly 与 AltStore 都会。

脚本里的 configure 参数：`--shared --openssl-no-asm --with-intl=small-icu
--without-inspector --without-npm --without-corepack --cross-compiling
--dest-cpu=arm64`，操作系统目标先试 `--dest-os=ios`，上游不认时退回
`--dest-os=mac` + iPhoneOS sysroot（nodejs-mobile 的做法）。两条都失败时报错停下，
不猜。

## 启动过程

`Sources/EngineRuntime.swift`：

1. 建目录：`Application Support/dsh`（`DSH_HOME`）、`Documents/workspace`
   （`process.cwd()`，harness 在这里读写）、`Library/Logs`。
2. 设环境：`DPSK_ENGINE_ROOT`、`DPSK_PORT`、`DSH_HOME`、`HOME`、`TMPDIR`——全在
   App 容器里，App 沙盒之外哪也写不了。
3. 起一个 8 MB 栈的线程跑 `DPSKNodeStart(argv)`（`Sources/NodeBridge.mm` 里的
   `node::Start`）。Node 只能在进程里启动一次，所以启动失败就直接说清原因，不重试。
4. 轮询 `http://127.0.0.1:8799/`，通了就把地址交给 WebView，60 秒没通报超时。

**JIT**：V8 只有在签名带 `com.apple.security.cs.allow-jit` 时才 JIT。
`DPSK.entitlements` 声明了它，但自签（免费 Apple ID）会丢掉这个权限，所以
Info.plist 的 `DPSKEngineJIT` 默认 `false`，启动时加 `--jitless`——能跑，只是解释
执行。有带该权限的签名时把 `DPSKEngineJIT` 改成 `true`，不必动代码。

## `host.mjs` 做什么

- `ios.patch.yml` 经 `--patch` 传给 CLI，`--profile web`，`--host 127.0.0.1`，
  `--no-open`：一个来源，Swi‌ft 只给端口。
- `uncaughtException`／`unhandledRejection` 写日志后继续跑：引擎和界面同一个进程，
  崩了会一起没，所以宁可留着残局也不默认退出。
- `console` 的输出镜像进 `Library/Logs/engine.log`（iOS 上 stdout 无处可去）。

## `ios.patch.yml` 去掉了什么

覆盖层只能碰到**宿主平面**的行，而且只有「没有别的行注入它」的行才能关：

| 关掉 | 为什么安全 |
|---|---|
| `open-in-app`、`ui-open-in-app` | 没有任何行注入 `openInApp`；探针枚举的是 Linux/macOS 应用库 |
| `skill-office` | 没人注入 `skillOffice`；Office 技能指向 Python |
| `terminal-controller`、`ui-sidebar-terminal` | 客户端行是 `terminalController` 唯一的消费者，两行一起关 |
| `directory-picker` → 换成 `-browse` 两行 | 与仓库自己的 `apps/web/tests/pin-browse-picker.overlay.yml` 逐字相同 |

**故意不关**的：`sandbox`、`bash-sandbox`、`pwsh-sandbox`、`subprocess`。它们是
providers，`tool-fs-search`、`workspace-changes`、`terminal-bash`、PTC 运行时都注入
它们；在 iOS 上它们的失败形态是 `spawn` 报错（`sandbox-local` 的探针本来就是
`spawnSync` 返回非零即「unusable」），关掉反而会让上面那些行在挂载阶段失败。
`office-kit` 同理：`standard`／`ptc` 两个 preset 里的 `tool-office` 注入
`officeKit`。`workspace-dependencies` 与两个遥测行本来就只在 desktop profile 启用，
这里再关一次只是重复，还会把 desktop 的配置丢掉。

## 已知缺口

1. **会话持久化：addon 已经会编进包，但没在真机上验过。**
   `session-persistence-jsonl` 与 `-sqlite` 的重写锁来自
   `@deepseek-ai/node-addon-system`，它按平台发 `system.node`，仓库里没有 iOS 版。
   现在 `prepare-engine.sh` 的 `stage_system_addon` 用 `native/system` 的
   `flock.c` 对 iPhoneOS SDK 现编一份，覆盖 harness 里
   `@deepseek-ai/node-addon-system-darwin-arm64/bin/system.node`（本构建的
   `process.platform` 是 `darwin`，`flock.ts` 就是按这两个值找包），再 `--sign -`
   ad-hoc 签名——iOS 不让没有代码签名的 `.node` 被 `dlopen`，App 封印只管字节，
   不管代码签名。
   未验证的部分：`flock` 在 iOS libSystem 上的实际行为、ad-hoc 签名后的 `.node`
   在真机上能否加载、重签 `.ipa` 的工具是否会把它一并封进 CodeResources。这三条
   都只有真机能回答；失败形态是第一次落盘报 addon 加载错误，`engine.log` 里能看到。
2. **工具行来自 preset，`ios.patch.yml` 到不了那里——所以有第二个文件。**
   `tool-bash`、`tool-pwsh` 由每个 preset 在自己的作用域里挂载，而 patch 只能按
   Loader 行 id 覆盖，且一覆盖就换掉整份 `config`。`ios-preset.patch.yml` 因此把
   `preset-standard` 整行重述一遍、只删掉这两个进程工具（iOS 沙箱里没有
   fork/exec，留着也只会每次调用报 spawn 错）。它是
   `tooling/ios/make-ios-preset.py` 从
   `packages/bundle/web-app/presets/standard.patch.yml` 生成的：上游 preset 一改，
   `--check` 就会失败，提醒重新生成，避免手抄的副本悄悄漂移。`host.mjs` 先传
   `ios.patch.yml`、再传这一份；文件缺失时跳过（退化成模型多一个跑不动的 `bash`）。
   仍未解决：`minimal` preset 还带 `terminal-*`，所以只能用 `standard`；
   要换 preset 得先在 web bundle 里加一个 iOS 版。
3. **没在真机上跑过。** 这台设备没有 Node、没有 Xcode，`prepare-engine.sh`、
   Xcode 链接、`node::Start` 的返回、`--jitless` 下 harness 的实际速度，全部只有
   纸面推演。上面第 1、2 条同样没跑过——是从源码与 composition 读出来的结论。
   第 2 条唯一验证过的是结构：生成的 YAML 能解析、插件条目 34→32（只少那两个）、
   每一行都能逐字追回上游文件；它能否被 Loader 接受，只有真机知道。

## 排查

引擎起不来时先看 App 容器里的 `Library/Logs/engine.log`（设置页显示路径）：

- `Cannot find module .../lib/bin.js`：`prepare-engine.sh` 的 harness 步骤没跑完。
- `Loader` 报某个 provider 缺失：按 id 往 `ios.patch.yml` 加 `disabled: true`。
- 进程立刻退出、日志空白：多半是 dylib 没被签名或 rpath 不对，检查
  `otool -L DPSK.app/DPSK | grep node` 是否指向 `@rpath/libnode.dylib`。
