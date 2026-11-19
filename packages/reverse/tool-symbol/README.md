---
description: "reverse_symbols: symbol names and runtime addresses from a loaded image, rebased by the target's own load address."
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-symbol

English | [中文](README.zh.md)

## Summary

`reverse_symbols` answers the question a hook needs: what is this function called inside the running app, and at which address. It takes a pid, an image selector and an optional name filter, and returns each symbol with the runtime address computed from the image's load base in that process. Filtering happens on the device, so a large image does not cross the socket in full.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## Use this package

```json
{ "tool": "reverse_symbols", "arguments": { "pid": 1234, "image": "App", "filter": "isVip", "limit": 50 } }
```

<a id="understand-the-implementation"></a>
## Understand the implementation

The image selector matches on the path's last component or a substring of it, so `App` and `Frameworks/Foo.framework/Foo` both work. Addresses are rebased: file symbol offsets plus the slide the image has in the target. The result says whether the list was truncated.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- Symbols come from the image's file symbol table and export names; a stripped binary (as App Store builds are) yields few of them, and Objective-C method names are not reconstructed from runtime metadata.
- An address is only meaningful while the process is alive and the image unmoved; a relaunch invalidates it.
