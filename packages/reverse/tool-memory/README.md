---
description: "Memory over ctx.reverse: read, scan, and the approved write — the one operation here that changes a running app."
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-memory

English | [中文](README.zh.md)

## Summary

`reverse_memory_read` renders bytes at an address as hex and ASCII, `reverse_memory_scan` searches one process for a typed value (u8…i64, float, double) and returns the addresses it found, and `reverse_memory_write` overwrites one value of that typed shape. The first two are reads and run without asking; the write is the sharpest edge in the harness, so it goes through `ctx.reverse.mutate()` and its approval names the process, the address, the type and both values.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## Use this package

```json
{ "tool": "reverse_memory_scan", "arguments": { "pid": 1234, "type": "i32", "value": "99999", "limit": 20 } }
{ "tool": "reverse_memory_write", "arguments": { "pid": 1234, "address": "0x104a1c2d0", "type": "i32", "value": "999999" } }
```

The write returns what was there before, so a change can be undone with the same call.

<a id="understand-the-implementation"></a>
## Understand the implementation

The scan walks the target's readable regions and matches the typed value byte for byte, honoring an optional address range and a result cap. The write protects the region writable, writes, and restores the original protection even on failure. Lengths and counts are validated on the harness side first, so an oversized request never reaches the device.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- The scan matches one exact value at one width; there is no range match, no "changed between two snapshots" mode, and no pointer-chain resolution.
- A write outside the target's mapped, writable-after-protect memory fails with the resident's reason; nothing is written partially and silently.
- Nothing keeps a log of past writes beyond the session's own tool results: an undo is the caller's responsibility.
