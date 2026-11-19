---
description: "The two tools that put code into a target: reverse_hook_install for one Substrate hook, reverse_inject_dylib for a dylib injection — both behind one approval."
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-tweak

English | [中文](README.zh.md)

## Summary

The two tools whose arguments are code. `reverse_hook_install` takes a pid, an image, a symbol, a mode (`replace` or `log-only`) and the complete hook source — the replacement function and its `MSHookFunction`/`MSHookMessageEx` statement — and asks the resident to install it. `reverse_inject_dylib` takes a pid and a dylib path on the device. Both change the running process, so both go through `ctx.reverse.mutate()`: the approval prompt names the process and shows the source before anything is sent, and only "allow once" lets the frame out. This build's resident answers both with `unsupported`, so the model learns that plainly instead of guessing — and the source it wrote stays in the transcript, ready to be built with Theos.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## Use this package

Resolve the symbol with `reverse_symbols` first, then:

```json
{ "tool": "reverse_hook_install",
  "arguments": {
    "pid": 1234,
    "image": "App",
    "symbol": "-[VIPManager isVip]",
    "mode": "log-only",
    "source": "…the replacement function and its MSHookMessageEx statement…"
  } }
```

The approval prompt names the process and shows the source, elided after a couple of dozen lines. Build and install the generated tweak with Theos — see the deployment page; this tool runs no compiler.

<a id="understand-the-implementation"></a>
## Understand the implementation

The source is checked for shape and length before it is sent, and it travels as a string: nothing in the harness compiles or evaluates it. These two operations are the only ones here that can change behaviour rather than data, which is why their approval is not optional even when the resident will refuse them.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- Runtime installation is not implemented: the resident answers `hook.install` and `inject.dylib` with `unsupported`. The supported path is generate here, build with Theos, install with the package manager.
- Nothing type-checks the source against the target's headers; a hook that compiles is not a hook that works.
- The harness drives no cross-compiler, so no build result comes back to the transcript.
- `inject.dylib` takes a path already on the device; the tool uploads no library.