# How the crash was located

This document records the forensic chain behind StackFix: what the dumps said,
what was ruled out, and how the fix was narrowed down to a single header field.
It is written so someone with the same crash can repeat the reasoning.

Addresses are quoted as `XCom2.exe+RVA` — relative to the image base, as a
disassembler shows them. They describe observations on one build of
*War of the Chosen*; the tool never depends on them.

---

## 1. What the dump actually said

`0xC00000FD` is `STATUS_STACK_OVERFLOW`. The minidump's exception stream gave:

| field | value |
|---|---|
| exception code | `0xC00000FD` |
| faulting instruction | `XCom2.exe+0x10a3f18` |
| symbol | `_chkstk` |
| stack region captured | ~12 KB |

`_chkstk` is the compiler's stack-probe helper. On x64 it walks down from the
current stack pointer one page at a time, touching each page so the OS commits
it and the guard page moves. It raises the overflow only when the **reservation
is exhausted** — that is, when the probe reaches below the lowest address the
thread was ever given.

So the exception is not "the stack grew too deep through recursion". It is
"someone asked for more stack than the thread owns, in one step".

The 12 KB captured is the whole point: the frames that led there were never
written, because the probe never got that far.

## 2. The caller

The return address sitting on top of the `_chkstk` frame, in all six battle
dumps, was the same: `XCom2.exe+0xa29901`. Backing up to the function that
contains it (`XCom2.exe+0xa29850 .. +0xa29c0d`, 957 bytes) gave the shape:

```asm
0xa298ec   mov   eax, [rsi+...]        ; Num  (element count)
0xa298f4   lea   rax, [rax+rax*2]      ; Num * 3
0xa298f8   shl   rax, 3                ; * 8   ->  Num * 24 bytes
0xa298fc   call  _chkstk               ; reserve that many bytes
0xa29901   sub   rsp, rax              ; claim them
...
           mov   rcx, rsp              ; the array is then built on the stack
```

`Num * 24` is the signature of copying a `TArray` of 24-byte structures — three
8-byte fields per element, which matches a great many UE3 structs. This is
ordinary C++ doing exactly what it was told; there is no bug to fix *here*.

### What the array is

Not determined, and deliberately not guessed at. The `Num` values recovered were
233 581–417 707, the `Data` pointer referred to heap memory that had already been
freed by the time the dump was taken, and the containing function is reached only
through a vtable (three slots, `#198` / `#201`), with RTTI stripped, and zero
direct `call` sites in the image. It references the wide strings `Core`,
`Engine`, `None`, `<uninitialized>` and `No_Detailed_Info_Specified` — consistent
with walking a name table or an object table, but that is an inference, not a
result.

It does not matter for the fix. What matters is the **size**, and the size is
known exactly.

## 3. The sizes

| dump | `Num` | bytes requested (`Num * 24`) |
|---|---:|---:|
| 1 | 233 581 | 5 605 944 |
| 2 | 291 145 | 6 987 480 |
| 3 | 311 954 | 7 486 896 |
| 4 | 356 730 | 8 561 520 |
| 5 | 395 208 | 9 484 992 |
| 6 | 417 707 | **10 024 968** |

Peak: **10 024 968 bytes = 9.56 MiB**, in a single `sub rsp, rax`.

## 4. Ruling out everything else

Three explanations were tested before the header field was touched. Each is
recorded because each is the obvious next guess.

### "It is infinite recursion; the stack just fills up"

Tested by walking the captured stack for repeated return addresses. The
`.text` pointers in the 12 KB region cluster densely — but every one of them
resolves, through the PE exception directory (`.pdata`, 94 762 entries), to
functions in the error-reporting / logging / stack-walk chain, not to a
self-call. Nothing in the image sits in a recursion cycle there.

Also, and more simply: a recursion overflow **would** have written thousands of
frames. The dump has 12 KB. The stack was never that deep — it was demanded all
at once.

### "A native function is looping and re-entering itself"

Tested by disassembling 18 of the densest stack addresses. All landed outside
`.text` (they were `.pdata`, `_RDATA` and `.rsrc`), which is a reminder that a
stack dump's raw values are **not** all return addresses.

This line of investigation produced nothing, and it was dropped. It is recorded
here so the next person does not repeat it.

### "A script-level mod is looping and re-entering the ruleset"

This was the working theory for a long time, because the crashes clustered
around enemy-turn visualisation and around mods that hand AI teams to the
player. It is not what the dump says: a script loop runs on the **same,
bounded** stack, and re-entering a UnrealScript function costs a few hundred
bytes per frame. Reaching 4.77 MiB that way would take thousands of levels,
which would have been visible in the dump.

Both mechanisms were present in the same sessions, which is why they were
confused for so long. The fix for the loop (a watchdog that clears stuck
visualisation actions and, optionally, ends a stalled turn) is real and was
shipped separately — but it does **not** prevent this crash, and the crash
continued with the watchdog active. They are two different problems with two
different fixes.

## 5. Narrowing to the header field

Once the arithmetic said "one request of ~10 MB", the question became: what
determines the ceiling?

On Windows, the maximum stack a thread can ever use is set when the thread is
created:

* The process default comes from the PE optional header's
  `SizeOfStackReserve`.
* `CreateThread` / `_beginthreadex` may pass their own size explicitly,
  overriding it for that thread only.

`XCom2.exe`'s header had:

```
SizeOfStackReserve  @ optional header +0x48   =  0x004C4B40  =  5 000 000
SizeOfStackCommit   @ optional header +0x50   =  0x004C4B40  =  5 000 000
```

5 000 000 bytes is 4.77 MiB. A 10 MB request cannot fit. The arithmetic closes:
`_chkstk` runs out of reservation, the probe faults, `0xC00000FD`.

### Why the field and not the code

Removing the `sub rsp, rax` pattern, or splitting the array, means patching
game code whose semantics are unknown — the array's element count is not
controlled by anything the tool can see. Raising the reserve changes nothing
about behaviour: the stack still grows page by page, and code that never asked
for 10 MB never notices.

### Choosing 32 MiB

Peak measured request: 9.56 MiB. 32 MiB gives 3.3×. It is also comfortably
above the largest plausible growth of a data-driven array in a campaign that has
not been deliberately pushed to absurd lengths, and it costs nothing: reserve is
address space, and a 64-bit process has 128 TB of it. 145 threads × 32 MiB is
4.6 GB of reservation that is never committed.

## 6. What was verified, and how

**Static.** The field sits at a fixed offset inside the parsed optional header,
so there is nothing to search for and nothing that can match twice. The tool
refuses anything that is not PE32+.

**On disk.** Byte-for-byte diff against the backup: exactly 4 differing bytes —
`0x228: 40 4B 4C 00` → `00 00 00 02`, i.e. the low half of `0x004C4B40`
(`5 000 000`) replaced by `0x02000000` (`33 554 432`). Nothing else in a
32 MB file moved.

**In memory.** With no injector, no debugger and no frida session running, the
PE header was read straight out of the live process:

```
SizeOfStackReserve = 33,554,432
```

That is the loaded image, so the change survives the loader. A patch that only
lives in a debugger would not show up here.

**On the threads.** Reading every thread's real reservation is the part that
needs care:

```
reservation = StackBase - DeallocationStack      (both from the TEB)
```

`DeallocationStack` lives at `TEB + 0x1478` on x64. Of 146 threads, 91 reserved
32 MiB and 52 reserved 5 MiB — the latter being worker threads the engine
creates with an explicit size, which the header cannot influence. Filtering by
`Win32StartAddress` inside the game's own image left **34 threads, all 34 at
32 MiB**: every thread that runs game code inherited the patch.

> **The trap.** `StackBase - StackLimit` reads ~4.77 MiB even on a patched
> process. `StackLimit` is the *currently committed* boundary, not the
> reservation. Reading it makes the patch look like it did nothing. Use
> `StackBase - DeallocationStack`.

**In game.** The decisive evidence is a controlled comparison, not a
measurement: before the patch, 6 of 6 dumps came from taking over the alien team
and advancing the turn. After the patch, two complete playthroughs of that exact
scenario — 105 take-overs of `eTeam_Alien`, 797 `GatherUnitsToMove` calls — with
**zero** crashes and a clean shutdown.

A stack overflow leaves nothing to measure afterwards: the stack is already
gone, and a live process only ever shows you the committed boundary. The
comparison is the strongest evidence available, and it is strong.

## 7. What this does not fix

* **A larger request than the new reserve still crashes.** The array is
  data-driven; nothing bounds it from the tool's side. If a campaign ever needs
  more than 32 MiB, raise the value.
* **Threads with an explicit stack size are unaffected.** If a crash ever lands
  on one of those, this field is not its lever.
* **Nothing about the mod that grew the array changes.** Direct Control forks
  make big enemy turns playable, which is what lets the array get big. That is a
  design consequence, not a defect.

## 8. Reproducing the investigation

Nothing here needs the game running except the in-memory and thread checks.

```console
# what the tool sees, including the raw field values
python tools/xcom2_stackfix.py status

# the disk-level claim: exactly which bytes differ
fc /b "XCom2.exe" "XCom2.exe.stackbak"
```

For the runtime half you need a process handle with
`PROCESS_QUERY_INFORMATION | PROCESS_VM_READ`, then the PE header at the module
base and `NtQueryInformationThread(ThreadBasicInformation)` for each thread's
TEB.
