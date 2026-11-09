# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-11-09

First release. The patch, both implementations, the Workshop item and the
documentation are all in this release.

### Added

* `tools/xcom2_stackfix.py` — the patch tool (`status` / `apply` / `restore`),
  standard library only. Locates the field by parsing the PE optional header, so
  there is no byte signature to maintain and no address to update when the game
  is patched. Refuses any file that is not a PE32+ image.
* `tools/StackFix.ps1` — the same patch tool in PowerShell, for subscribers who
  arrive through the Steam Workshop and have no Python. Same states, same exit
  codes, same refusal conditions.
* `workshop/item/StackFix.bat` — a double-click launcher. With no argument it
  runs the report and then *offers* the patch, so it is usable without ever
  opening a console; with any argument it passes straight through. Retries
  elevated when Windows denies access to the game folder.
* `tools/pe_util.py` — a dependency-free PE reader, shared with
  [SaveFix](https://github.com/A16Nights/xcom2-savefix).
* `tools/check_vdf.py` — an offline validator for the Workshop build file, so a
  malformed `.vdf` is caught before SteamCMD's parser reports it badly.
* `workshop/make_preview.py` — regenerates `ModPreview.jpg` instead of keeping a
  binary blob of unknown origin in the repository.
* `docs/TECHNICAL.md` — the forensic chain: what the six dumps said, which three
  explanations were tested and rejected, and how the fix was narrowed to one
  header field.
* `docs/PE_STACK.md` — what `SizeOfStackReserve` controls, why 32 MiB is free,
  and the measurement trap that makes a correct patch look like it did nothing.
* `docs/WORKSHOP.md` — why this is a tool rather than a mod, and how it is
  published.
* `README.md` / `README.zh-CN.md` — the same explanation in English and Chinese.

### Fixed

* **`0xC00000FD` (stack overflow) in heavily modded campaigns.** The game copies
  a `TArray` onto the thread stack in a single `sub rsp, rax`, sized
  `Num * 24` bytes. Six crash dumps measured that request at 5.6–10.0 MB
  (peak 10 024 968 bytes) against a 5 000 000-byte reservation. Raising
  `SizeOfStackReserve` to 32 MiB gives 3.3× margin. Verified in game: two full
  playthroughs of the crashing scenario, 105 take-overs of the alien team, zero
  crashes.

### Notes

* **`restore` rewrites only the 8 reserve bytes**, never the whole file, so a
  code patch applied to the same executable — such as SaveFix — survives it.
  Restore refuses to act if `SizeOfStackCommit` no longer matches the backup,
  because that would mean something else modified the header.
* **Threads created with an explicit stack size are unaffected** by this field.
  In the observed process 52 of 146 threads were like that; all 34 threads whose
  start address is inside the game's own image inherited the patched value.
* **`apply` refuses any reserve that is not larger than the largest measured
  request**, because a value below the peak would look like a fix and not be one.

### Known limitations

* A request larger than the configured reserve still crashes. The array is
  data-driven and nothing on this side bounds it.
* The contents of the oversized array were not identified. The element count and
  stride are known exactly; the data is not. It does not affect the fix, since
  the size is what matters.
* The base game executable takes the same patch, but it was only verified in game
  on *War of the Chosen* — that is where the crash reports come from.
