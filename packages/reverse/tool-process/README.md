---
description: "The process-discovery tools: reverse_status, reverse_process_list and reverse_process_images."
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-process

English | [中文](README.zh.md)

## Summary

Three read-only tools over `ctx.reverse`: `reverse_status` reports whether the resident is reachable and what it speaks, `reverse_process_list` lists live processes with their pids and paths, and `reverse_process_images` lists the Mach-O images mapped into one process, each with its base address. Nothing here changes the target, so nothing here asks for approval.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## Use this package

Mount `@deepseek-ai/dsh-reverse-bridge` and this package. A call looks like:

```json
{ "tool": "reverse_process_images", "arguments": { "pid": 1234 } }
```

<a id="understand-the-implementation"></a>
## Understand the implementation

`reverse_process_list` filters by substring on the process name or path; the filter is validated (length and type) before it reaches the socket. `reverse_process_images` needs the caller to have found the pid first — the tool does not guess. Results are rendered as compact tables, and a truncated list says so rather than silently stopping.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- Listing sees processes the resident's identity can see; on iOS some system processes are not enumerable even from SpringBoard.
- Images come from the resident's region walk, so an image mapped but not yet loaded is not distinguishable from one that is.
