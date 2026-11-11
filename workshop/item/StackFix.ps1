#Requires -Version 5.1
<#
    XCOM 2 StackFix  -  Stop the 0xC00000FD crash
    ==============================================

    In a heavily modded campaign, XCom2.exe sometimes copies a very large
    array onto the thread stack in one go (a single "sub rsp, rax" asking
    for 5.6 - 10 MB). The default thread stack is only ~4.77 MiB
    (PE header SizeOfStackReserve = 5,000,000), so the request walks past
    the guard page and the game dies with:

        0xC00000FD  STACK_OVERFLOW   (XCom2.exe+0x10a3f18, _chkstk)

    The crash is data-driven: the bigger the campaign (more mods, more
    units, longer history), the bigger that array gets. Six out of six
    observed battle crashes happened while a mod let the player control
    the alien team's turn - but the underlying stack request is vanilla
    engine behaviour; any large enough campaign can hit it.

    This script raises ONE field in the PE optional header:

        SizeOfStackReserve  @ optional header +0x48 (8 bytes, PE32+)
            5,000,000  ->  33,554,432   (32 MiB)

    SizeOfStackCommit is NOT touched - that is physical memory handed to
    every thread immediately. Reserve is only address space; a 64-bit
    process has 128 TB of it, so 145 threads x 32 MiB = 4.6 GB reserved
    costs nothing. The stack still grows page by page on demand.

    Observed peak request was 10,024,968 bytes (9.56 MiB), so 32 MiB
    leaves a 3.3x margin.

    Restore rolls back ONLY those 8 bytes, so a SaveFix-style code patch
    applied to the same executable is never disturbed.

    The patch site is found by parsing the PE header - never a hard-coded
    file offset - so it relocates if the header layout shifts. The script
    refuses to act on a non-PE32+ file, and refuses to "restore" a backup
    that does not match the installed file.

    USAGE
        .\StackFix.ps1                 # report only (read-only, the default)
        .\StackFix.ps1 Apply           # patch, raising the reserve to 32 MiB
        .\StackFix.ps1 Apply -MiB 64   # patch, raising it to 64 MiB instead
        .\StackFix.ps1 Restore         # put the original value back
        .\StackFix.ps1 Apply -Exe "D:\Games\XCOM 2\...\XCom2.exe"

    Requires Windows PowerShell 5.1 or newer. No third-party modules.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Status', 'Apply', 'Restore')]
    [string]$Action = 'Status',

    [string]$Exe,

    [ValidateRange(8, 1024)]
    [int]$MiB = 32,

    [switch]$Yes
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$SCRIPT:ReserveOffInOpt = 0x48      # SizeOfStackReserve, PE32+ optional header
$SCRIPT:CommitOffInOpt = 0x50       # SizeOfStackCommit (never written)
$SCRIPT:VanillaReserve = [uint64]5000000
$SCRIPT:BackupExt = '.stackbak'
$SCRIPT:PeakObserved = 10024968     # largest stack request seen across 6 dumps

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkCyan
}

function Test-AccessDenied([System.Exception]$Error_) {
    $e = $Error_
    $depth = 0
    while ($e -and $depth -lt 8) {
        if ($e -is [System.UnauthorizedAccessException]) { return $true }
        if ($e -is [System.Security.SecurityException]) { return $true }
        $e = $e.InnerException
        $depth++
    }
    return $false
}

function Write-AdminHint {
    Write-Host ''
    Write-Host '  The Steam folder is normally administrator-only, because Steam' -ForegroundColor Yellow
    Write-Host '  installs under "C:\Program Files (x86)" by default.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Fix: right-click StackFix.bat and choose "Run as administrator".' -ForegroundColor Yellow
    Write-Host '       (StackFix.bat also offers this automatically when it sees the error.)' -ForegroundColor Yellow
    Write-Host '       If you run StackFix.ps1 directly, start an administrator PowerShell first.' -ForegroundColor Yellow
    Write-Host ''
}

function Write-Item([string]$Label, [string]$Value, [string]$Color = 'Gray') {
    Write-Host ('  {0,-14} {1}' -f ($Label + ':'), $Value) -ForegroundColor $Color
}

function Format-Bytes([uint64]$Value) {
    if ($Value -ge 1MB) { return ('{0:N0} ({1} MiB)' -f $Value, [int]($Value / 1MB)) }
    if ($Value -ge 1KB) { return ('{0:N0} ({1} KiB)' -f $Value, [int]($Value / 1KB)) }
    return ('{0:N0}' -f $Value)
}

function Get-Sha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            return ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '')
        }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

# ---------------------------------------------------------------------------
# PE parsing - just enough to find the optional header
# ---------------------------------------------------------------------------

function Get-PeInfo {
    param([byte[]]$Data, [string]$Path)

    if ($Data.Length -lt 0x40) { throw "File is too small to be a PE image: $Path" }

    $peOff = [System.BitConverter]::ToInt32($Data, 0x3C)
    if ($peOff -le 0 -or ($peOff + 24) -ge $Data.Length) { throw "Not a PE file (bad e_lfanew): $Path" }
    if ([System.BitConverter]::ToUInt32($Data, $peOff) -ne 0x00004550) { throw "Not a PE file (missing PE signature): $Path" }

    $machine = [System.BitConverter]::ToUInt16($Data, $peOff + 4)
    $optSize = [System.BitConverter]::ToUInt16($Data, $peOff + 20)
    $optOff = $peOff + 24

    if ($optOff + $optSize -gt $Data.Length) { throw "Truncated optional header: $Path" }
    $magic = [System.BitConverter]::ToUInt16($Data, $optOff)
    if ($magic -ne 0x20B) {
        throw ("Unsupported optional header magic 0x{0:X} (this script expects the 64-bit PE32+ format): {1}" -f $magic, $Path)
    }

    $imageBase = [System.BitConverter]::ToUInt64($Data, $optOff + 24)

    # SECURITY is data-directory entry 4 and, uniquely, holds a file offset
    # rather than an RVA.  A non-zero size means the image carries an
    # Authenticode signature -- and the field this tool rewrites sits inside the
    # bytes that signature covers, so patching invalidates it.
    $sigSize = 0
    $dirs = $optOff + 0x70          # PE32+ optional header is 0x70 bytes before the directories
    $entry = $dirs + (4 * 8)
    if (($entry + 8) -le $Data.Length) {
        $sigSize = [System.BitConverter]::ToUInt32($Data, $entry + 4)
    }

    [pscustomobject]@{
        Path         = $Path
        ImageBase    = $imageBase
        Machine      = $machine
        OptOff       = $optOff
        ReserveField = $optOff + $SCRIPT:ReserveOffInOpt
        CommitField  = $optOff + $SCRIPT:CommitOffInOpt
        SignatureSize = $sigSize
    }
}

function Get-StackState {
    param([byte[]]$Data, $PeInfo)

    $reserve = [System.BitConverter]::ToUInt64($Data, $PeInfo.ReserveField)
    $commit = [System.BitConverter]::ToUInt64($Data, $PeInfo.CommitField)

    $state = if ($reserve -eq $SCRIPT:VanillaReserve) { 'vanilla' } else { 'patched' }

    [pscustomobject]@{
        Reserve = $reserve
        Commit  = $commit
        State   = $state
    }
}

# ---------------------------------------------------------------------------
# Locating the game
# ---------------------------------------------------------------------------

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                if ($props.PSObject.Properties.Name -contains $name) {
                    $value = $props.$name
                    if ($value) { $roots.Add(($value -replace '/', '\')) }
                }
            }
        }
        catch { }
    }

    $vdfRel = 'steamapps\libraryfolders.vdf'
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (-not $libs.Contains($root)) { $libs.Add($root) }

        $vdf = Join-Path $root $vdfRel
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in [System.IO.File]::ReadAllLines($vdf)) {
                $m = [regex]::Match($line, '"path"\s+"([^"]+)"')
                if ($m.Success) {
                    $p = $m.Groups[1].Value -replace '\\\\', '\'
                    if ((Test-Path -LiteralPath $p) -and (-not $libs.Contains($p))) { $libs.Add($p) }
                }
            }
        }
    }

    if ($libs.Count -eq 0) {
        foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            foreach ($sub in @('Steam', 'SteamLibrary', 'Games\Steam', 'Program Files (x86)\Steam')) {
                $p = Join-Path ($drive.Root + '') $sub
                if ((Test-Path -LiteralPath $p) -and (-not $libs.Contains($p))) { $libs.Add($p) }
            }
        }
    }

    return [pscustomobject]@{ Paths = $libs.ToArray() }
}

function Get-CandidateExes {
    $wanted = @(
        @{ Rel = 'steamapps\common\XCOM 2\XCom2-WarOfTheChosen\Binaries\Win64\XCom2.exe'; Build = 'War of the Chosen' },
        @{ Rel = 'steamapps\common\XCOM 2\Binaries\Win64\XCom2.exe'; Build = 'base game' }
    )

    $found = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.List[string]

    foreach ($lib in (Get-SteamLibraries).Paths) {
        foreach ($w in $wanted) {
            $p = Join-Path $lib $w.Rel
            if (Test-Path -LiteralPath $p) {
                $full = (Resolve-Path -LiteralPath $p).Path
                $key = $full.ToLowerInvariant()
                if (-not $seen.Contains($key)) {
                    $seen.Add($key)
                    $found.Add([pscustomobject]@{ Path = $full; Build = $w.Build })
                }
            }
        }
    }

    return [pscustomobject]@{ Items = $found.ToArray() }
}

function Get-BuildLabel {
    param([byte[]]$Data)

    # "War of the Chosen" as UTF-16LE appears only in the WOTC build, which
    # makes it a reliable in-file signal (paths and file names are not).
    $needle = [System.Text.Encoding]::Unicode.GetBytes('War of the Chosen')
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $haystack = $latin1.GetString($Data)
    $pattern = $latin1.GetString($needle)

    if ($haystack.IndexOf($pattern, [System.StringComparison]::Ordinal) -ge 0) { return 'War of the Chosen' }
    return 'base game'
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Get-TargetExe {
    param([string]$Given)

    if ($Given) {
        if (-not (Test-Path -LiteralPath $Given)) { throw "Executable not found: $Given" }
        $full = (Resolve-Path -LiteralPath $Given).Path
        return [pscustomobject]@{ Path = $full; Build = $null }
    }

    $candidates = @((Get-CandidateExes).Items)
    if ($candidates.Count -eq 0) {
        throw 'Could not find XCom2.exe automatically. Pass it explicitly, e.g. -Exe "D:\Steam\steamapps\common\XCOM 2\XCom2-WarOfTheChosen\Binaries\Win64\XCom2.exe"'
    }

    foreach ($c in $candidates) { if ($c.Build -eq 'War of the Chosen') { return $c } }
    return $candidates[0]
}

function Show-State {
    param($Target, $PeInfo, $State, [string]$Build)

    Write-Item 'executable' $Target.Path
    Write-Item 'build' $Build
    Write-Item 'reserve' ('0x{0:X8}  {1}' -f $State.Reserve, (Format-Bytes $State.Reserve))
    Write-Item 'commit' ('0x{0:X8}  {1}  (never written)' -f $State.Commit, (Format-Bytes $State.Commit))
    Write-Item 'peak seen' (Format-Bytes $SCRIPT:PeakObserved)

    if ($PeInfo -and $PeInfo.SignatureSize -gt 0) {
        Write-Item 'signature' ('{0:N0} bytes (Authenticode) - writing the field below invalidates it' -f $PeInfo.SignatureSize)
    }
    elseif ($PeInfo) {
        Write-Item 'signature' 'none'
    }

    if ($State.State -eq 'vanilla') {
        Write-Item 'state' ('ORIGINAL - reserve is 5,000,000 (~4.77 MiB)' ) 'Yellow'
        if ($SCRIPT:PeakObserved -gt $State.Reserve) {
            Write-Item 'risk' ('a 10 MB stack request would overflow this' ) 'Yellow'
        }
    }
    else {
        Write-Item 'state' ('PATCHED - reserve is {0}' -f (Format-Bytes $State.Reserve)) 'Green'
        if ($State.Reserve -gt $SCRIPT:PeakObserved) {
            Write-Item 'margin' ('{0:N1}x above the largest observed request' -f ($State.Reserve / $SCRIPT:PeakObserved)) 'Green'
        }
    }
}

function Invoke-Status {
    param($Target)

    $data = [System.IO.File]::ReadAllBytes($Target.Path)
    $pe = Get-PeInfo -Data $data -Path $Target.Path
    $build = Get-BuildLabel -Data $data
    $state = Get-StackState -Data $data -PeInfo $pe

    Write-Head 'XCOM 2 StackFix - status'
    Write-Item 'size' ('{0:N0} bytes' -f $data.Length)
    Write-Item 'sha256' (Get-Sha256 -Path $Target.Path)
    Show-State -Target $Target -PeInfo $pe -State $state -Build $build

    $backup = $Target.Path + $SCRIPT:BackupExt
    Write-Head 'Backup'
    if (Test-Path -LiteralPath $backup) {
        Write-Item 'backup' $backup 'Green'
    }
    else {
        Write-Item 'backup' 'none yet (Apply creates one automatically)' 'DarkGray'
    }

    if ($state.State -eq 'vanilla') {
        Write-Host ''
        Write-Host '  This executable can be patched - run "StackFix.bat Apply" to do it.' -ForegroundColor Yellow
        exit 10
    }
    else {
        Write-Host ''
        Write-Host '  Nothing to do - this executable is already patched.' -ForegroundColor Green
    }
}

function Invoke-Apply {
    param($Target, [int]$NewMiB)

    $data = [System.IO.File]::ReadAllBytes($Target.Path)
    $pe = Get-PeInfo -Data $data -Path $Target.Path
    $build = Get-BuildLabel -Data $data
    $state = Get-StackState -Data $data -PeInfo $pe

    Write-Head 'XCOM 2 StackFix - apply'
    Show-State -Target $Target -PeInfo $pe -State $state -Build $build

    $new = [uint64]$NewMiB * 1MB

    if ($state.Reserve -eq $new) {
        Write-Host ''
        Write-Host ('  Already patched to {0} MiB - nothing to do.' -f $NewMiB) -ForegroundColor Green
        exit 0
    }

    if ($state.State -ne 'vanilla' -and $state.Reserve -ne $SCRIPT:VanillaReserve) {
        Write-Host ''
        Write-Host ('  ABORTED: the reserve is neither the original 5,000,000 nor the requested value,') -ForegroundColor Red
        Write-Host ('           it is {0}. Another tool has modified this file.' -f $state.Reserve) -ForegroundColor Red
        Write-Host '           Restore the backup first, or patch a clean copy.' -ForegroundColor Red
        exit 2
    }

    Write-Host ''
    Write-Host ('  About to change SizeOfStackReserve: {0}  ->  {1}' -f (Format-Bytes $state.Reserve), (Format-Bytes $new)) -ForegroundColor White
    Write-Host '  (SizeOfStackCommit stays untouched. Reserve is address space only.)' -ForegroundColor DarkGray
    if ($pe.SignatureSize -gt 0) {
        Write-Host '  Note: this field is covered by the executable''s signature, so the' -ForegroundColor DarkGray
        Write-Host '  signature will no longer validate afterwards. Normal Windows still' -ForegroundColor DarkGray
        Write-Host '  starts the game; a locked-down machine, or an antivirus that treats' -ForegroundColor DarkGray
        Write-Host '  modified executables as tampering, may not. See ReadMe.txt.' -ForegroundColor DarkGray
    }

    if (-not $Yes) {
        $answer = Read-Host '  Proceed? [y/N]'
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host '  Cancelled.' -ForegroundColor DarkGray
            exit 0
        }
    }

    # Back up first, then write, then read back and verify.
    $backup = $Target.Path + $SCRIPT:BackupExt
    if (-not (Test-Path -LiteralPath $backup)) {
        try {
            Copy-Item -LiteralPath $Target.Path -Destination $backup -Force
        }
        catch {
            Write-Host ''
            Write-Host '  FAILED: could not create the backup next to the executable.' -ForegroundColor Red
            Write-Host ('          ' + $_.Exception.Message) -ForegroundColor Red
            Write-Host '          The Steam folder is normally administrator-only. Run this as' -ForegroundColor Yellow
            Write-Host '          administrator (right-click StackFix.bat -> "Run as administrator"),' -ForegroundColor Yellow
            Write-Host '          or use StackFix.bat, which asks for it.' -ForegroundColor Yellow
            exit 4
        }
        Write-Item 'backup' ('created ' + $backup) 'Green'
    }
    else {
        Write-Item 'backup' ('kept existing ' + $backup) 'DarkGray'
    }

    $newBytes = [System.BitConverter]::GetBytes([uint64]$new)
    $writeOff = [int]$pe.ReserveField

    try {
        $stream = [System.IO.File]::Open($Target.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $stream.Position = $writeOff
            $stream.Write($newBytes, 0, 8)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch [System.UnauthorizedAccessException] {
        Write-Host ''
        Write-Host '  FAILED: access denied. The game folder is normally administrator-only' -ForegroundColor Red
        Write-Host '          because Steam installs under "C:\Program Files (x86)".' -ForegroundColor Red
        Write-Host ''
        Write-Host '          Run this as administrator (right-click StackFix.bat and choose' -ForegroundColor Yellow
        Write-Host '          "Run as administrator"), or use StackFix.bat, which asks for it.' -ForegroundColor Yellow
        Write-Host '          If XCOM 2 is running, close it first.' -ForegroundColor Yellow
        exit 4
    }
    catch [System.IO.IOException] {
        Write-Host ''
        Write-Host ('  FAILED: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '          If XCOM 2 is running, close it first.' -ForegroundColor Red
        Write-Host '          If the message mentions access or permission, run this as' -ForegroundColor Yellow
        Write-Host '          administrator (the Steam folder is normally admin-only).' -ForegroundColor Yellow
        exit 3
    }

    $check = [System.IO.File]::ReadAllBytes($Target.Path)
    $nowReserve = [System.BitConverter]::ToUInt64($check, $writeOff)
    $nowCommit = [System.BitConverter]::ToUInt64($check, [int]$pe.CommitField)

    Write-Head 'Result'
    Write-Item 'reserve now' (Format-Bytes $nowReserve)
    Write-Item 'commit now' ((Format-Bytes $nowCommit) + '  (unchanged)')

    if ($nowReserve -eq $new -and $nowCommit -eq $state.Commit) {
        Write-Item 'verify' 'OK' 'Green'
        Write-Host ''
        Write-Host ('  Done. The thread stack reserve is now {0} MiB.' -f $NewMiB) -ForegroundColor Green
        Write-Host '  Start the game and play the mission that used to crash.' -ForegroundColor Green
        exit 0
    }

    Write-Item 'verify' 'MISMATCH' 'Red'
    Write-Host ''
    Write-Host '  The write did not stick. Restore from the backup and try again.' -ForegroundColor Red
    exit 3
}

function Invoke-Restore {
    param($Target)

    $backup = $Target.Path + $SCRIPT:BackupExt

    Write-Head 'XCOM 2 StackFix - restore'

    if (-not (Test-Path -LiteralPath $backup)) {
        Write-Item 'backup' ('not found: ' + $backup) 'Red'
        Write-Host ''
        Write-Host '  Nothing to restore from. Use the Steam client option' -ForegroundColor Yellow
        Write-Host '  "Verify integrity of game files" to get a clean executable back.' -ForegroundColor Yellow
        exit 2
    }

    $current = [System.IO.File]::ReadAllBytes($Target.Path)
    $original = [System.IO.File]::ReadAllBytes($backup)

    Write-Item 'executable' $Target.Path
    Write-Item 'backup' $backup
    Write-Item 'backup size' ('{0:N0} bytes' -f $original.Length)

    if ($current.Length -ne $original.Length) {
        Write-Host ''
        Write-Host '  ABORTED: the backup and the installed executable differ in size.' -ForegroundColor Red
        Write-Host '           The backup does not belong to this file - not touching anything.' -ForegroundColor Red
        exit 2
    }

    # Roll back ONLY the 8 reserve bytes (plus verify commit is untouched).
    # A code patch like SaveFix applied to the same executable survives this.
    $pe = Get-PeInfo -Data $current -Path $Target.Path
    $origReserve = [System.BitConverter]::ToUInt64($original, [int]$pe.ReserveField)
    $curReserve = [System.BitConverter]::ToUInt64($current, [int]$pe.ReserveField)
    $curCommit = [System.BitConverter]::ToUInt64($current, [int]$pe.CommitField)
    $origCommit = [System.BitConverter]::ToUInt64($original, [int]$pe.CommitField)

    if ($curReserve -eq $origReserve) {
        Write-Item 'difference' 'none - reserve already matches the backup' 'Green'
        exit 0
    }

    Write-Item 'reserve now' (Format-Bytes $curReserve)
    Write-Item 'reserve back' (Format-Bytes $origReserve)

    if ($curCommit -ne $origCommit) {
        Write-Host ''
        Write-Host '  ABORTED: SizeOfStackCommit differs from the backup too.' -ForegroundColor Red
        Write-Host '           This tool never writes commit; something else changed it.' -ForegroundColor Red
        Write-Host '           Refusing to act - inspect the file manually.' -ForegroundColor Red
        exit 2
    }

    try {
        $stream = [System.IO.File]::Open($Target.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $stream.Position = [int]$pe.ReserveField
            $stream.Write([System.BitConverter]::GetBytes([uint64]$origReserve), 0, 8)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        Write-Host ''
        Write-Host ('  FAILED: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '          Close XCOM 2 if it is running. If the message mentions access' -ForegroundColor Yellow
        Write-Host '          or permission, run this as administrator.' -ForegroundColor Yellow
        exit 3
    }

    $after = [System.IO.File]::ReadAllBytes($Target.Path)
    $afterReserve = [System.BitConverter]::ToUInt64($after, [int]$pe.ReserveField)

    Write-Head 'Result'
    if ($afterReserve -eq $origReserve) {
        Write-Item 'verify' 'OK - reserve matches the backup' 'Green'
        Write-Host ''
        Write-Host '  The original stack reserve is back in place.' -ForegroundColor Green
        Write-Host '  (Only those 8 bytes were rewritten - any other patch on this' -ForegroundColor DarkGray
        Write-Host '   executable, such as SaveFix, is untouched.)' -ForegroundColor DarkGray
        exit 0
    }

    Write-Item 'verify' 'MISMATCH' 'Red'
    exit 3
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    $target = Get-TargetExe -Given $Exe

    switch ($Action) {
        'Status' { Invoke-Status -Target $target }
        'Apply' { Invoke-Apply -Target $target -NewMiB $MiB }
        'Restore' { Invoke-Restore -Target $target }
    }
}
catch {
    Write-Host ''
    if (Test-AccessDenied $_.Exception) {
        Write-Host 'ERROR: access denied.' -ForegroundColor Red
        Write-Host ('       ' + $_.Exception.Message) -ForegroundColor DarkGray
        Write-AdminHint
        exit 4
    }
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
