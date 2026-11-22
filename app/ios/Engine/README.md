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
2. 设环境：`DPSK_ENGINE_ROOT`、`DPSK_PORT`、`DSH_HOME`、`HOME`、`TMPDIR`、
   `DPSK_WORKSPACE`、`DPSK_LOG`——全在 App 容器里，App 沙盒之外哪也写不了。
   后两个由 App 直接给出走不通的路径，`host.mjs` 不再自己用 `HOME` 推：`HOME`
   是容器根，从它 `..` 会落到沙盒外，`mkdir` 直接 `EPERM`。
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

## 构建树缓存（CI 里最贵的那一步）

交叉编译 Node 要编两遍 V8，3 核 runner 上约两小时。所以 `prepare-engine.sh` 产出的构建树
（解包的 Node 源码 + `out/`）由 CI 缓存，下次直接接手。判断「能不能复用」不在缓存键里，
而在树自己身上：

- **stamp**：`out/.dpsk-ios-tree`，一行 JSON，记录两个 wrapper 脚本的哈希、补丁集指纹、Node 版本。
  wrapper 字节一致 ⇒ 编译参数（sysroot、`-DV8_TARGET_OS_IOS`、`-O3`/`-O1`、`-g0`）一致 ⇒ 对象有效。
  Xcode 或 SDK 一换，哈希就变，对象照规矩丢掉重建。
- **补丁集变了不丢树**：每个被补丁改写的文件，第一次打补丁前会在 `.dpsk-ios-pristine/` 留一份原件
  （随树进缓存）。补丁集一变，先把原件放回去再打当前这组——这也让**删掉**一个补丁真的生效，
  否则旧改动会一直留在源码里被编进去。
- **mtime 分层**：缓存往返不保证时间戳，而 make 只看时间戳。复用时把源码置 2000、`out/` 置 2001、
  被补丁改过的文件置 2002——严格递增，make 只重建补丁碰到的那几个 object。
  （`patch` 会保留原文件 mtime，所以补丁后要显式 touch，否则会链接旧对象。）
- **wrapper 路径固定**在 `$NODE_BUILD_DIR/toolchain`：gyp 会把路径写进每个生成的 makefile，
  路径一变就得重跑 configure，而 configure 重写生成物 → 全部重编。复用树时**不跑 configure**。
- **ccache** 兜底：workflow 装 ccache，wrapper 通过 `DPSK_CCACHE` 调它，目录在构建树里随缓存走。
  即使 make 仍决定重编（SDK 变动、生成物被重写），也是回放缓存对象而不是再编两小时。
  构建末尾会打印 `ccache --show-stats`，命中率就是下次要等多久的直接证据。

缓存键只哈希 `tooling/ios/tree-cache-key` 一个文件（内容是 `tree-3 node-24.22.3`），
Node 版本或暂存布局要变时才改它。patches 不进缓存键——那是 stamp 的事。
`ios.yml` 里还有三件配套：`cancel-in-progress: false`（推送不再杀掉正在跑的构建）、
保存后回查缓存是否真的存在（失败会打 warning）、以及每周两次只做 restore 的保温任务
（GitHub 7 天不读就回收）。

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
3. **`pnpm deploy` 不带 peer 依赖，harness 因此少首方包（已修，未复跑）。**
   `deploy` 只复制被部署包的 `dependencies`，peer 依赖要由消费者自己提供；而这条闭包
   里不少包把接口包声明成 peer（`dsh-atomic-write` 依赖 `dsh-error`、
   `tool-bash` 依赖 `dsh-shell`……），仓库里靠 workspace 顶层链接总能解析，部署树里
   却没有。第一次 import 就抛 `ERR_MODULE_NOT_FOUND`，App 只能看到引擎立刻退出。
   真机那份部署树实测缺 11 个：`dsh-attachment`、`dsh-compaction`、`dsh-error`、
   `dsh-fs`、`dsh-jobs`、`dsh-sandbox`、`dsh-scope`、`dsh-session-persistence`、
   `dsh-session-query`、`dsh-shell`、`dsh-workflow`。
   `prepare-engine.sh` 的 `stage_harness_peers` 现在拿部署树自检：首方 `lib/` 里
   import 的每个 `@deepseek-ai/*` 都必须在树内解析得到，缺的从本 checkout 拷进去，
   再查一遍（拷进来的包自己还会 import），最多 8 轮；checkout 里都没有的包直接
   fail loud。这条检查已在那份真机部署树上跑过，列出的正是上面 11 个；补拷逻辑在
   合成小树上验过两轮补全。整条链路（Mac 重跑 `prepare-engine.sh` → 重装 App →
   引擎真的起来）还没有复跑，需要一台有 Xcode 的机器。

   CI #39 又抓到同类缺口里更隐蔽的一个：`dsh-app-boot` 在模块顶层就 import
   `@deepseek-ai/cordis-plugin-group`，却只把它写成 `peerDependencies`（另外在
   `devDependencies` 里有一份给本仓开发用），而 `apps/cli` 提供了 cordis、include、
   loader、timer，独独漏了 group，于是 `pnpm deploy --prod` 不带它，部署树自检
   fail loud。根治在消费者一侧：`apps/cli` 的 `dependencies` 补上这一条，
   `pnpm-lock.yaml` 的 importer 同步（`workspace:~` 记成 `link:../../vendor/group`）。
   这类缺口以后仍会被自检拦下，但拦下只是 fail loud，不会自愈——`stage_harness_package`
   只认 checkout 顶层 `node_modules`，而 workspace 的包常常不在那里。
   另外注意：`ios` 工作流只在 `app/ios/**`、`tooling/ios/**` 改动时触发，只改 CLI
   依赖不会重跑构建，要动这两棵树里的文件。

4. **JIT 在这台设备上拿不到，`--jitless` 是唯一选项。** 用四种签名分别跑探针
   （裸 `ldid`；`com.apple.security.cs.allow-jit`；`platform-application` +
   `no-sandbox` + `get-task-allow`；TrollStore 式的
   `jb.pmap_cs.custom_trust` + `get-task-allow`）：`MAP_JIT` 一律 `EPERM`（iOS 没有这个 flag），
   `mmap(PROT_EXEC)` 得到的页被内核降成 `rw-`（崩溃报告里
   `VM_ALLOCATE ... rw-/rwx`），跳进去即 `EXC_BAD_ACCESS`（Instruction Abort）。
   所以 `DPSKEngineJIT` 保持 `false` 是对的，V8 只能解释执行。
5. **没在真机上跑完整链路。** 这台设备没有 Node、没有 Xcode，`prepare-engine.sh`
   和 Xcode 链接只能在 Mac 上做。已经跑过的部分是：App 里 `node::Start` 确实起来了
   （`engine.log` 有 `[engine] exited with 0 after 1s`，说明 `libnode.dylib` 加载、
   Node 启动、脚本执行都通了），死在 harness 的 import 上，也就是第 3 条。第 1 条
   （flock addon）、第 2 条（preset patch 是否被 Loader 接受）、`--jitless` 下 harness
   的实际速度，仍然只有重装之后才知道。
6. **包体积：`deploy` 会把 macOS 版一起带进来，现在按包名裁掉。**
   在 Mac 上 `pnpm deploy` 只解析当前平台的 optionalDependencies，于是树上多了
   LibreOffice 引擎（`@deepseek-ai/libreoffice-kit-darwin-arm64` 154 MB，其中
   `bin/dsoffice` 单个 141 MB）、它的 wasm 后端
   （`@deepseek-ai/libreoffice-kit-wasm` 145 MB，全无 Mach-O）、sherpa-onnx、
   sharp/libvips、koffi、ripgrep、esbuild 的 darwin 包，以及 node-pty 自带的
   Windows 预编译（`.dll`/`.pdb`/`.exe`）。这些在 iOS 上要么 dlopen 必失败，要么
   需要 JIT（`--jitless` 下 wasm 不可用），所以 `stage_harness` 里的
   `prune_foreign_platform_packages` 整个包删掉，顺带删掉指向它们的悬空链接。
   判据是 npm 给平台包的名字：OS 后面必须跟架构（`-darwin-arm64`、`-win32-x64`、
   `-linux-x64-gnu`），只有 OS 的 `@deepseek-ai/dsh-win32-process` 这类 JS 包必须留下。
   删包而不是只删文件，是为了让消费者拿到"这个平台没有这个包"（例如
   `@vscode/ripgrep` 的 `require.resolve` 本来就会抛同一句话），而不是"包在、二进制坏了"。
   这一步之后的 `prune_non_ios_binaries` 仍然负责其余的 Mach-O 与 prebuilds。
   没验的部分：真机 IPA 的实际大小、删完之后 harness 是否照常启动——都要等下一次
   Mac/CI 构建。

## 排查

引擎起不来时先看 App 容器里的 `Library/Logs/engine.log`（设置页显示路径）：

- `Cannot find module .../lib/bin.js`：`prepare-engine.sh` 的 harness 步骤没跑完。
- `ERR_MODULE_NOT_FOUND` 指向某个 `@deepseek-ai/dsh-*`：部署树缺首方包，
  `stage_harness_peers` 没跑到（或在 Mac 上用旧脚本打的包）。
- `Loader` 报某个 provider 缺失：按 id 往 `ios.patch.yml` 加 `disabled: true`。
- 进程立刻退出、日志空白：多半是 dylib 没被签名或 rpath 不对，检查
  `otool -L DPSK.app/DPSK | grep node` 是否指向 `@rpath/libnode.dylib`。
