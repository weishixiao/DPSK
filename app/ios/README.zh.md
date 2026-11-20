---
description: "DPSK 的 iOS App：黑白极简壳，接远程 harness 主机；本机 Node 引擎是 Stage 2。构建、出包与装机步骤。"
---

# DPSK iOS App

中文 | [English](README.md)

## 现状

这个 App 是 harness 的**壳**：界面不另写一套，直接把 `dsh web` 的 Web UI 装进
`WKWebView`，所以聊天、思考、工具结果、审批、日志面板全部和桌面端一模一样，
不存在两套 UI 需要同步。

两种来源，代码里叫 `LaunchMode`：

| 来源 | 状态 | 说明 |
|---|---|---|
| 远程主机 | 可用 | 连局域网或 tailnet 上已经跑着 `dsh web` 的机器 |
| 本机引擎 | Stage 2 | 包内没有 Node 运行时，选了会明确报「未打包」，不会假装启动 |

App 里**不含**任何逆向能力，也不需要：逆向工具是 harness 侧的插件，跑在主机上，
设备侧只剩 `native/reverse-resident/` 这个 SpringBoard tweak。换句话说，手机上的
App 只是显示器，真正的 agent 在主机上运行。

## 目录

```
app/ios/
  project.yml         XcodeGen 描述，唯一的工程定义（仓库不存 .xcodeproj）
  Sources/
    DPSKApp.swift     入口
    AppModel.swift    状态机：远程 / 本机、重连、错误
    Settings.swift    设置模型与 UserDefaults 持久化
    EngineRuntime.swift  本机引擎的就位点（现在如实报未链接）
    WebContainer.swift   WKWebView 容器
    RootView.swift    黑白界面：连接页、失败页、设置页
  Engine/             Stage 2 的运行时目录，现在是占位说明
tooling/ios/build.sh  出未签名 ipa / 模拟器编译检查
.github/workflows/ios.yml  CI：macos runner 出 ipa 并作为 artifact 上传
```

## 界面

黑白、无多余装饰：纯黑背景，白色细线，等宽字体显示地址与错误；连上以后只在顶部
留一条半透明信息条（地址 + 刷新 + 设置），其余全是 Web UI 本身。设置页只有两项：
主机地址、来源。

## 构建

`.ipa` 只能在 macOS 上产出，这台手机上做不到（工具链只有 iOS 的 clang 和 SDK，
不能 archive 一个 App）。两条路：

**CI（推荐）**：把改动推到 GitHub，`ios` 工作流在 `macos-15` 上跑

```sh
tooling/ios/build.sh iphoneos "$RUNNER_TEMP/ipa"
```

产出的 `DPSK.ipa` 在 Actions 运行页的 Artifacts 里下载，保留 14 天。

**Mac 本机**：

```sh
brew install xcodegen
tooling/ios/build.sh iphoneos /tmp/dpsk-ipa
```

要真机调试就在 Xcode 里开 `app/ios/DPSK.xcodeproj`（先跑一次
`xcodegen generate`），给 target 选好 Team。

**Bundle ID** 在 `app/ios/project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER`，默认
`com.dpsk.harness`。第一次签名安装前改成你自己的——免费 Apple ID 的签名只认
一个没被占用的 ID。

## 装机

产物是**未签名** ipa，必须由签名工具装：Sideloadly、AltStore、eSign 之类，用它
自己的证书重签后安装。免费 Apple ID 的签名 7 天有效、最多 3 台设备。

装好后在 App 的设置里填主机地址，例如 `192.168.1.20:8787`（主机上先跑
`dsh web`）。地址不带协议时按 `http://` 处理；`https://` 原样使用。

## 与参考项目 dsh-Go 的差别

- 界面不重写：dsh-Go 是 Flutter 原生 UI；这里直接用 harness 自己的 Web UI，所以
  黑白色调靠 Web 端主题，壳只保证背景是纯黑、没有系统边框。
- 引擎不打包（Stage 2）：dsh-Go 在 App 进程内嵌 NodeMobile；这里先做远程，等
  引擎移植完成再填 `EngineRuntime.start()`。
- 没有分享扩展、没有小组件、没有 Siri：那些是 dsh-Go 的产品功能，不是本项目的
  需求。

## Stage 2：本机引擎

要在手机上真正跑 agent，还差这些，顺序即依赖：

1. 打包 NodeMobile（iOS）运行时，链接进 target，由 `EngineRuntime.start()` 启动
   `Engine/Engine/host.mjs`，监听 `127.0.0.1:8799`。
2. 让 `host.mjs` 起一个 iOS 可用的 profile：去掉 `dsh-bash-local`、
   `dsh-pwsh-local`、持久终端（iOS 上没有 bash、pwsh、PTY），`runtime/system`
   的 N-API addon 重编成 framework 嵌入。
3. 确认 `node:sqlite` 在这个 Node 版本上可用（会话持久化依赖它）。
4. 引擎崩溃隔离：`host.mjs` 捕获 `uncaughtException`/`unhandledRejection`，只让
   引擎重启，不带走界面。

这几步都必须在 macOS 上迭代，并且要在真机上验证——模拟器通过不等于真机通过。

## 文档配对

`README.md` 与 `README.zh.md` 是同一份内容的两种语言，改动一侧要同步另一侧，并在
有 Node 的机器上重录配对记录：

```sh
pnpm run verify-translation-pairing --write app/ios/README.md
```
