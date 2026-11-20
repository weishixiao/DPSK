---
description: "The reverse-engineering capability group: a seam to a device resident, its local-socket provider, the wire protocol, and the model-facing tools for processes, images, symbols, Mach-O files and memory."
kind: "package-group"
---

# reverse/ — device reverse-engineering family

English | [中文](README.zh.md)

## Summary

The reverse group gives a composition read access to processes and memory on the jailbroken device it runs on, plus the one write and the two dangerous operations that require a human decision. The group owns no privileged primitive: `protocol` fixes the wire vocabulary, `bridge` owns the `ctx.reverse` seam and dials the resident's Unix socket, and the `tool-reverse-*` packages turn model calls into validated protocol requests. The privileged half — `task_for_pid`, `mach_vm_*`, hook installation — lives in a SpringBoard tweak under `native/reverse-resident/` in this repository and is not a package of it. This page maps the group; each package README owns its per-package contract, and [`docs/reverse/readme.md`](../../docs/reverse/readme.md) owns deployment.

## Table of Contents

- [Packages](#packages)
- [Related documentation](#related-documentation)
- [Dev Note](#dev-note)

-----

<a id="packages"></a>
## Packages

| Package | Role | ctx key |
|---|---|---|
| [`protocol/`](protocol/README.md) | Operation table, frames, error codes, argument validation, line framing | — |
| [`bridge/`](bridge/README.md) | Defines `ctx.reverse` and serves it over the resident's Unix socket, asking approval before anything that changes the target | `ctx.reverse` |
| [`tool-process/`](tool-process/README.md) | `reverse_status`, `reverse_process_list`, `reverse_process_images` | registers tools |
| [`tool-macho/`](tool-macho/README.md) | `reverse_macho_analyze`: load commands, sections, dependencies, encryption, names, strings | registers tools |
| [`tool-symbol/`](tool-symbol/README.md) | `reverse_symbols`: runtime addresses from a target's image symbol tables | registers tools |
| [`tool-memory/`](tool-memory/README.md) | `reverse_memory_read`, `reverse_memory_scan`, and the approved `reverse_memory_write` | registers tools |
| [`tool-tweak/`](tool-tweak/README.md) | `reverse_hook_install`, `reverse_inject_dylib`: generated Substrate source and the approvals in front of both | registers tools |
| [`scripts/`](scripts/README.md) | `reverse_script_save`, `reverse_script_list`, `reverse_script_read`, `reverse_script_delete`: hooks, memory scripts and notes kept as files | registers tools |

The bundle that lists these rows is [`packages/bundle/reverse`](../bundle/reverse/README.md); the resident's source, build and installation are in [`native/reverse-resident`](../../native/reverse-resident/README.md).

-----

<a id="related-documentation"></a>
## Related documentation

- [Deployment and operation](../../docs/reverse/readme.md): Theos build, socket permissions, capability switch, model routing.
- [Architecture](../../docs/architecture.md): where a capability seam belongs in a composition.

## Dev Note

A new operation is five edits, kept in step by the compiler: the operation table in `protocol`, its validation, a `normalize.ts` branch in `bridge`, the tool schema, and a handler row in the resident's `RVServer.m`.