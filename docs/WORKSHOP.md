# Publishing to the Steam Workshop

This document records how the Workshop item **[WOTC] StackFix — Stop the
0xC00000FD Crash** is built and published, and what the constraints are.

The short version: the Workshop is used as a **distribution page for a tool**,
not as a mod. The game never loads the item. It carries no game files.

**Status: published.** The item is live at
<https://steamcommunity.com/sharedfiles/filedetails/?id=3836166241>
(id `3836166241`, private at the time of writing). Uploaded with SteamCMD.

---

## Why the Workshop, and why not as a normal mod

The thing this project fixes lives inside `XCom2.exe`, and it is consumed by the
**Windows loader** before any game code runs:

* `SizeOfStackReserve` is read by the loader when it creates the process. Every
  thread the game creates without an explicit stack size inherits it. By the time
  UnrealScript executes one line, the number is already fixed.
* UnrealScript has no access to the PE header. There is no script function that
  can raise a thread's reservation, and no `Sleep`-based workaround — the stack
  is exhausted inside a single `sub rsp, rax`.
* XCOM 2's UE3 build exposes no `DLLBind` mechanism, so a mod cannot carry a
  native helper either — a full name-table scan for `DLLBind`/`DLLImport` and
  friends returns nothing.

So a Workshop item cannot *fix* the problem by loading mod code. What it *can* do
is deliver the tool and the instructions to players who would never find a GitHub
repository.

This is established practice on this game's Workshop: the item **MemoryAllocation
DLL** (id `3151611447`) does exactly this — it ships an updated `tbbmalloc.dll`
and tells subscribers to copy it into their game folder by hand. Roughly 800
items were scanned while preparing the save-limit sibling of this one; that was
the only item shipping a binary, and it proves the format works.

The same project's earlier item, **[WOTC] Savefix — Beyond 65535**
(id `3818684374`), established the pattern this one follows: a tool, a launcher,
a plain-text script the subscriber can read before running, and no game files.

---

## Layout

```
workshop/item/               what subscribers receive - the upload source
workshop/workshop_build.vdf  SteamCMD config pointing at workshop/item/
workshop/make_preview.py     regenerates item/ModPreview.jpg (needs Pillow)
```

Only `workshop/item/` is uploaded. Everything else sits beside it, so nothing
development-only can leak into the item by being in the same folder. In
particular the `.vdf` must stay **outside** `contentfolder`, or it uploads itself
as content.

## What the item must contain

| File | Required | Purpose |
|---|---|---|
| `StackFix.XComMod` | yes | The manifest. Steam and the launcher read this. |
| `ModPreview.jpg` | yes | Item thumbnail. 1024×1024 is what other items use. |
| `ReadMe.txt` | yes in practice | The full instructions, shown on the item page. |
| `StackFix.bat` | — | Double-click launcher, sets execution policy for one run. |
| `StackFix.ps1` | — | The tool itself. Plain text, readable by subscribers. |
| `LICENSE` | — | MIT, so the terms travel with the download. |

`ModPreview.jpg` is generated from `make_preview.py`, which is committed
alongside it, rather than being a binary blob of unknown origin. Regenerate with:

```console
python workshop/make_preview.py workshop/item/ModPreview.jpg
```

The script needs Pillow, which is why it lives in `workshop/` and not in
`tools/` — everything in `tools/` is standard-library only.

### Manifest format notes

`.XComMod` is an INI file. Two details that are easy to get wrong, both confirmed
against real Workshop items:

* **`Description` uses real newlines**, not `\n` escapes. Writing the
  two-character sequence `\n` produces a page with a visible `\n` in it — nothing
  in this path un-escapes it.
* Steam-native BBCode is supported in the body: `[b]`, `[list]`, `[code]`,
  `[url]`. The item page renders these; `ReadMe.txt` is plain text.

**The same rule applies to the `description` in `workshop_build.vdf`**, and that
one is easy to miss because the `.vdf` *is* a Steam KeyValues file, where escape
sequences look plausible. They are not processed. Both copies of the page text
therefore use real line breaks.

### A quote inside the description closes it early

KeyValues delimit strings with plain `"`, and there is no escape for it inside a
value written by hand. An ASCII double quote anywhere in the description ends the
string there; everything after it is read as key/value pairs, producing an error
that names the wrong thing. The symptom on a real upload was:

    Bad expression token: y at 1 in y/N]
    Assertion Failed: CKeyValuesSystem::AddStringToPool: key name too long (3450 chars)

The second message is the informative one: the remainder of the description was
being parsed as a **key name**. Neither message points at the actual defect,
which is a single character tens of lines earlier.

The fix is to not use a bare `"` in a description at all: write prominent quoted
text in `[i]` BBCode or with full-width quotes. And validate the `.vdf` offline
before uploading, because the authoritative parser only tells you after a failed
attempt:

```console
python tools/check_vdf.py
```

A clean file exits `0`.

### The launcher: two things that break silently

`StackFix.bat` is the file subscribers actually double-click, and it has two
failure modes worth recording, because both produce errors that point at the
wrong file:

* **The script path must be quoted.** `cmd.exe` parses the line before it runs
  anything, so an unquoted `%HERE%StackFix.ps1` inside the default Steam location
  (`C:\Program Files (x86)\...`) has its `)` read as the end of a block. The error
  is `\StackFix.ps1 was unexpected at this time.`
* **The file must be CRLF.** `cmd.exe` reads a batch file as a stream and
  resolves `goto :label` by byte offset. With LF-only endings the jump lands in
  the wrong place and fails with `The system cannot find the batch label
  specified`. Hence the `*.bat text eol=crlf` rule in `.gitattributes`. Do not
  remove it.

### The launcher: the failure that is not a crash

A report that says "this executable can be patched" and then withholds the means
to patch it is useless to someone who arrived by double-clicking: they have no
console to type into, and double-clicking the `.ps1` opens Notepad.

The fix turns the dead end into a question. With **no argument at all**,
`StackFix.bat` runs the report and then asks:

```
  Raise the reserve to 32 MiB now? [y/N]
```

Answering `y` re-invokes the script with `Apply -Yes`, so the confirmation the
user just gave is not asked for twice. **Passing any argument skips the question
entirely**, so every documented command and every scripted caller behaves exactly
as before. That test is a label jump (`goto`), not an `if (...)` block, for the
parenthesis reason above.

The report needs a way to say "I ran fine, and there is something to do" without
calling it an error, so it exits **10** for that case; a status run against an
already-patched executable exits 0. The launcher maps 10 to its offer branch and
everything else to its report branch.

Elevation has three separate entry points rather than one shared label, so that
an elevated retry re-runs *the same thing the user asked for* and nothing more.

### Exit codes

| code | meaning |
|---:|---|
| 0 | ran fine, nothing to do (already patched, or change applied successfully) |
| 1 | could not proceed (no executable found, read/write failure) |
| 2 | refused (bad value, backup does not belong to this file, commit mismatch) |
| 10 | ran fine, and this executable **can** be patched |

---

## Publishing

### Normal route: ModBuddy

The supported way is Firaxis' own tool, which ships with the **XCOM 2
Development Tools** — a separate Steam app, **id 299990**, not part of the game
install. For an item like this one — no `Src/`, no `Script/`, no cooked content —
ModBuddy is heavyweight: the upload dialog only needs a folder and a manifest.

### Scriptable route: steamcmd

`workshop_build.vdf` in this folder is ready for Valve's `steamcmd`:

```console
steamcmd +login <account> +workshop_build_item <path to workshop_build.vdf> +quit
```

* `publishedfileid 0` creates a new item; paste the assigned ID in for later
  updates. The file in this repository already carries the real ID.
* `steamcmd` replaces the item's file set with the contents of `contentfolder`,
  so keep that folder exactly as it should appear to subscribers.
* The paths in the `.vdf` are absolute. SteamCMD does not resolve them relative
  to the config file.
* Logging in needs the account password **and** a Steam Guard code. Once it has
  succeeded, credentials are cached and later runs need nothing.

### What SteamCMD does and does not do

`steamcmd` **does** upload `title`, `description`, `changenote`, `visibility` and
the preview image straight from the `.vdf`. What it does *not* do is interpret
anything inside those values: whatever is between the quotes is what lands on the
page.

"Arrived" and "arrived correctly" are different claims, and only the second one
is worth making. Verify by fetching the description back and counting: no literal
`\n`, a plausible number of real line breaks, and the expected text present.
Reading the page by eye is what let a page full of literal `\n` pass as correct
on a sibling project's first publish.

One consequence worth knowing: `steamcmd` **rewrites the `.vdf` it was given**,
reordering keys and filling in the assigned item id. That is normal.

---

## Checklist before publishing

- [ ] `StackFix.XComMod` — title, description, tags present; real newlines.
- [ ] `workshop_build.vdf` — `description` uses real newlines too; keys intact.
- [ ] `python tools/check_vdf.py` — exits `0`.
- [ ] `ModPreview.jpg` — regenerated, 1024×1024, shows the actual fix.
- [ ] `StackFix.ps1` — syntax-checks clean, and `Status` / `Apply` / `Restore`
      all behave on a **copy** of the executable.
- [ ] `StackFix.bat` — **CRLF line endings, and its own path quoted.** Run it
      from a folder whose name contains a space *and* a parenthesis.
- [ ] `LICENSE` — present, with the copyright line filled in.
- [ ] No game files in the folder: no `.exe`, `.dll`, `.upk`, `.bin`.
- [ ] No BOM on any text file.
- [ ] The page copy does not claim the item is a mod, and does not claim mods can
      fix this. It is a tool, and it changes eight bytes.
- [ ] **After publishing**: fetch the description back and check it — literal
      `\n` count is 0 and the expected text is present. Do not eyeball the page.

---

## After publishing

* The item page is the support surface. Point bug reports at
  `https://github.com/A16Nights/xcom2-stackfix/issues`.
* If the game updates, the tool still works — the field is found by parsing the
  PE header, not by a signature or a hard-coded offset. That is a deliberate
  difference from the save-limit tool, which has a signature to re-verify.
* Steam "Verify integrity of game files" and game updates both revert the patch.
  Re-running the tool is the fix; that is worth saying on the page, and it is.
