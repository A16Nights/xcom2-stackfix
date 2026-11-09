# -*- coding: utf-8 -*-
"""XCOM 2 / War of the Chosen thread-stack reserve raiser.

Background
----------
A heavily modded campaign can make the game copy a very large array onto a
thread stack in a single step.  Across six real crash dumps that single request
measured 5.6 - 10.0 MB (peak 10,024,968 bytes).  ``XCom2.exe`` ships with a
thread-stack reserve of 5,000,000 bytes (~4.77 MiB), so the request walks past
the guard page and the process dies instantly::

    0xC00000FD  STACK_OVERFLOW   (XCom2.exe+0x10a3f18, _chkstk)

The array is data-driven: the bigger the campaign, the bigger it gets.  That is
why the crash appears in long-running, heavily-modded campaigns and not in a
clean one.

The fix is a single field in the PE optional header::

    SizeOfStackReserve   @ optional header +0x48   (QWORD, PE32+)
        5,000,000  ->  33,554,432   (32 MiB)

``SizeOfStackCommit`` (``+0x50``) is never touched.  Reserve is address space
only, and the stack still grows page by page on demand -- the ceiling is simply
higher.  A 64-bit process has 128 TB of address space, so 145 threads at 32 MiB
each costs nothing that matters.

This tool locates the field by parsing the PE header, never by a hard-coded file
offset, so it keeps working across game builds.  It supports both ``XCom2.exe``
(base game) and ``XCom2-WarOfTheChosen\\Binaries\\Win64\\XCom2.exe``.

Usage
-----
    python xcom2_stackfix.py status           # inspect: show reserve and state
    python xcom2_stackfix.py apply [MiB]      # patch (default 32 MiB), with backup
    python xcom2_stackfix.py restore          # restore from backup

Common options:
    --exe PATH      operate on a specific executable
    --all           operate on every XCOM 2 executable found
    --dry-run       do not write anything (apply/restore)
    --yes           do not ask for confirmation

Only eight bytes of the optional header are written, so a code patch applied to
the same executable -- such as SaveFix -- is not disturbed.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pe_util import PE, PEError  # noqa: E402

# ---------------------------------------------------------------- constants

WOTC_REL = os.path.join('XCom2-WarOfTheChosen', 'Binaries', 'Win64', 'XCom2.exe')
BASE_REL = os.path.join('Binaries', 'Win64', 'XCom2.exe')

BACKUP_EXT = '.stackbak'

# Optional-header field offsets, from the start of the optional header.
RESERVE_OFF = 0x48      # SizeOfStackReserve, QWORD in PE32+
COMMIT_OFF = 0x50       # SizeOfStackCommit -- read for verification, never written

VANILLA_RESERVE = 5_000_000
DEFAULT_MIB = 32

# Largest single stack request observed across the six crash dumps, in bytes.
PEAK_OBSERVED = 10_024_968

MIN_MIB = 8
MAX_MIB = 1024

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_REFUSED = 2
EXIT_NEEDS_ACTION = 10   # status found a patchable executable


# ------------------------------------------------------------ game location

def _steam_roots() -> list[str]:
    """Locate Steam installation roots from the registry."""
    roots: list[str] = []
    if os.name != 'nt':
        return roots
    try:
        import winreg
    except ImportError:
        return roots
    for hive, key, name in (
        (winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam', 'SteamPath'),
        (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'),
        (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\Valve\Steam', 'InstallPath'),
    ):
        try:
            with winreg.OpenKey(hive, key) as k:
                val, _ = winreg.QueryValueEx(k, name)
        except OSError:
            continue
        if val and os.path.isdir(val) and val not in roots:
            roots.append(val)
    return roots


def _library_folders(steam_root: str) -> list[str]:
    """Read libraryfolders.vdf to enumerate every Steam library on the system."""
    out = [steam_root]
    vdf = os.path.join(steam_root, 'steamapps', 'libraryfolders.vdf')
    if not os.path.isfile(vdf):
        return out
    try:
        with open(vdf, 'r', encoding='utf-8', errors='replace') as f:
            text = f.read()
    except OSError:
        return out
    import re
    for m in re.finditer(r'"path"\s*"([^"]+)"', text):
        p = m.group(1).replace('\\\\', '\\')
        if os.path.isdir(p) and p not in out:
            out.append(p)
    return out


def candidate_exes(explicit: str | None = None) -> list[str]:
    """Every plausible XCOM 2 executable, deduplicated, existing only.

    The same install is reachable through several routes (Steam registry key,
    libraryfolders.vdf, conventional paths), and Windows paths differ only by
    case, so dedupe on the normalised real path rather than the string.
    """
    if explicit:
        return [explicit] if os.path.isfile(explicit) else []

    found: list[str] = []
    seen: set[str] = set()

    def add(p: str) -> None:
        p = os.path.normpath(p)
        try:
            key = os.path.normcase(os.path.realpath(p))
        except OSError:
            key = os.path.normcase(p)
        if key in seen or not os.path.isfile(p):
            return
        seen.add(key)
        found.append(p)

    for root in _steam_roots():
        for lib in _library_folders(root):
            common = os.path.join(lib, 'steamapps', 'common', 'XCOM 2')
            for rel in (WOTC_REL, BASE_REL):
                add(os.path.join(common, rel))

    # Fall back to a few conventional install paths.
    for drive in ('C:', 'D:', 'E:', 'F:', 'G:'):
        for base in (r'Program Files (x86)\Steam', r'Program Files\Steam',
                     r'Steam', r'Games\Steam', r'SteamLibrary'):
            common = os.path.join(drive + os.sep, base, 'steamapps', 'common', 'XCOM 2')
            for rel in (WOTC_REL, BASE_REL):
                add(os.path.join(common, rel))
    return found


# ------------------------------------------------------------ header access

class StackFields:
    """The two thread-stack fields of one optional header, plus where they are."""

    def __init__(self, data: bytes, path: str):
        self.path = path
        self.data = data
        self.pe = PE(data, path)

        if self.pe.magic != 0x20B:
            raise PEError(
                '%s: optional header magic is 0x%X, not PE32+ (0x20B). '
                'This tool only handles the 64-bit build of XCOM 2.'
                % (path, self.pe.magic))

        e_lfanew = struct.unpack_from('<I', data, 0x3C)[0]
        self.opt_off = e_lfanew + 4 + 20
        self.reserve_off = self.opt_off + RESERVE_OFF
        self.commit_off = self.opt_off + COMMIT_OFF

        if self.commit_off + 8 > len(data):
            raise PEError('%s: optional header is truncated' % path)

        self.reserve = struct.unpack_from('<Q', data, self.reserve_off)[0]
        self.commit = struct.unpack_from('<Q', data, self.commit_off)[0]

    @property
    def state(self) -> str:
        return 'vanilla' if self.reserve == VANILLA_RESERVE else 'patched'

    def backup_path(self) -> str:
        return self.path + BACKUP_EXT


def read_fields(path: str) -> StackFields:
    with open(path, 'rb') as f:
        return StackFields(f.read(), path)


def looks_like_wotc(path: str) -> bool:
    """War of the Chosen installs live one directory deeper than the base game."""
    return 'WarOfTheChosen' in path or 'War of the Chosen' in path


def detect_build(path: str) -> str:
    return 'War of the Chosen' if looks_like_wotc(path) else 'base game'


def human(n: int) -> str:
    """Byte count the way the reports show it: exact plus a readable size."""
    if n >= 1024 * 1024:
        return '%s bytes (%.2f MiB)' % (f'{n:,}', n / (1024 * 1024))
    if n >= 1024:
        return '%s bytes (%.1f KiB)' % (f'{n:,}', n / 1024)
    return '%s bytes' % f'{n:,}'


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


# ------------------------------------------------------------------ helpers

def _confirm(question: str, assume_yes: bool) -> bool:
    if assume_yes:
        return True
    try:
        answer = input('%s [y/N] ' % question).strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    return answer in ('y', 'yes')


def _is_access_denied(exc: BaseException) -> bool:
    seen = 0
    e: BaseException | None = exc
    while e is not None and seen < 8:
        if isinstance(e, (PermissionError, OSError)) and getattr(e, 'errno', None) in (13, 5):
            return True
        if isinstance(e, PermissionError):
            return True
        e = getattr(e, '__cause__', None) or getattr(e, '__context__', None)
        seen += 1
    return False


def _print_admin_hint() -> None:
    print()
    print('  Windows denied access to the game folder. Steam installs under')
    print('  "C:\\Program Files (x86)" by default, which is administrator-only.')
    print()
    print('  Fix: run the tool from an elevated prompt, or right-click the')
    print('  .bat launcher and choose "Run as administrator".')


def _write_reserve(path: str, value: int) -> None:
    """Write exactly the 8 reserve bytes, in place, and flush to disk."""
    with open(path, 'r+b') as f:
        f.seek(0)
        data = f.read()
        fields = StackFields(data, path)
        f.seek(fields.reserve_off)
        f.write(struct.pack('<Q', value))
        f.flush()
        os.fsync(f.fileno())


# ------------------------------------------------------------------- status

def cmd_status(args) -> int:
    targets = candidate_exes(args.exe)
    if not targets:
        print('No XCOM 2 executable found.')
        print()
        print('  Looked through the Steam registry and libraryfolders.vdf, then')
        print('  through the usual install paths. Point the tool at the file with')
        print('  --exe "<path to XCom2.exe>" if your install is somewhere else.')
        return EXIT_FAIL

    print()
    print('XCOM 2 StackFix - status')
    print('-' * 24)
    print('  found %d executable(s)' % len(targets))

    patchable = 0
    for path in targets:
        print()
        print('  ' + path)
        try:
            fields = read_fields(path)
        except (PEError, OSError) as exc:
            print('    unreadable: %s' % exc)
            continue

        print('    build      %s' % detect_build(path))
        print('    size       %s bytes' % f'{os.path.getsize(path):,}')
        print('    sha256     %s' % sha256_of(path))
        print('    reserve    0x%08X  %s' % (fields.reserve, human(fields.reserve)))
        print('    commit     0x%08X  %s  (never written)'
              % (fields.commit, human(fields.commit)))
        print('    peak seen  %s' % human(PEAK_OBSERVED))

        backup = fields.backup_path()
        if os.path.isfile(backup):
            print('    backup     %s' % backup)
        else:
            print('    backup     none yet (apply creates one automatically)')

        if fields.state == 'vanilla':
            patchable += 1
            print('    state      ORIGINAL - reserve is 5,000,000 (~4.77 MiB)')
            if PEAK_OBSERVED > fields.reserve:
                print('    risk       a 10 MB stack request would overflow this')
        else:
            print('    state      PATCHED - reserve is %s' % human(fields.reserve))
            if fields.reserve > PEAK_OBSERVED:
                print('    margin     %.1fx above the largest observed request'
                      % (fields.reserve / PEAK_OBSERVED))
            elif fields.reserve > 0:
                print('    margin     BELOW the largest observed request - '
                      'this may still crash')

    print()
    if patchable:
        print('  %d executable(s) can be patched - run "apply" to do it.' % patchable)
        return EXIT_NEEDS_ACTION
    print('  Nothing to do - every executable found is already patched.')
    return EXIT_OK


# -------------------------------------------------------------------- apply

def cmd_apply(args) -> int:
    mib = args.mib
    if not (MIN_MIB <= mib <= MAX_MIB):
        print('Refusing: %d MiB is outside the supported range (%d-%d).'
              % (mib, MIN_MIB, MAX_MIB))
        return EXIT_REFUSED

    new_reserve = mib * 1024 * 1024
    if new_reserve <= PEAK_OBSERVED:
        print('Refusing: %d MiB is not larger than the largest observed request '
              '(%s).' % (mib, human(PEAK_OBSERVED)))
        return EXIT_REFUSED

    targets = candidate_exes(args.exe)
    if not targets:
        print('No XCOM 2 executable found. Use --exe "<path>" to point at one.')
        return EXIT_FAIL

    acted = 0
    failed = 0
    for path in targets:
        print()
        print('XCOM 2 StackFix - apply (%d MiB)' % mib)
        print('-' * 30)
        print('  executable %s' % path)

        try:
            fields = read_fields(path)
        except (PEError, OSError) as exc:
            print('  unreadable: %s' % exc)
            failed += 1
            continue

        print('  build      %s' % detect_build(path))
        print('  reserve    0x%08X  %s' % (fields.reserve, human(fields.reserve)))
        print('  commit     0x%08X  %s  (never written)'
              % (fields.commit, human(fields.commit)))

        if fields.reserve == new_reserve:
            print('  state      already at %d MiB - nothing to do' % mib)
            continue

        backup = fields.backup_path()
        make_backup = not os.path.isfile(backup)
        if not make_backup:
            print('  backup     %s  (already exists, kept)' % backup)

        print()
        print('  About to change SizeOfStackReserve: %s  ->  %s'
              % (human(fields.reserve), human(new_reserve)))
        print('  SizeOfStackCommit will not be touched.')

        if args.dry_run:
            print()
            print('  --dry-run: nothing was written.')
            acted += 1
            continue

        if not _confirm('  Apply this change?', args.yes):
            print('  Cancelled.')
            continue

        try:
            if make_backup:
                with open(path, 'rb') as src, open(backup, 'wb') as dst:
                    for chunk in iter(lambda: src.read(1 << 20), b''):
                        dst.write(chunk)
                print('  backup     wrote %s' % backup)

            _write_reserve(path, new_reserve)

            # Read the file back: a patch the game will not load is not a patch.
            after = read_fields(path)
            if after.reserve != new_reserve:
                print('  FAILED     read-back shows 0x%08X, expected 0x%08X'
                      % (after.reserve, new_reserve))
                failed += 1
                continue
            if after.commit != fields.commit:
                print('  WARNING    SizeOfStackCommit changed unexpectedly '
                      '(0x%08X -> 0x%08X)' % (fields.commit, after.commit))

            print('  written    reserve is now 0x%08X  %s'
                  % (after.reserve, human(after.reserve)))
            print('  verify     read back from the file, matches')
            acted += 1

        except (OSError, PEError) as exc:
            if _is_access_denied(exc):
                _print_admin_hint()
            else:
                print('  FAILED     %s' % exc)
            failed += 1

    print()
    if failed:
        print('  %d changed, %d failed.' % (acted, failed))
        return EXIT_FAIL
    if not acted:
        print('  Nothing changed.')
        return EXIT_OK
    print('  Done. Start the game and play the battle that used to crash.')
    return EXIT_OK


# ------------------------------------------------------------------ restore

def cmd_restore(args) -> int:
    targets = candidate_exes(args.exe)
    if not targets:
        print('No XCOM 2 executable found. Use --exe "<path>" to point at one.')
        return EXIT_FAIL

    acted = 0
    failed = 0
    for path in targets:
        print()
        print('XCOM 2 StackFix - restore')
        print('-' * 25)
        print('  executable %s' % path)

        try:
            fields = read_fields(path)
        except (PEError, OSError) as exc:
            print('  unreadable: %s' % exc)
            failed += 1
            continue

        backup = fields.backup_path()
        if not os.path.isfile(backup):
            print('  backup     not found: %s' % backup)
            print()
            print('  Nothing to restore from. "Verify integrity of game files" in')
            print('  Steam also returns a clean executable.')
            failed += 1
            continue

        try:
            with open(backup, 'rb') as f:
                original = f.read()
        except OSError as exc:
            print('  backup     unreadable: %s' % exc)
            failed += 1
            continue

        print('  backup     %s  (%s bytes)' % (backup, f'{len(original):,}'))

        if len(original) != os.path.getsize(path):
            print()
            print('  REFUSED    the backup and the installed executable differ in size.')
            print('             The backup does not belong to this file - not touching')
            print('             anything.')
            failed += 1
            continue

        try:
            orig_fields = StackFields(original, backup)
        except PEError as exc:
            print('  REFUSED    backup is not a readable PE image: %s' % exc)
            failed += 1
            continue

        if fields.reserve == orig_fields.reserve:
            print('  difference none - reserve already matches the backup')
            continue

        print('  reserve now   0x%08X  %s'
              % (fields.reserve, human(fields.reserve)))
        print('  reserve back  0x%08X  %s'
              % (orig_fields.reserve, human(orig_fields.reserve)))

        if fields.commit != orig_fields.commit:
            print()
            print('  REFUSED    SizeOfStackCommit differs from the backup too.')
            print('             This tool never writes commit; something else changed')
            print('             it. Refusing to act - inspect the file manually.')
            failed += 1
            continue

        if args.dry_run:
            print()
            print('  --dry-run: nothing was written.')
            acted += 1
            continue

        try:
            _write_reserve(path, orig_fields.reserve)
            after = read_fields(path)
            if after.reserve != orig_fields.reserve:
                print('  FAILED     read-back shows 0x%08X, expected 0x%08X'
                      % (after.reserve, orig_fields.reserve))
                failed += 1
                continue
            print('  written    reserve is back to 0x%08X  %s'
                  % (after.reserve, human(after.reserve)))
            print('  note       only the 8 reserve bytes were rewritten; any other')
            print('             patch on this executable is untouched')
            acted += 1
        except (OSError, PEError) as exc:
            if _is_access_denied(exc):
                _print_admin_hint()
            else:
                print('  FAILED     %s' % exc)
            failed += 1

    print()
    if failed:
        print('  %d restored, %d failed.' % (acted, failed))
        return EXIT_FAIL
    print('  Done.' if acted else '  Nothing changed.')
    return EXIT_OK


# --------------------------------------------------------------------- argv

def add_common_options(p: argparse.ArgumentParser) -> None:
    p.add_argument('--exe', metavar='PATH',
                   help='operate on a specific XCom2.exe instead of auto-detecting')
    p.add_argument('--dry-run', action='store_true',
                   help='show what would happen without writing anything')


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog='xcom2_stackfix.py',
        description='Raise the XCOM 2 thread-stack reserve so heavily modded '
                    'campaigns stop crashing with 0xC00000FD.',
        epilog='Nothing is written without a backup, and restore rewrites only '
               'the 8 reserve bytes.')
    sub = p.add_subparsers(dest='command')

    st = sub.add_parser('status', help='inspect the executable(s): show state')
    add_common_options(st)

    ap = sub.add_parser('apply', help='raise the thread-stack reserve')
    ap.add_argument('mib', nargs='?', type=int, default=DEFAULT_MIB,
                    metavar='MiB',
                    help='new reserve in MiB (default %d)' % DEFAULT_MIB)
    add_common_options(ap)
    ap.add_argument('--yes', action='store_true', help='do not ask for confirmation')
    ap.add_argument('--all', action='store_true',
                    help='(default) act on every executable found')

    rs = sub.add_parser('restore', help='put the original reserve back')
    add_common_options(rs)
    rs.add_argument('--yes', action='store_true', help='do not ask for confirmation')

    return p


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.command:
        parser.print_help()
        return EXIT_FAIL

    if getattr(args, 'all', False) and args.exe:
        parser.error('--all and --exe cannot be combined')

    handler = {'status': cmd_status, 'apply': cmd_apply, 'restore': cmd_restore}[args.command]
    try:
        return handler(args)
    except KeyboardInterrupt:
        print()
        return EXIT_FAIL


if __name__ == '__main__':
    sys.exit(main())
