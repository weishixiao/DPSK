---
description: "The wire vocabulary of the reverse capability: operation names, argument shapes and validators, NDJSON frames, error codes and line framing, shared by the harness and the SpringBoard resident."
kind: "package-reference"
---

# @deepseek-ai/dsh-reverse-protocol

English | [中文](README.zh.md)

## Summary

`dsh-reverse-protocol` is the one place the two ends of the reverse capability agree on anything: the operation table (`ReverseOp`) and which operations change the target (`DANGEROUS_OPS`, `isDangerousOp`), each operation's arguments and result, the per-field validators every argument passes before it is framed (`validatePid`, `validateAddress`, `validateLength`, `validateImageSelector`, `validateDevicePath`, `validateSource`, `validateValue`, …), `PROTOCOL_VERSION`, the request and response frame unions, `ReverseErrorCode`, and the framing — `encodeFrame`, `parseResponse`, `LineFramer`, `MAX_FRAME_BYTES`. It is a library: no context key, no tools, nothing mounted. Both ends depend on it and neither depends on the other.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

Validators throw `ReverseArgsError` naming the field, so nothing malformed ever reaches a socket:

```ts
import { validateAddress, validatePid } from '@deepseek-ai/dsh-reverse-protocol'

const pid = validatePid(raw.pid)
const address = validateAddress(raw.address)
```

A tool normally goes through `@deepseek-ai/dsh-reverse-bridge`'s `normalizeArguments(op, raw)`, which runs these validators as one per-operation shape and returns the typed arguments.

<a id="understand-the-implementation"></a>
## Understand the implementation

Validation is synchronous and total: a rejection names the field. The resident re-validates the same shapes in Objective-C, so a hand-written client cannot skip the contract. Frames are capped at `MAX_FRAME_BYTES` (8 MiB), and a `LineFramer` that meets a longer line fails the connection rather than truncating a request — a partial write must never be read as a different operation.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- `hook.install` and `inject.dylib` are in the table but the resident answers `unsupported`; they stay listed so `system.hello` can report the gap honestly.
- Nothing here knows about approvals: which operations need one is the bridge's decision, keyed on `isDangerousOp`.

<a id="dev-note"></a>
## Dev Note

The operation table is the schema of the whole capability. Adding an operation means adding it to `types.ts` first; the bridge's `normalize.ts` and the tools' schemas then fail to compile until they agree.