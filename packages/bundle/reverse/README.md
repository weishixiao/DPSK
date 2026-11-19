---
description: "The optional DSH bundle that mounts the reverse-engineering capability: the ctx.reverse bridge plus the process, Mach-O, symbol, memory and tweak tools."
kind: "package-bundle"
---

# @deepseek-ai/dsh-reverse-bundle

English | [中文](README.zh.md)

## Summary

`dsh-reverse-bundle` mounts the device reverse-engineering capability as one layer over a base-backed profile: the bridge that dials the SpringBoard resident, and the six tool packages that reach it. Selecting the bundle is the only switch — leave it out of `dsh.profile.bundles` and nothing of this capability exists in that composition.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Further Exploration](#further-exploration)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

Add it to a profile's bundle list:

```yaml
dsh:
  profile:
    bundles:
      - base
      - reverse
```

Nothing else is needed to start: without the resident tweak the bridge answers `offline`, and the tools say so instead of failing the composition. To point the bridge elsewhere, give its row a config — the bundle inserts `reverse-bridge` with the resident's default socket path:

```yaml
- id: reverse-bridge
  name: '@deepseek-ai/dsh-reverse-bridge'
  config:
    socketPath: /var/mobile/Library/DSHReverse/rvd.sock
```

<a id="understand-the-implementation"></a>
## Understand the implementation

The bundle is a patch of `insert` rows only; it rewrites no row of the layers beneath it, so chat, the agent loop, persistence and approval behave exactly as they do without it. Rows are the bridge and `tool-reverse-process`, `tool-reverse-macho`, `tool-reverse-symbol`, `tool-reverse-memory`, `tool-reverse-tweak`. The resident is not a package here: it is the Theos tweak under `native/reverse-resident/`, which the bridge reaches only over its Unix socket.

<a id="further-exploration"></a>
## Further Exploration

- [The reverse group](../../reverse/README.md): what each package owns.
- [Deployment](../../../docs/reverse/readme.md): Theos build, socket permissions, model routing.

<a id="model-experience"></a>
## Model Experience

The model sees six tools named `reverse_*`. Reads (`reverse_status`, `reverse_process_list`, `reverse_process_images`, `reverse_macho_analyze`, `reverse_symbols`, `reverse_memory_read`, `reverse_memory_scan`) run without asking; `reverse_memory_write`, `reverse_hook_install` and `reverse_inject_dylib` each require one "allow once" inside the open turn, with a summary naming the process, address and value. Failures come back as the protocol's stable codes (`not-connected`, `denied`, `unsupported`), so the model can tell a missing resident from a refused `task_for_pid`.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- `reverse_hook_install` and `reverse_inject_dylib` answer `unsupported` from the resident: cross-process hooking and injection are not implemented in this build. The tweak tool still generates and saves Substrate source, which is the supported path.
- The bundle has no per-capability flag. A composition with the tools but without the bridge would answer every call with a configuration error, which is worse than the capability being absent.

## Dev Note

The bundle's `dependencies` name every row's package so the profile resolver can load them; a row added here must be added there too.