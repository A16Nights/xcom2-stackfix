---
name: Game build report
about: The tool does not recognise your executable
title: 'Unsupported build: <build / version>'
labels: build-support
assignees: ''
---

Unlike a signature-based patch, this tool has no site to search for: the field
sits at a fixed offset inside the parsed PE optional header, so it works on any
build of either executable without a table to maintain. What it can still run
into is a file it will not touch at all.

## What to paste

Run this and paste the whole output:

```console
python tools/xcom2_stackfix.py status
```

## Build details

- Executable size in bytes:
- Base game or War of the Chosen:
- Store (Steam / GOG / Microsoft Store / other):
- Language of the game install:
- Any prior modifications to the executable (SaveFix, other patchers, hex edits):

## The cases the tool refuses

* **Not a PE image** — the file does not start with `MZ` or has no `PE\0\0`
  signature. Usually means the path is wrong, or the file is a launcher stub.
* **Optional header magic is not `0x20B`** — this tool only handles the 64-bit
  build. A 32-bit `XCom2.exe` would have magic `0x10B`, and this field means
  something different there.
* **Access denied** — the game folder is administrator-only, which is the Steam
  default. Run elevated.

If you get one of these on a file you believe is the real game executable, the
output above is enough to investigate. The header values can be checked
directly: `SizeOfStackReserve` is the 8 bytes at optional header `+0x48`, and
`SizeOfStackCommit` at `+0x50`.

**Do not attach the executable itself**, or any game file. See
[`DISCLAIMER.md`](../../DISCLAIMER.md).
