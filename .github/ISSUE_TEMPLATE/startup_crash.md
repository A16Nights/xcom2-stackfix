---
name: Game will not start
about: The game stopped launching after patching, or crashes during loading
title: 'Startup crash: <what you see>'
labels: bug
assignees: ''
---

The patch changes 8 bytes in the PE optional header. Two things about that are
worth ruling out before anything else, because together they explain most
"it just crashes on startup" reports.

## Step 1 — does `Restore` bring it back?

```console
.\StackFix.ps1 Restore
```

- **The game starts again.** StackFix was involved. Paste the `Status` output
  below, with the `-MiB` value you used.
- **It still does not start.** StackFix is not the cause. Restore is safe to have
  run either way: it puts those 8 bytes back and touches nothing else.

## Step 2 — is it the signature or a security policy?

The patched field sits inside the region covered by the executable's Authenticode
signature, so the signature no longer validates. Windows normally starts such an
image anyway, and the game runs no integrity check of its own. On a machine
enforcing Smart App Control, WDAC, or running an antivirus/EDR that treats
modified executables as tampering, it can be blocked.

Quick test — double-click the executable directly rather than going through Steam:

```
...\steamapps\common\XCOM 2\XCom2-WarOfTheChosen\Binaries\Win64\XCom2.exe
```

- **Starts this way** → something in the launch chain (Steam, a launcher, a
  security policy), not the game binary.
- **Still refuses** → note the exact wording of any dialog, and whether the game
  folder is excluded in your antivirus.

## What to paste

1. Full `Launch.log`, as an attachment or a gist, from
   `Documents\My Games\XCOM2 War of the Chosen\XComGame\Logs\`
2. Output of `.\StackFix.ps1 Status`
3. Full path of the executable you patched, and the `-MiB` value used
4. Whether the game worked **before** you ran StackFix
5. Any dialog text, exactly as Windows showed it

**Do not attach the executable itself**, or any game file. See
[`DISCLAIMER.md`](../../DISCLAIMER.md).
