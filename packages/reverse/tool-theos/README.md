---
description: "Theos scheduling over ctx.shell: reverse_theos_build runs the device's own make behind one approval, reverse_theos_scaffold writes a plain Objective-C tweak project to run it on."
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-theos

English | [中文](README.zh.md)

## Summary

The two tools that turn a hook the model wrote into something the device can actually load. `reverse_theos_scaffold` writes a Theos project — Makefile, control, filter plist and one Objective-C hook source that uses `MSHookMessageEx` instead of Logos — at an absolute path the user names. `reverse_theos_build` then runs the device's own `make` in that directory, through `ctx.shell`, and reports the exit status, the tail of both streams and the `.deb` the build wrote. The build executes the project's Makefile, which is code, so it goes through `ctx.approval` first and the prompt shows the exact command line; there is no configuration that skips that question. Neither tool installs anything: putting the `.deb` into the package manager is the user's step, and the resident's `hook.install` remains the runtime path when it is implemented.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## Use this package

Scaffold a project from a resolved symbol, then build it:

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

The approval prompt names the project, `THEOS` and the command (`make -C '<dir>' -j2 package`). A refused prompt, a missing approval service and an aborted call all leave the disk untouched.

<a id="understand-the-implementation"></a>
## Understand the implementation

The build resolves `make` from `Config.makePath`, `THEOS` from `Config.theosRoot` and the deadline from `Config.timeoutMs`, hands the resolved spec to `ctx.shell`, and waits for the foreground result. A spawn that never produced a process becomes one `HarnessError` with code `theos-unavailable` naming both settings, so a device without Theos reads as "make is not installed" rather than as a broken build. After a successful `package` or `do` run, the newest `.deb` under `packages/` is reported; a build that wrote none says so.

The scaffold validates the directory as absolute, both identifiers as reverse-DNS, and the project name as letters, digits and underscores. It refuses a directory that already holds entries unless `force` is true, because replacing a Makefile someone edited is not a repair. The hook source is plain Objective-C on purpose: a `%hook` block would need Logos, and then the source in the transcript is not the source that compiles.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- This device ships no Theos and no `make`, so today the build's only reachable outcome here is the `theos-unavailable` refusal; the success path has not been exercised on the device.
- The build is not sandboxed: approval is the whole gate, and a Makefile can do anything the harness user can.
- No `.deb` is installed by these tools, and a built tweak only takes effect through the package manager or a respring.
- The scaffold writes no Logos template, no Preferences bundle and no test target; it is one tweak dylib filtered to one bundle.
- A hook whose replacement signature does not match the original still compiles, and crashes the target when it runs.
