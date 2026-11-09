---
name: Bug report
about: The tool did something unexpected
title: ''
labels: bug
assignees: ''
---

## What happened

<!-- What you ran, and what came back. Paste the full output. -->

```console
$ python tools/xcom2_stackfix.py status
```

## What you expected

## Which build

<!-- The `status` output shows this. Base game, or War of the Chosen? -->

- Game build:
- Executable size in bytes:
- Tool version / commit:

## Environment

- OS:
- Python version (`python --version`), or "PowerShell only":
- Was the game running when you patched?

## Did `status` find the executable and read the field?

<!-- If it reported "No XCOM 2 executable found" or refused the file as not
     PE32+, that is the most useful thing in the report. Paste it verbatim. -->

## If the game still crashes

<!-- A stack overflow leaves a minidump behind. The faulting address matters:
     if it is XCom2.exe+0x10a3f18 (_chkstk), this patch is the right lever and
     the value may simply need to be larger. If it is somewhere else, it is a
     different crash. -->
