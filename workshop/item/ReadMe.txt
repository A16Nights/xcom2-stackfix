StackFix - Stop the 0xC00000FD crash
====================================

Raises the XCOM 2 thread-stack reserve so heavily modded campaigns stop
crashing with a stack overflow (0xC00000FD) during tactical battles.

WHY
---
In a big modded campaign, XCom2.exe sometimes copies a very large array
onto the thread stack in one go. Across six real crash dumps that single
request measured 5.6 - 10.0 MB (peak 10,024,968 bytes). The default
thread stack is only 5,000,000 bytes (~4.77 MiB), so the request walks
past the guard page and the game dies instantly with:

    0xC00000FD  STACK_OVERFLOW   (XCom2.exe+0x10a3f18, _chkstk)

The array is data-driven - the bigger the campaign (more mods, more
units, longer history), the bigger it gets. That is why the crash shows
up in long-running, heavily-modded campaigns, often around enemy-turn
visualisation or when a mod lets you control the alien team.

This is NOT a mod in the usual sense. The game never loads it and it
cannot be turned on or off in the launcher. It is a tool that patches
YOUR OWN copy of XCom2.exe, once. No game files are redistributed here.


WHAT IT ACTUALLY CHANGES
-----------------------
One field in the PE optional header of XCom2.exe:

    SizeOfStackReserve  @ optional header +0x48 (8 bytes, PE32+)
        5,000,000  ->  33,554,432   (32 MiB)

That is the only thing the tool writes. SizeOfStackCommit - the physical
memory handed to every thread immediately - is never touched. Reserve is
address space only: a 64-bit process has 128 TB of it, so 145 threads
x 32 MiB = 4.6 GB reserved costs nothing. The stack still grows page by
page on demand, exactly as before; the ceiling is just higher.

The observed peak request (9.56 MiB) fits with a 3.3x margin.

Restore rolls back ONLY those 8 bytes. A code patch applied to the same
executable - such as SaveFix - is never disturbed by it.


QUICK START
-----------
1. Close XCOM 2. (It locks the executable while the game is running.)
2. Open this folder (where Steam downloaded this item).
3. Double-click  StackFix.bat
      -> read-only report. It tells you whether your executable is
         original or already patched, and what the current reserve is.
4. If it says ORIGINAL it then asks:
          Raise the reserve to 32 MiB now? [y/N]
   Type  y  and press Enter. Eight bytes of XCom2.exe change.
5. Start the game and play the battle that used to crash.

Steps 3 and 4 are one double-click and one keystroke. You do not need a
command prompt. If you want a different size, or to script the tool, use
the commands below instead - passing any argument skips the question.


COMMANDS
--------
    StackFix.bat                     report, then offer to patch (double-click this)
    StackFix.bat Apply                raise the reserve to 32 MiB (default)
    StackFix.bat Apply -MiB 64       raise it to 64 MiB instead
    StackFix.bat Restore             put the original value back

Options:

    -Exe "<path>"    use a specific XCom2.exe (auto-detected otherwise)
    -Yes             skip the confirmation prompt


UNDOING IT
----------
    StackFix.bat Restore

A copy of your original executable is written to XCom2.exe.stackbak next
to the game's executable before the first change. Restore reads the
original reserve value out of that backup and rewrites only those 8
bytes - it never copies the whole file back, so any other patch you
applied to the executable survives. "Verify integrity of game files" in
Steam also restores a clean executable.


REQUIREMENTS AND CAVEATS
------------------------
- Windows, with PowerShell 5.1 (present on any current Windows).
- Works on both the base game and War of the Chosen - the field is found
  by parsing the PE header, never by a hard-coded file offset.
- If your game is under "C:\Program Files (x86)" - the Steam default -
  the folder is usually administrator-only, so the tool cannot read or
  write XCom2.exe. It will say so and offer to retry elevated; say yes,
  or right-click StackFix.bat and choose "Run as administrator".
- Modifies a game executable. That is your decision to make; it is why
  this is a manual install rather than an ordinary mod.
- Antivirus software may flag any tool that writes to an .exe. The
  script is plain text - open StackFix.ps1 in Notepad and read it
  before running it.
- Engine-created worker threads that ask for their own explicit stack
  size are not affected by this field; every crash observed so far ran
  on a thread that follows the PE header value.
- A game update replaces the executable and the patch is gone. Run the
  tool again - it is not cumulative or destructive.


TECHNICAL SUMMARY
-----------------
- Crash: 0xC00000FD at XCom2.exe+0x10a3f18 (_chkstk probing past the
  guard page). The caller at +0xa29850 performs "sub rsp, rax" with
  rax = Num * 24 for a TArray of 233,581 - 417,707 elements.
- Fix: SizeOfStackReserve 5,000,000 -> 33,554,432 (32 MiB), leaving a
  3.3x margin over the largest observed request.
- Verified: patched value loaded by the OS (live PE header), 91/146
  threads reserving 32 MiB, all 34 game-code threads covered, and two
  full playthroughs of the crashing scenario with zero crashes.


LICENSE
-------
MIT. See the LICENSE file in this folder. XCOM 2 is a trademark of
Take-Two Interactive; this project is unaffiliated with and not endorsed
by Firaxis Games or 2K Games.
