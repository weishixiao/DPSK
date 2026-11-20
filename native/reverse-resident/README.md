# reverse-resident — the device half of the reverse capability

English | [中文](README.zh.md)

## What this is

A SpringBoard tweak that serves the harness's reverse-engineering operations on the device itself: process listing, image and symbol enumeration, static Mach-O analysis, and memory read/scan/write. It is the only place in this project where `task_for_pid`, `mach_vm_*` and hook installation live; the harness process never opens a task, writes memory, or loads a dylib.

It is a tweak rather than a daemon on purpose: `task_for_pid` on a third-party app needs the platform identity SpringBoard already holds, and a dylib inside SpringBoard's task inherits it. A jailed helper would need its own entitlements and would be refused.

Not part of the pnpm workspace: it builds with Theos, not with the harness.

## Wire

One Unix domain socket, `/var/mobile/Library/DSHReverse/rvd.sock`, NDJSON frames, protocol version `1`. The vocabulary — operation names, argument validation, error codes — is `@deepseek-ai/dsh-reverse-protocol`'s; `RVPrelude.h` keeps deliberately free of TypeScript vocabulary and repeats only the strings.

A malformed line drops that connection instead of resynchronizing, so a partial write can never be read as a different operation.

## Build and install

```sh
THEOS=/opt/theos make package            # rootless / rootful
THEOS=/opt/theos THEOS_PACKAGE_SCHEME=roothide make package
```

Install the resulting `.deb` with your package manager, then respring: the listener starts from the tweak's constructor, and the first start creates `/var/mobile/Library/DSHReverse` with mode `0700`.

Confirm it is up by its own log line, `rv: resident listening on …`, and by `reverse_status` from the harness. [The deployment page](../../docs/reverse/readme.md) covers socket permissions, the capability switch and model routing.

## Operations

| Operation | Status |
|---|---|
| `system.hello` | answers the protocol version and the operation list |
| `system.logs` | a ring of the last 200 answers: moment (UTC ISO-8601), operation, verdict, elapsed time, failure text |
| `process.list`, `process.images` | `proc_listpids`, then the target's own `vm_region_recurse` walk to find its Mach-O headers |
| `process.symbols` | the image file's `LC_SYMTAB` and export names, rebased by the image's load address in the target |
| `macho.analyze` | on-disk file: load commands, sections, dylibs, encryption, strings |
| `memory.read`, `memory.scan` | `mach_vm_read_overwrite` over the target's regions |
| `memory.write` | `mach_vm_protect` + `mach_vm_write`, restoring protection afterwards |
| `hook.install`, `inject.dylib` | **`unsupported`**: cross-process hooking and injection are not implemented here |

`unsupported` is a real answer, not a stub: the operation is in the table so a client learns the capability is absent rather than getting a silent timeout, and `system.hello` reports the same list.

## Notes

- The socket is created `0600` in a `0700` directory: only `mobile` (and `root`) reach it. Anything that can reach it can write memory in other processes — treat the socket as a root-equivalent capability.
- `memory.write` restores the region's original protection even when the write fails, and reports what was there before.
- The log ring lives in memory only: a respring clears it, and past 200 entries the oldest are dropped with `dropped` reporting how many. Writes and reads take the same `@synchronized` lock, so two clients answering at once never interleave entries.
- Scan and read are bounded by `RV_MAX_FRAME_BYTES` (8 MiB) and `RV_MAX_READ_LENGTH` (1 MiB); the client validates the same limits first, so a refused request fails before it reaches the device.
- The four operation files compile and link against the iOS 18.5 SDK with `-Wall -Wextra` clean; `Tweak.xm` additionally needs Logos and `libsubstrate`, which only a Theos toolchain provides.