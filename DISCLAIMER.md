# Legal notice

## No game files are distributed here

This repository contains **only original source code** written for this project
(a Python tool and a PowerShell tool that inspect and modify a Portable
Executable file that the user already owns).

It does **not** contain, and must not be used to distribute:

* XCOM 2 executables (patched or unpatched)
* game archives (`.upk`, `.umap`, `.tfc`, or any other cooked content)
* game assets, textures, sounds, models, localisation text, or scripts
* decrypted or decompiled game data in any form
* save files belonging to anyone

The tool is the deliverable. It operates on files that are already on the user's
own machine.

## Not affiliated

This is an unofficial, fan-made utility. It is not affiliated with, authorised
by, endorsed by, or supported by **Firaxis Games**, **2K Games**, or **Take-Two
Interactive Software, Inc.** *XCOM* and *XCOM 2* are trademarks of their
respective owners. Those names are used here only to describe what the tool is
compatible with.

## What the tool does

It modifies **eight bytes** in the PE optional header of the user's local copy of
`XCom2.exe` — the `SizeOfStackReserve` field, raising the thread-stack reservation
from 5 000 000 bytes to 33 554 432 bytes (32 MiB). `SizeOfStackCommit` is never
written. Nothing else in the executable is touched.

This is a modification of software you own, performed on your own machine, for
your own single-player use. Whether that is permissible in your jurisdiction is
your call to make — this notice is a statement of what the tool does, not legal
advice.

## Consequences you accept by using it

* **Steam "Verify integrity of game files" and any game update will overwrite the
  patched executable.** Re-run the tool afterwards.
* **Do not use a patched executable in competitive, ranked, or shared-save
  contexts** (multiplayer, Challenge Mode ladders, anything where another player
  or a leaderboard is involved). A modified executable changes assumptions the
  other side did not agree to.
* **The fix is a ceiling, not a guarantee.** If a stack request ever exceeds the
  new reservation, the game still crashes with `0xC00000FD`. Raise the value if
  that happens.
* **Back up anything you care about.** The tool never touches save files, but
  backups are cheap.
* **No warranty.** The software is provided "as is", without warranty of any kind.
  See [`LICENSE`](LICENSE). A copy of the original executable is created
  automatically before any write, and `restore` reverses the change.

## Reverse engineering

The analysis behind this project was performed on a legally purchased, locally
installed copy of the game, for the purpose of interoperability and personal use.
Addresses, disassembly excerpts and measurements in [`docs/`](docs) are
**descriptions of observations**, published to make the tool's behaviour
auditable — they are not and cannot be used as a substitute for the game.

## Reporting

If you are a rights holder and object to anything in this repository, please open
an issue and it will be removed promptly.
