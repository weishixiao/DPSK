# 本机引擎（Stage 2 预留）

`project.yml` 把这个目录整体作为资源拷进 `DPSK.app/Engine/`，运行期由
`Sources/EngineRuntime.swift` 用名字找到它。目录里现在只有这份说明，所以
`EngineRuntime.bundled()` 返回 nil，App 只提供「远程主机」一种来源。

Stage 2 要放进来的是：

```
Engine/
  host.mjs        Node 入口：boot 一个受支持的 dsh profile，并把 Web UI 监听到 127.0.0.1:8799
  runtime/        Node 运行时（NodeMobile 版本的二进制与启动脚本）
  README.md       这份说明
```

约定：

- `host.mjs` 必须让 Web UI 监听 `127.0.0.1:8799`——壳按这个端口打开 WKWebView；
  端口在 `EngineRuntime.defaultPort` 里，改一处即可。
- iOS 上没有 bash、pwsh、PTY，`runtime/system` 的原生 addon 也要重编；因此本机
  引擎使用的 profile 必须去掉 `dsh-bash-local`、`dsh-pwsh-local`、持久终端等行，
  否则 compose 会在加载时失败。
- 引擎在 App 进程内运行，所以崩溃会连界面一起带走：`host.mjs` 必须捕获
  `uncaughtException`/`unhandledRejection` 并写日志，不能默认退出。
