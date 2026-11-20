---
description: "Saved reverse-engineering scripts as tools: write a hook or a memory script to disk, list it, read it back, delete it."
kind: "package-reference"
---

# @deepseek-ai/dsh-reverse-scripts

English | [中文](README.zh.md)

## Summary

Four tools that keep what a session produced, so the next session does not have to produce it again: `reverse_script_save`, `reverse_script_list`, `reverse_script_read`, `reverse_script_delete`. A hook written for a target, a list of memory operations to replay, or a note about what an offset turned out to be — each is one file in one directory, not a row in a database, because the next thing that happens to a script is a person opening it in an editor or handing it to Theos.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## Use this package

```json
{ "tool": "reverse_script_save", "arguments": { "name": "vip-check-bypass", "kind": "tweak", "source": "%hook ..." } }
{ "tool": "reverse_script_list", "arguments": { "kind": "tweak" } }
{ "tool": "reverse_script_read", "arguments": { "name": "vip-check-bypass", "kind": "tweak" } }
{ "tool": "reverse_script_delete", "arguments": { "name": "vip-check-bypass", "kind": "tweak" } }
```

Saving a name that already exists replaces the file and answers `replaced: true`; that is how an edited script goes back to disk.

| Kind | Extension | Holds |
|---|---|---|
| `tweak` | `.xm` | Logos source, the starting point for `make package` |
| `memory` | `.json` | A list of memory operations to replay |
| `note` | `.md` | What a symbol, offset or value turned out to mean |

The directory is `<dsh home>/reverse/scripts` unless the row sets `directory`. Each of the four tools can be turned off on its own (`save`, `list`, `read`, `delete`), and `enabled: false` turns off the package.

<a id="understand-the-implementation"></a>
## Understand the implementation

The name is validated before anything touches the disk: letters, digits, dot, dash and underscore, at most 64 characters, and no path separator — so a name from the model can never address a file outside the store. The extension follows from the kind, so a name cannot claim to be a different kind of file than it is. Reads are capped and answer `truncated: true` rather than returning an unbounded file to the model.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- A script is text, not a record: there is no history of previous versions, no author and no timestamp beyond the file's own `mtime` (which `list` reports as `updatedAt`).
- Nothing in this package builds a script. `tweak` scripts are handed to Theos by the operator; the resident does not drive a build.
- The store is per machine and per directory. Two checkouts with different `directory` settings do not see each other's scripts.
