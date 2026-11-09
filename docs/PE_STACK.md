# `SizeOfStackReserve`: what it does, and what it does not

The whole patch is one field. This document explains what that field controls,
why raising it is safe, and where its limits are — so you can judge the tool
rather than take it on faith.

---

## The thread stack on Windows x64, in one page

Every Windows thread gets a **stack reservation** when it is created:

| region | what it is | cost |
|---|---|---|
| **reserve** | address space set aside, not committed | virtual only |
| **commit** | physical memory actually backed by the page file | real |
| **guard page** | one page at the growing edge, armed to commit more | one page |

The stack starts small (a few pages of commit) and **grows downward on demand**.
When code touches the guard page, the OS commits another page and moves the guard
one page further down. This repeats until the committed region would exceed the
reservation — at that point the OS raises `STATUS_STACK_OVERFLOW`
(`0xC00000FD`) and, unless something handles it, the process dies.

The reservation is therefore a **ceiling**, not an allocation. Raising it does
not reserve physical memory, does not slow anything down, and does not change how
the stack grows. It only moves the line at which the process dies.

### Where the number comes from

The process default is in the PE optional header:

| field | PE32+ offset | meaning |
|---|---:|---|
| `SizeOfStackReserve` | `+0x48` | ceiling for threads that do not ask for their own |
| `SizeOfStackCommit` | `+0x50` | how much is committed up front |

`XCom2.exe` uses **5 000 000 bytes (4.77 MiB)** for both.

Threads created with an explicit size — `CreateThread(..., dwStackSize, ...)` or
`_beginthreadex` with a non-zero stack size — **ignore the header** and use what
the caller asked for. In the observed process, 52 of 146 threads were like that
(all at 5 MiB, created by the engine's job system). The other 91 inherited the
header value, and every thread whose start address is inside the game's own
image (34 of them) was in that group.

### Committed vs reserved, and the measurement trap

There are two different "current size" numbers, and confusing them makes the
patch look broken:

```
StackBase - StackLimit           ->  currently committed   (~4.77 MiB, barely moves)
StackBase - DeallocationStack    ->  the reservation       (what the patch changed)
```

Both come from the TEB. `DeallocationStack` is at `TEB + 0x1478` on x64.
`StackLimit` looks like "how big is the stack" and is not: it is the committed
edge, which on a game that has never needed more than 4 MB sits at ~4.77 MiB
whether the reservation is 5 MB or 32 MB.

A single deep `sub rsp, rax` does move the committed edge down — the guard page
commits through it — but the OS does not hand those pages back immediately, so a
reading taken later shows a high-water mark rather than the reservation. Use
`DeallocationStack` when you want to know what the patch did.

---

## Is 32 MiB safe?

**Address space.** A 64-bit process has 128 TB of user address space. 145 threads
× 32 MiB = 4.6 GB of *reservation* — no pages, no page-file cost, no commit
charge. Even a 32-bit process would usually be fine, and this is not one.

**Memory.** `SizeOfStackCommit` is untouched, so the amount of physical memory
committed at thread creation does not change at all. Memory is consumed only if
the stack actually grows, which is the same behaviour as before.

**Fragmentation.** A 32 MiB reservation is 8 192 pages. The loader allocates it
as one region; there is no per-page cost until a page is touched. This is why the
number can be generous without consequence.

**Behaviour.** No instruction, no data structure, no API contract changes. Code
that never asks for more than 4 MB behaves identically. Code that asks for 10 MB
now succeeds instead of dying.

## What it does not fix

* **A request larger than the new reserve still crashes.** The array that caused
  this is data-driven; the tool cannot bound it. If it ever needs more than
  32 MiB, raise the value (`apply 64`, and so on up to 1024).
* **Explicit-stack threads are unaffected.** If a future crash lands on one of
  the engine's 5 MiB workers, this field is not the lever — that path would need
  a code-level change, which this project deliberately does not do.
* **Genuine deep recursion is still deep recursion.** This raises a ceiling; it
  does not make unbounded recursion finite.
* **It has nothing to do with save files, mod load order, or mod count.** Those
  are separate problems with separate fixes.

## Why the header and not the code

The alternative was to stop the array from being that big: patch the `sub rsp,
rax` site, or the allocation feeding it. Rejected, for reasons that still hold:

* The function is reached only through a vtable (three slots), RTTI is stripped,
  and there are **zero direct call sites** — there is no clean place to
  intercept it from a patch.
* Its semantics are unknown. `Num` is not something the tool can influence, and
  changing an array copy's behaviour means changing what the game computes.
* The array's element count grows with campaign size. Any hard limit would turn a
  crash into a different crash.

Raising a documented header field changes nothing the game can observe until the
moment it would otherwise have died.

## Why not ship this as a mod

Because it is not one. The value is consumed by the **Windows loader** when it
creates the process, before any game or mod code runs. A `.u` package cannot
reach it: UnrealScript has no access to the PE header, XCOM 2's UE3 build exposes
no `DLLBind`, and even a code hook would run too late — the reservation is fixed
at thread creation.

That is also why the Workshop item is published as a **tool** rather than a mod.
See [`WORKSHOP.md`](WORKSHOP.md).

## Checking it yourself

```console
# the field, the state, and the margin
python tools/xcom2_stackfix.py status

# which bytes differ from the backup
fc /b "XCom2.exe" "XCom2.exe.stackbak"
```

Reading the live reservation needs `PROCESS_QUERY_INFORMATION | PROCESS_VM_READ`
on the process and `NtQueryInformationThread(ThreadBasicInformation)` per thread;
note that opening individual threads with `THREAD_QUERY_INFORMATION` fails on a
game process with default privileges, which is why the usual approach is to hold
the process handle and query from there.
