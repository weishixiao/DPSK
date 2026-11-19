---
description: "reverse_macho_analyze: static analysis of one Mach-O file on the device — load commands, sections, dependencies, encryption, symbols and strings."
kind: "package-reference"
---

# @deepseek-ai/dsh-tool-reverse-macho

English | [中文](README.zh.md)

## Summary

`reverse_macho_analyze` reads one binary on the device and reports what a reverse engineer asks for first: architecture, file type, flags, whether it is encrypted (and for which cryptid), its dylibs and rpaths, its sections with sizes, an optional name list from the symbol table, and an optional string sample. It reads the file, not a running process, so it works before the app is launched.

## Table of Contents

- [Use this package](#use-this-package)
- [Understand the implementation](#understand-the-implementation)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)

-----

<a id="use-this-package"></a>
## Use this package

```json
{ "tool": "reverse_macho_analyze", "arguments": { "path": "/var/containers/Bundle/Application/…/App.app/App", "stringsLimit": 100 } }
```

<a id="understand-the-implementation"></a>
## Understand the implementation

The file is read in one pass through the resident: a fat file's arm64 slice is selected, load commands are walked with bounds checks, and symbol and string sections are read only when asked for. Every count the caller names is capped, and the answer says when it stopped early.

<a id="known-limitations-and-deferred-work"></a>
## Known Limitations and Deferred Work

- Only the arm64 slice of a fat file is reported; arm64e differences in a fat file are not listed.
- Chained-fixup binding information is not resolved into names: names come from `LC_SYMTAB` and the string table.
- String extraction is a printable-run scan, not a semantic search for URLs or keys.
