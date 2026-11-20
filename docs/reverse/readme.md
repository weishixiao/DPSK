---
description: "The iOS reverse-engineering workbench added on top of DeepSeek Harness: bridge plugin, SpringBoard resident, protocol, assembly, switches, deployment, and troubleshooting."
---

# iOS reverse-engineering workbench

[中文](readme.zh.md) | English

## Overview

This capability is **additive** over DeepSeek Harness: `packages/core/*`, `packages/client/*` and the approval interaction packages are unchanged. Three layers are new:

1. **Harness-side plugins** (`packages/reverse/*`): a capability seam, a local-socket provider, and six model-facing tools.
2. **A profile bundle** (`packages/bundle/reverse`): lists those rows as one optional layer — selected or absent, never half-loaded.
3. **A device-side resident** (`native/reverse-resident/`): a Theos tweak injected into SpringBoard that owns the platform identity and actually touches processes and memory.

The harness process **never** calls `task_for_pid`, `mach_vm_*` or `dlopen` injection; it writes requests to one Unix domain socket.

## Table of Contents

- [Architecture](#architecture)
- [Node-side additions](#node-side-additions)
- [IPC protocol](#ipc-protocol)
- [Device-side resident](#device-side-resident)
- [Assembly and switches](#assembly-and-switches)
- [Models and API keys](#models-and-api-keys)
- [Workflow](#workflow)
- [Security boundary](#security-boundary)
- [Known boundaries](#known-boundaries)
- [Troubleshooting](#troubleshooting)

-----

<a id="architecture"></a>
## Architecture

```
model ↔ agent-loop (core, unchanged)
         │ tool.execute
         ▼
   dsh-tool-reverse-* (six tools: argument shape and approval only)
         │ ctx.reverse.call()
         ▼
   dsh-reverse-bridge (capability seam + local-socket provider)
         │ NDJSON over /var/mobile/Library/DSHReverse/rvd.sock
         ▼
   ReverseResident (tweak inside SpringBoard)
         │ task_for_pid / mach_vm_* / Mach-O parsing
         ▼
      target process
```

The seam has the usual three roles: `ReverseBridge` (Service Definition, `packages/reverse/bridge/src/seam.ts`), `LocalSocketReverseBridge` (Provider), `dsh-tool-reverse-*` (Consumer). Tools never see the socket; the provider never sees a tool.

<a id="node-side-additions"></a>
## Node-side additions

| Path | Role |
|---|---|
| `packages/reverse/protocol/` | Operation table, request/response frames, error codes, argument validation (`validate.ts`), line framing (`frame.ts`) |
| `packages/reverse/bridge/` | Seam `ReverseBridge` and the socket provider; asks `ctx.approval` before every mutating operation |
| `packages/reverse/tool-process/` | `reverse_status`, `reverse_logs`, `reverse_process_list`, `reverse_process_images` |
| `packages/reverse/tool-macho/` | `reverse_macho_analyze` |
| `packages/reverse/tool-symbol/` | `reverse_symbols` |
| `packages/reverse/tool-memory/` | `reverse_memory_read`, `reverse_memory_scan`, `reverse_memory_write` |
| `packages/reverse/tool-tweak/` | `reverse_hook_install`, `reverse_inject_dylib` (behind one approval; the installation itself answers `unsupported`) |
| `packages/reverse/scripts/` | `reverse_script_save`, `reverse_script_list`, `reverse_script_read`, `reverse_script_delete`: hooks, memory scripts and notes kept as files |
| `packages/bundle/reverse/` | Optional bundle whose `cordis.patch.yml` only inserts its own rows |
| `packages/llm/llm-failover/` | Multi-model routing: when a provider answers with a quota or credential failure, the next step selects the next configured provider |

Registration-only edits: the alias region of `tsconfig.base.json`, the references in `tsconfig.host.json`, and each package's `tsconfig.json` and `tsdown.config.ts`.

<a id="ipc-protocol"></a>
## IPC protocol

One JSON object per line, UTF-8, terminated by `\n`; a single frame is capped at 8 MiB.

Request:

```json
{"id":"<uuid>","op":"memory.read","args":{"pid":1234,"address":"0x100004000","length":64}}
```

Response, same `id`:

```json
{"id":"<uuid>","ok":true,"result":{"address":"0x100004000","length":64,"hex":"...","ascii":"..."},"elapsedMs":3}
{"id":"<uuid>","ok":false,"error":{"code":"denied","message":"task_for_pid(1234) was refused ..."},"elapsedMs":2}
```

Operations: `system.hello`, `system.logs`, `process.list`, `process.images`, `process.symbols`, `macho.analyze`, `memory.read`, `memory.scan`, `memory.write`, `hook.install`, `inject.dylib`.

Error codes: `bad-request`, `invalid-args`, `not-connected`, `timeout`, `cancelled`, `denied`, `not-found`, `target-gone`, `unsupported`, `protocol-mismatch`, `remote-error`.

`system.hello`'s `ops` is what that resident **actually serves**. The current build serves the first nine; `hook.install` and `inject.dylib` answer `unsupported` with the reason (see [known boundaries](#known-boundaries)).

<a id="device-side-resident"></a>
## Device-side resident

Source lives in `native/reverse-resident/`:

| File | Content |
|---|---|
| `Tweak.xm` | `%ctor` starts the listener and hooks nothing of SpringBoard's own behaviour; a start-up exception is logged and leaves the resident offline rather than the desktop down |
| `ReverseResident.plist` | Filter: only `com.apple.SpringBoard` |
| `RVServer.m` | Listening socket, line framing, dispatch table, `system.hello`, and the answered-request ring behind `system.logs`; every request runs in its own autorelease pool inside an exception boundary that turns a raised exception into a `remote-error` frame |
| `RVProcess.m` | Process list (`sysctl` + `proc_pidpath`), image enumeration (Mach-O headers found at VM-region starts), symbol table reading and rebasing |
| `RVMachO.m` | File-level analysis: dependencies, segments and sections, encryption flag, platform, Objective-C names, strings |
| `RVMemory.m` | `mach_vm_read_overwrite` reads, region-walk scans, writes that save and restore the region's protection |

### Failure containment

The resident runs inside SpringBoard, so every failure it allows to escape costs the home screen. Three boundaries keep a bug on the resident's side of that line:

| Boundary | What it contains |
|---|---|
| `%ctor` | A start-up exception is logged and swallowed: the socket is simply never created, `reverse_status` answers `offline`, and the desktop keeps running |
| Dispatcher (`RVServer.m`) | An exception raised while serving one operation becomes that request's `remote-error` frame; the answer is delivered, the connection stays open, the next request is served normally |
| Per-request pool (`RVServer.m`) | Each answer's temporaries are released before the next line is read, so a long-lived client does not accumulate the memory of every scan it ever asked for |

An exception is never swallowed silently: it is logged with its name and reason, which is what `log stream --predicate 'eventMessage CONTAINS "rv:"'` shows.

The tweak also chains, rather than replaces, the process's uncaught-exception handler, so another tweak's handler and the system's own crash reporting keep working.

### Locating a target

`reverse_process_list` takes a name fragment or a **bundle identifier**: `com.burbn.instagram` finds the app as well as `Instagram` does, and the answer carries the `bundleId` of each process. A filter that starts with a reverse-DNS prefix is validated as a bundle identifier before it is sent, so a malformed one is refused here instead of coming back as an empty list that reads like "the app is not running".

### The operation log

`reverse_logs` reads the resident's own answered-request log: one line per request, with its moment (UTC), operation name, verdict, elapsed time and failure text. It is the first-hand answer to "why was that call refused" — `unsupported`, `invalid-args` and `denied` keep their exact words here, without going back to SpringBoard's `rv:` system log.

The ring lives in the resident's memory, capped at 200 entries: a respring clears it, and entries pushed out by newer ones are only counted, with the tool's rendering saying how many (the result's `dropped`). The log is never written to disk, so it carries no history across sessions.

### Theos environment

You need a Theos able to build arm64/arm64e tweaks (on device with `ldid`, or cross-compiling on a Mac):

```sh
export THEOS=$HOME/theos
cd native/reverse-resident
make package            # produces packages/*.deb
make install            # or hand the deb to the user's package manager
```

`control` declares `Depends: mobilesubstrate`; the resident assumes Substrate/ElleKit injection.

### Install and run

1. Install the deb, then respring (the package manager's respring, or `killall -9 SpringBoard`).
2. On SpringBoard launch the resident creates `/var/mobile/Library/DSHReverse/rvd.sock` (0666).
3. Confirm in the log: `log stream --predicate 'eventMessage CONTAINS "rv:"'` shows `rv: resident listening on ...`.

<a id="assembly-and-switches"></a>
## Assembly and switches

The capability switches **as a whole** through one bundle: add `@deepseek-ai/dsh-reverse-bundle` to the profile's `dsh.profile.bundles` to enable it, remove it to make it non-existent.

One capability can also be dropped on its own: give that row `config: { enabled: false }`, and the package registers no tools at all. The model then has nothing to call, and no approval prompt can appear for it. This is the switch for "keep process and memory analysis, drop the hook generator".

```yaml
    - id: tool-reverse-tweak
      name: '@deepseek-ai/dsh-tool-reverse-tweak'
      config:
        enabled: false        # no reverse_hook_install, no reverse_inject_dylib
```

| Row | Capability | Tools it brings |
|---|---|---|
| `reverse-bridge` | The seam itself | — |
| `tool-reverse-process` | Running processes and the answered-request log | `reverse_status`, `reverse_logs`, `reverse_process_list`, `reverse_process_images` |
| `tool-reverse-macho` | Static file analysis | `reverse_macho_analyze` |
| `tool-reverse-symbol` | Symbol lookup | `reverse_symbols` |
| `tool-reverse-memory` | Reading, scanning, writing target memory | `reverse_memory_read`, `reverse_memory_scan`, `reverse_memory_write` |
| `tool-reverse-tweak` | Hook and inject requests | `reverse_hook_install`, `reverse_inject_dylib` |
| `reverse-scripts` | Saved scripts on disk | `reverse_script_save`, `reverse_script_list`, `reverse_script_read`, `reverse_script_delete` |

Fragment for your own profile:

```yaml
# ~/.dsh/profiles/reverse.yml (merge into your existing profile's shape)
dsh:
  profile:
    bundles:
      - base
      - reverse            # this workbench
```

`reverse-bridge` settings (config of the row of the same name in `cordis.yml`):

| Field | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Off fails every call without sending anything, with the rows still mounted |
| `socketPath` | `/var/mobile/Library/DSHReverse/rvd.sock` | Must match the resident |
| `timeoutMs` | `20000` | Deadline of one request |
| `connectTimeoutMs` | `2000` | Deadline of a single dial |

`reverse-scripts` keeps what it writes in `<dsh home>/reverse/scripts` (one file per script: `.xm` for a hook, `.json` for a memory script, `.md` for a note). Set `directory` on that row to point it somewhere an editor or Theos can reach. Saving the same name again replaces the file, which is how an edited script is written back.

Without the resident installed, `reverse_status` answers `offline` with the reason instead of failing the composition.

<a id="models-and-api-keys"></a>
## Models and API keys

`packages/llm/llm-failover` is a separate optional plugin: it listens on `agent/request-error` and, when the failure is one that another provider can serve (`QUOTA`, `ACCOUNT_QUOTA`, `INVALID_CREDENTIAL`, `MISSING_CREDENTIAL`, `AUTH`, `ACCOUNT_SIGN_IN_REQUIRED`, `ACCOUNT_TOKEN_INVALID`), selects the next configured provider with `agent.model.select({provider, model})` and returns `{kind:'retry'}`. The switch applies to **later steps**, which is the `agent/request` waterfall's semantics.

```yaml
- id: llm-failover
  name: '@deepseek-ai/dsh-llm-failover'
  config:
    enabled: true
    candidates:
      - provider: deepseek
        model: deepseek-chat
      - provider: zhipu          # GLM adapter
        model: glm-4.6
    loopGuard: 100
```

Keys stay with the existing credentials/settings: `DEEPSEEK_API_KEY` (or the `deepseek` provider's credential entry); the GLM key is a provider credential too and never goes into `cordis.yml`.

<a id="workflow"></a>
## Workflow

1. `reverse_status` — resident online, protocol version, served operations.
2. `reverse_process_list {filter:"SpringBoard"}` — get the pid.
3. `reverse_process_images {pid}` — what is mapped (when `path` is empty, select by `base`).
4. `reverse_symbols {pid, image:"/usr/lib/libobjc.A.dylib", filter:"class_"}` — runtime addresses.
5. `reverse_macho_analyze {path:"/var/containers/.../App.app/App"}` — encrypted, dependencies, Objective-C name tables.
6. `reverse_memory_scan {pid, type:"u64", value:"0"}` — find a value (coins, remaining attempts).
7. `reverse_memory_write {pid, address:"0x...", type:"u64", value:"999999"}` — each write needs one "allow once" inside the open turn.
8. `reverse_hook_install` — takes the hook source you wrote and puts it through approval; this build's resident answers `unsupported`, so what you keep is the source itself (see the boundary below).

<a id="security-boundary"></a>
## Security boundary

- **The bridge enforces approval**: `ReverseBridge.mutate()` asks `ctx.approval` before sending, and sends nothing without it. No tool exposes a way to skip it.
- **Approval must be requested inside the open turn**: otherwise `approval.request()` throws `outside an open turn` — existing behaviour, not introduced here.
- **The harness process never touches the target**: no `task_for_pid`, no `mach_vm_*`, no injection.
- **The resident makes no second decision**: it executes approved frames with SpringBoard's own privileges, so whether it exists at all is the bundle's decision.
- **Arguments are validated in the bridge first**: `normalize.ts` canonicalizes and rejects addresses, lengths, limits, value widths and paths before anything becomes a question a person must answer.

<a id="known-boundaries"></a>
## Known boundaries

| Item | State |
|---|---|
| `hook.install` | Answers `unsupported`. Cross-process inline hooking needs a hook engine inside the target, which this build does not carry; `reverse_hook_install` still takes the source you wrote and puts it through approval, so the source in the transcript is the starting point for a Theos-built tweak |
| `inject.dylib` | Same, `unsupported`. Load the dylib with the jailbreak's own injector or a tweak filter |
| Remote Theos builds | `system.hello`'s `theos` field only reports whether Theos is visible on device; the resident does not drive a build yet |
| `objc-method` symbols | Inferred from the file's symbol and name tables only; the target runtime's class/method lists are not read yet |
| Reach of the exception boundary | It contains Objective-C exceptions and mach errors that return a code. A wild pointer or `SIGSEGV` is a process-level crash no in-process guard can contain — what the tweak guarantees is narrower: a resident that fails to start never takes the desktop with it |
| Bilingual pairing record | `readme.i18n.yaml` for this directory is not generated yet: on a machine with Node run `pnpm run verify-translation-pairing --write docs/reverse/readme.md` |

<a id="troubleshooting"></a>
## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `reverse_status` answers `offline` / `not-connected` | Resident not loaded or socket missing: confirm the deb is installed and the device respringed; check `/var/mobile/Library/DSHReverse/rvd.sock` |
| `denied: task_for_pid(...) was refused` | Target is hardened/platform, or the tweak lacks platform identity; confirm it is injected into SpringBoard |
| `protocol-mismatch` | The two ends disagree on `PROTOCOL_VERSION`: update harness and resident together |
| A written value reverts at once | The target remaps the page or checks its protection; use the hook path, or pick a writable page |
| Too many scan hits | Narrow with `range`, or locate with `reverse_symbols` and then `reverse_memory_read` |

## Dev Note

To add an operation: one row in `protocol/src/types.ts` (name, arguments, result), its check in `validate.ts`, a branch in the bridge's `normalize.ts`, a schema in the tool package, and a handler row in `RVServer.m`. The compiler and the type checker keep all five in step.