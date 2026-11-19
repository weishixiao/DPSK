---
description: "The ctx.reverse seam and its local-socket provider: one NDJSON connection to the SpringBoard resident, with approval required before anything that changes the target."
kind: "package-reference"
---

# @deepseek-ai/dsh-reverse-bridge

English | [中文](README.zh.md)

## Summary

`dsh-reverse-bridge` defines `ctx.reverse` and serves it over the resident's Unix domain socket. Three calls: `state` (whether the resident is reachable), `status()` (the resident's own view: protocol version, operation list, uptime) and `call(op, args)` for reads. The fourth, `mutate(op, args, options)`, is only for the operations that change the running target — a memory write, a hook, an injection — and it asks the approval service first, inside the open turn. The provider is the package's default export, so listing the package in a composition mounts it with its default socket path.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

```yaml
- id: reverse-bridge
  name: '@deepseek-ai/dsh-reverse-bridge'
  config:
    socketPath: /var/mobile/Library/DSHReverse/rvd.sock   # the default
```

Another plugin reads through the seam:

```ts
const { processes } = await ctx.reverse.call('process.list', {})
```

<a id="understand-the-implementation"></a>
## Understand the implementation

One connection is dialed lazily and reused; a dropped resident is reported as `not-connected` rather than queued, because a stale answer about a process is worse than none. `mutate` calls `ctx.approval.request()` with a summary the caller writes (process, address, type, both values), and an `allowed-once` is what lets the frame go out; a denial becomes `denied` with the reason the user saw. Every call is bounded by a deadline and by the caller's `AbortSignal`.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- No reconnect backoff: a resident installed after the harness started is picked up on the next call, not by a watcher.
- The approval for a mutation is requested even when the resident will answer `unsupported`, so the user is asked before a no-op. The tools for those two operations are marked as such in their own READMEs.

<a id="dev-note"></a>
## Dev Note

`normalizeArguments` runs here, not only in the tools, so a hand-written `ctx.reverse.call` gets the same validation as a model call. Anything new that changes the target must be added to `DangerousOp` in the protocol package, or `mutate` will refuse it.
