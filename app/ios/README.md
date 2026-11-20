---
description: "DPSK on iOS: a black-and-white shell that opens the dsh web UI of a remote harness host. Build, unsigned ipa, install; the local Node engine is stage two."
---

# DPSK iOS app

[中文](README.zh.md) | English

## What it is

The app is a **shell** around the harness: it draws no interface of its own, it opens
the `dsh web` UI in a `WKWebView`. Chat, thinking, tool results, approvals and the log
panel are therefore the desktop ones — there is no second UI to keep in sync.

Two sources, `LaunchMode` in the code:

| Source | State | Meaning |
|---|---|---|
| Remote host | works | a machine on the LAN or a tailnet already running `dsh web` |
| Local engine | stage two | no Node runtime is packed yet, so choosing it reports that plainly |

The app carries **no** reverse-engineering capability, and needs none: those tools are
harness plugins that run on the host, and the only device-side piece is the
`native/reverse-resident/` SpringBoard tweak. The phone is a display; the agent runs
on the host.

## Layout

```
app/ios/
  project.yml         XcodeGen spec, the only project definition (no .xcodeproj in git)
  Sources/
    DPSKApp.swift     entry point
    AppModel.swift    state machine: remote or local, reload, failure
    Settings.swift    settings model and UserDefaults persistence
    EngineRuntime.swift  where the local engine would start; states that it cannot yet
    WebContainer.swift   the WKWebView container
    RootView.swift    black and white UI: connecting, failure, settings
  Engine/             stage-two runtime directory, a placeholder today
tooling/ios/build.sh  unsigned ipa, or a simulator compile check
.github/workflows/ios.yml  CI: a macOS runner builds the ipa and uploads it as an artifact
```

## Build

An `.ipa` can only be produced on macOS: this device's toolchain has the iOS clang and
SDK, not the ability to archive an app. Two ways:

**CI**: push, and the `ios` workflow runs `tooling/ios/build.sh iphoneos "$RUNNER_TEMP/ipa"`
on `macos-15`; download `DPSK.ipa` from the run's Artifacts (kept 14 days).

**On a Mac**:

```sh
brew install xcodegen
tooling/ios/build.sh iphoneos /tmp/dpsk-ipa
```

To run on a device, open `app/ios/DPSK.xcodeproj` in Xcode (after `xcodegen generate`)
and pick a Team for the target.

**Bundle id** is `PRODUCT_BUNDLE_IDENTIFIER` in `app/ios/project.yml`, `com.dpsk.harness`
by default. Change it before the first signed install: a free Apple ID needs an id
nothing else holds.

## Install

The ipa is **unsigned**, so a signing tool (Sideloadly, AltStore, eSign) has to re-sign
it while installing. A free Apple ID signature lasts 7 days and covers 3 devices.

Then set the host in the app's settings, e.g. `192.168.1.20:8787` (run `dsh web` on the
host first). A bare host takes `http://`; an explicit `https://` is used as written.

## How it differs from dsh-Go

- No rewritten UI: dsh-Go is Flutter; this opens the harness's own Web UI, so the shell
  only keeps the background black and the chrome out of the way.
- No packed engine yet (stage two): dsh-Go embeds NodeMobile in the app process; this
  ships remote first and fills `EngineRuntime.start()` when the engine is ported.
- No share extension, widget or Siri: those are dsh-Go product features, not needed here.

## Stage two: the local engine

Running the agent on the phone still needs, in this order:

1. A NodeMobile (iOS) runtime linked into the target, started by
   `EngineRuntime.start()`, serving `127.0.0.1:8799` from `Engine/host.mjs`.
2. A profile that composes on iOS: drop `dsh-bash-local`, `dsh-pwsh-local` and the
   persistent terminal (there is no bash, pwsh or PTY), and rebuild `runtime/system`'s
   N-API addon as an embedded framework.
3. `node:sqlite` available on that Node build — session persistence depends on it.
4. Engine containment: `host.mjs` catches `uncaughtException`/`unhandledRejection` so a
   failed run restarts the engine instead of taking the UI with it.

All of it has to be iterated on macOS and verified on a device; a simulator pass is not
a device pass.

## Documentation pairing

`README.md` and `README.zh.md` carry the same content in two languages: change one, bring
the other, and re-record the pairing on a machine with Node:

```sh
pnpm run verify-translation-pairing --write app/ios/README.md
```
