# XCOM 2 StackFix — Stop the 0xC00000FD Crash

Raise the XCOM 2 thread-stack reserve so heavily modded campaigns stop crashing
with a **stack overflow (`0xC00000FD`)** during tactical battles.

> **Status:** reverse engineered, patched, and confirmed in-game on
> *War of the Chosen* — two full playthroughs of the scenario that used to crash,
> zero crashes. The tool locates the field by parsing the PE header, so it is not
> tied to one game build.

English | [简体中文](README.zh-CN.md)

---

## The problem

In a big modded campaign the game sometimes copies a very large array onto a
thread stack **in one step**. Across the six real crash dumps collected while
making this tool, that single request measured:

| crash dump | requested stack | array elements |
|---|---:|---:|
| smallest | 5.6 MB | 233 581 |
| largest | **10.0 MB** | 417 707 |
| peak measured | **10 024 968 bytes** (9.56 MiB) | — |

`XCom2.exe` ships with a thread-stack reserve of **5 000 000 bytes (~4.77 MiB)**
(`SizeOfStackReserve` in the PE optional header). A request larger than that
walks straight past the guard page, and the process is gone before anything can
catch it:

```
0xC00000FD  STACK_OVERFLOW
  XCom2.exe+0x10a3f18   _chkstk        <- probing past the guard page
  XCom2.exe+0xa29850    caller         <- sub rsp, rax  with rax = elements * 24
```

The array is **data-driven** — the bigger the campaign (more mods, more units,
longer history), the bigger it gets. That is why this crash shows up in
long-running, heavily-modded campaigns, and specifically around enemy-turn
visualisation or whenever a mod hands the AI's teams to the player.

**This is not a mod.** The game never loads it, and it cannot be switched on or
off in the launcher. It is a tool that patches **your own copy** of
`XCom2.exe`, once. No game files are redistributed here.

## The cause

The request is legitimate C++ — a `TArray` copy — and the compiler emits exactly
what it should:

```asm
0xa298fc   call  _chkstk          ; reserve rax bytes of stack
0xa29901   sub   rsp, rax         ; ...and claim them
```

`rax` is the byte size of the array being copied: `Num * 24` (three 8-byte
fields per element). With `Num = 417 707` that is 10 024 968 bytes in a single
instruction. `_chkstk` probes each page on the way down, touches one past the
reserved region, and Windows raises `STATUS_STACK_OVERFLOW`.

Nothing in the scripting layer can prevent it, and no time-based watchdog can
react to it: the stack is already gone in one instruction. The only lever is how
much stack the thread was **given** in the first place — which is one field in
the executable's header.

## The fix

One field in the PE optional header of `XCom2.exe`:

```
SizeOfStackReserve  @ optional header +0x48 (8 bytes, PE32+)
    5,000,000  ->  33,554,432   (32 MiB)
```

That is the only thing the tool writes.

| field | offset | before | after |
|---|---|---:|---:|
| `SizeOfStackReserve` | optional header `+0x48` | 5 000 000 | 33 554 432 |
| `SizeOfStackCommit` | optional header `+0x50` | 5 000 000 | **unchanged** |

`SizeOfStackCommit` — the physical memory handed to every thread immediately —
is never touched. Reserve is **address space only**: a 64-bit process has 128 TB
of it, so 145 threads × 32 MiB ≈ 4.6 GB of reserve costs nothing that matters.
The stack still grows page by page on demand, exactly as before; the ceiling is
simply higher. The observed peak request (9.56 MiB) fits with a **3.3× margin**.

`restore` rolls back **only those 8 bytes**. A code patch applied to the same
executable — such as [SaveFix](https://github.com/A16Nights/xcom2-savefix) — is
never disturbed by it, and neither is the reverse.

## Usage

Two implementations of the same patch. Both read the field from a parsed PE
header, both back up before writing, both verify by reading the file back.

**PowerShell** — no Python needed, works on any current Windows:

```console
powershell -ExecutionPolicy Bypass -File tools\StackFix.ps1 Status
powershell -ExecutionPolicy Bypass -File tools\StackFix.ps1 Apply
```

`workshop/item/StackFix.bat` is a double-click launcher around that script. With
no argument it runs the report and then offers to apply the patch itself, so the
tool is usable without ever opening a console window; with any argument it passes
straight through. It also retries the same operation elevated when Windows denies
access to the game folder.

**Python 3.8+** — standard library only, no `pip install`:

```console
# Get the repository
git clone https://github.com/A16Nights/xcom2-stackfix.git
cd xcom2-stackfix

# 1. See what the tool finds, and whether your game is already patched
python tools/xcom2_stackfix.py status

# 2. Patch (default 32 MiB). Close the game first — it locks the executable.
python tools/xcom2_stackfix.py apply

# 3. Verify
python tools/xcom2_stackfix.py status
```

A backup is written next to the executable as `XCom2.exe.stackbak` before
anything is modified.

```console
# Choose a different reserve (any value from 8 to 1024 MiB)
python tools/xcom2_stackfix.py apply 64

# Undo everything
python tools/xcom2_stackfix.py restore

# Show what would happen without writing
python tools/xcom2_stackfix.py apply 32 --dry-run
```

The tool auto-detects the game through the Steam registry and
`libraryfolders.vdf`, and handles both the base game and *War of the Chosen*.
Point it somewhere explicitly with `--exe PATH` if it guesses wrong.

### Choosing a size

32 MiB is the default because it is 3.3× the largest request ever measured. If
you run an enormous mod list and want more headroom, 64 MiB costs exactly the
same in practice (reserve is address space, not memory). There is no point going
below the peak you need — `apply` refuses any value that is not larger than the
largest measured request.

### Supported executables

| build | optional header | field offset | applied to |
|---|---|---:|---|
| War of the Chosen | `+0x48` | file offset varies by build | ✅ verified in game |
| base game | `+0x48` | file offset varies by build | patch path is identical |

Unlike a byte-signature patch, there is **no site to search for**: the field is
at a fixed position inside the parsed optional header, so the tool works on any
build of either executable without a signature table to maintain. It refuses to
act on anything that is not a 64-bit PE image.

## What you should know before using this

* **Close the game before patching.** Steam holds a lock on the executable.
* **Steam "Verify integrity of game files" and game updates restore the original
  executable.** Re-run `apply` afterwards.
* **Engine-created worker threads are not affected.** Some threads are created
  with an explicit stack size in code rather than inheriting the header value;
  in the observed process there were 52 of them at 5 MiB and 91 inheriting the
  patched 32 MiB. Every crash observed so far ran on a thread that follows the
  header — but this tool cannot promise a fix for a thread it never sees.
* **A stack overflow is fatal by nature.** If a request ever exceeds the new
  reserve, the game still dies. Raise the value if that happens.
* **This is an unsupported modification.** It is not affiliated with, endorsed
  by, or supported by Firaxis Games, 2K, or Take-Two. See
  [`DISCLAIMER.md`](DISCLAIMER.md).

## How it was verified

* **Crash forensic.** Six independent crash dumps, all `0xC00000FD`, all with the
  same return address (`+0xa29901`) and the same `_chkstk` frame — one code path,
  not a scatter of unrelated failures.
* **The number.** Element counts 233 581–417 707 at 24 bytes per element give
  5.6–10.0 MB per request. The peak, 10 024 968 bytes, sets the 32 MiB default.
* **Disk.** A byte-for-byte diff of the patched executable against the backup
  shows exactly 4 differing bytes — the low half of the `0x02000000` immediate
  replacing `0x004C4B40`.
* **Mapped at runtime.** With no injector running, reading the PE header out of
  the live process memory shows `SizeOfStackReserve = 33,554,432`. The change
  comes from the file, not from a debugger.
* **Applied to the right threads.** Reading each thread's real reserve
  (`StackBase − DeallocationStack` from the TEB) showed 91 threads at 32 MiB,
  including **all 34 threads whose start address is inside the game's own image**
  — i.e. every thread that runs game code.
* **In game.** Two full playthroughs of the exact scenario that used to crash:
  105 take-overs of the alien team, zero crashes, clean exit.

> **Trap worth knowing** if you re-verify this yourself: `StackBase − StackLimit`
> reads a constant ~4.77 MiB even on a patched process. `StackLimit` is the
> *currently committed* boundary, not the reservation. The reservation is
> `StackBase − DeallocationStack`, at `TEB + 0x1478`.

## Repository layout

```
tools/xcom2_stackfix.py   the patch tool, Python (status / apply / restore)
tools/pe_util.py          dependency-free PE reader
tools/StackFix.ps1        the same patch tool in PowerShell, no Python needed
tools/check_vdf.py        offline validator for the Workshop build file
workshop/item/            exactly what subscribers receive: manifest, ReadMe,
                          launcher, tool and preview image
workshop/workshop_build.vdf  SteamCMD upload config for that folder
workshop/make_preview.py  regenerates ModPreview.jpg (needs Pillow)
docs/TECHNICAL.md         how the crash was located and the field identified
docs/PE_STACK.md          what SizeOfStackReserve actually does, and what it does not
docs/WORKSHOP.md          why the Workshop item is a tool, and how it is published
README.zh-CN.md           简体中文说明
DISCLAIMER.md             legal notice
```

`workshop/item/` holds the files published to the Steam Workshop as
**[WOTC] StackFix — Stop the 0xC00000FD Crash**:

> https://steamcommunity.com/sharedfiles/filedetails/?id=3836166241

The Workshop item ships the PowerShell tool; subscribers run it against their
own executable, so the item contains no game files at all. There is no second
copy of these files anywhere: the repository folder *is* the upload source, and
`workshop_build.vdf` points at it, so re-running SteamCMD updates the live item
from a fresh clone.

## Related work

* **[SaveFix](https://github.com/A16Nights/xcom2-savefix)** — the same idea
  applied to a different hard-coded limit: the 65 535-character save-header cap.
  The two patches coexist on one executable; each rewrites only its own bytes.
* **Direct Control** forks that hand the AI's teams to the player are where most
  of these dumps came from, because controlling a big enemy turn is what makes
  the array grow. Fixing the stack does not change that mod's behaviour.

## License

[MIT](LICENSE) for the code in this repository. No game code, game binaries, or
game assets are included or redistributed.
