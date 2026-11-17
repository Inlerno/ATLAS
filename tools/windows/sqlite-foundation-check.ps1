<#
.SYNOPSIS
    Manual Windows check of the ATLAS SQLite foundation (ADR-016, issue #26).

.DESCRIPTION
    Runs the built ATLAS application through a set of storage scenarios and
    writes a report: application logs, SHA-256 of the files before and after
    each scenario, exit codes, the time of a normal exit, PASS / FAIL / SKIPPED
    for every scenario.

    ATLAS always keeps its data in %LOCALAPPDATA%\com.inlerno.atlas: Tauri
    asks Windows for that folder and no environment variable redirects it. So
    the script does not try to redirect it. Instead, in this order, it

      1. refuses to start while ATLAS or a WebView2 process of ATLAS is
         running, while it cannot tell whose a WebView2 process is, or while
         a previous run of this script was not restored;
      2. gives the run a unique id and writes a manifest
         %LOCALAPPDATA%\com.inlerno.atlas.sqlite-check\manifest-<id>.txt
         (outside the data directory) that names the data directory, the
         backup and a fingerprint of the data directory (names and sizes);
      3. prepares the test directory NEXT TO the data directory and marks it
         with a sentinel file that holds the same run id;
      4. renames the data directory to
         com.inlerno.atlas.sqlite-check-backup-<timestamp>-<id> and compares
         it with the fingerprint;
      5. renames the prepared test directory into place, so the data path is
         never occupied by an unmarked directory; every destructive step
         first checks the sentinel and its run id;
      6. in `finally` moves the test directory into the report (or, if that
         is not possible, renames it aside) and renames the backup back.

    The backup and the manifest are never deleted and never overwritten by
    this script. A backup is put back only when the run id in its name, the
    manifest of that id and (if a test directory is in place) the sentinel
    agree and the fingerprint matches; the fingerprint is compared before
    the backup is moved and once more after it. Nothing in the data path is
    moved until it is certain that no ATLAS process and no WebView2 process
    of ATLAS or of unknown owner is running; the script never ends processes
    it did not start. Anything else is a safe stop: nothing is moved and
    RESTORE-INSTRUCTIONS.txt in the report says what to do.

    Next to the manifest two small marker files record how far a run got;
    the manifest itself is never rewritten. touched-<id>.txt is written
    right before the run first changes the data path; done-<id>.txt is
    written when the run (or a later -RestoreOnly) has confirmed that the
    data path is settled. A run with "touched" and without "done" is not
    finished: while the directory in the data path cannot be proven to be
    the test directory of that run (its sentinel is missing, damaged or of
    another run) or the original data (by the fingerprint), the script
    moves nothing, ends with exit code 3 and never says "nothing to
    restore".

    A "done" marker counts only when it is whole. Its format is exactly
    these five lines, nothing before, between or after them:

        format=atlas-sqlite-check-marker-1
        kind=done
        run_id=<the 32 hexadecimal digits of the file name done-<id>.txt>
        written=<yyyyMMdd-HHmmss>
        end=<the same run id>

    An empty, cut short, unreadable or otherwise different file, or one
    with another run id, is NOT a "done" marker: the run stays unfinished,
    the script ends with exit code 3 and names the file. It never repairs,
    rewrites or deletes such a file; you replace it by hand after you have
    looked at the directories (RESTORE-INSTRUCTIONS.txt has the command).
    The script itself writes the marker to a temporary file
    tmp-done-<id>-<random>.tmp in the same directory, checks it and renames
    it into place without overwriting. A temporary file that is left behind
    is never taken for a marker and never deleted by the script.

    Do NOT start ATLAS while the script isolates or restores the data
    directory. The check of the processes is an additional safeguard, not a
    guarantee: a process that starts between the check and the file
    operation is not seen.

    Limit of the fingerprint: it covers the names, the types (file or
    directory) and the sizes of everything in the data directory, NOT the
    contents of the files. A change that keeps every name and size is not
    noticed by it.

    Exit codes: 0 all scenarios passed; 1 a scenario failed or the run was
    stopped, the original data is in its place; 2 refused before anything was
    changed, the data is in its place; 3 the original data is NOT in its
    place (also when an earlier run left it so): -RestoreOnly or manual
    action is needed.

    The messages are ASCII on purpose: Windows PowerShell 5.1 reads a script
    without a byte order mark in the system code page.

    This one file is all that is needed: it does not depend on where it
    lies or on a copy of the repository. Its own tests are built in
    (-SelfTest).

.PARAMETER Exe
    The application to run, for example a freshly built atlas.exe. Without
    it the script looks in these places, in this order, and takes what it
    finds:
      <current directory>\src-tauri\target\release\atlas.exe
      <current directory>\atlas.exe
      <directory of this script>\atlas.exe
      %LOCALAPPDATA%\ATLAS\ATLAS.exe
      %LOCALAPPDATA%\Programs\ATLAS\ATLAS.exe
      %ProgramFiles%\ATLAS\ATLAS.exe
      %ProgramFiles(x86)%\ATLAS\ATLAS.exe
    One found: it is used. Several or none: in a console the script asks;
    otherwise it refuses. Whatever happens, it refuses before anything is
    changed unless the application exists.

.PARAMETER Source
    A copy of the ATLAS repository, only for -Build. Default: the current
    directory, if it is one. A directory counts as ATLAS only when all of
    this holds: package.json is valid JSON with "name": "atlas" and a
    "build" script; src-tauri\Cargo.toml has name = "atlas" in [package] and
    name = "atlas_lib" in [lib]; src-tauri\tauri.conf.json is valid JSON
    with "identifier": "com.inlerno.atlas" (the application whose data
    directory this script isolates) and "productName": "ATLAS". Anything
    missing, unreadable or different: the script refuses, with the reason,
    before anything is installed, built or changed. This catches a wrong
    folder, not a forged one.

.PARAMETER Build
    Build the application from -Source first: npm ci, npm run build, cargo
    build --locked --release --features tauri/custom-protocol. The built
    src-tauri\target\release\atlas.exe is then the application.

.PARAMETER RestoreOnly
    Do not run any scenario: only put a data directory back that an
    interrupted run of this script left renamed. Safe to repeat.

.PARAMETER StartTimeoutSec
    How long to wait for the storage line in the application log.

.PARAMETER ExitTimeoutSec
    How long to wait for the application to exit after its window was closed.

.PARAMETER SelfTest
    Run the tests of this script and nothing else. Every case works in a
    temporary directory of its own: ATLAS is not started and %LOCALAPPDATA%
    is not touched. To prove that, everything named com.inlerno.atlas* in
    the real %LOCALAPPDATA% is recorded before and after the tests, object
    by object: the type and the relative path of each, and the size and
    the SHA-256 of every file; junctions and symbolic links are recorded
    and not followed. If ATLAS is running the tests are not started: close
    ATLAS and try again. They are not started either while a WebView2
    process runs whose command line cannot be read: it may belong to ATLAS,
    and the script does not assume that it does not. No process is ended. If the record cannot be taken completely (a file
    cannot be read, a directory cannot be listed, a path is too long for
    Windows PowerShell 5.1) the tests fail instead of passing over it.
    Exit codes: 0 every check passed; 1 a check failed; 2 the tests were
    not started.

.PARAMETER Keep
    Only with -SelfTest: keep the temporary directories for inspection.

.PARAMETER TestBase
    Only with -SelfTest, for the tests of this script. An existing directory
    that stands in for the profile: <TestBase>\local replaces %LOCALAPPDATA%
    and <TestBase>\home receives the report; the real %LOCALAPPDATA% is not
    read. -SelfTest -TestBase alone makes the guard of the test suite check
    itself against that test profile and runs no test case.

.PARAMETER TestRun
    Only with -SelfTest -TestBase: run the script itself against the test
    profile, as the test cases do. The application is never started and no
    scenario runs: only the backup and restore steps are exercised.

.PARAMETER TestFault
    Only with -SelfTest -TestBase: comma separated names of steps that must
    fail.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\sqlite-foundation-check.ps1 -SelfTest

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\sqlite-foundation-check.ps1 -Exe C:\path\to\atlas.exe

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\sqlite-foundation-check.ps1 -Build -Source C:\src\ATLAS

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\sqlite-foundation-check.ps1 -RestoreOnly
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [switch]$Build,
    [switch]$RestoreOnly,
    [int]$StartTimeoutSec = 90,
    [int]$ExitTimeoutSec = 45,
    [string]$TestBase,
    [string]$TestFault,
    [string]$Source,
    [switch]$SelfTest,
    [switch]$Keep,
    [switch]$TestRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants and paths
# ---------------------------------------------------------------------------

$AppId = 'com.inlerno.atlas'
$SentinelName = '.atlas-sqlite-check-test-root'
$BackupInfix = '.sqlite-check-backup-'
$StageInfix = '.sqlite-check-test-'
$StateDirName = "$AppId.sqlite-check"
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunId = [guid]::NewGuid().ToString('N')

# Windows PowerShell 5.1 has no $IsWindows; it only runs on Windows.
$OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows

# The test switches. Nothing but -SelfTest opens them:
#   -SelfTest                         the whole test suite; the real profile is
#                                     only watched, never changed;
#   -SelfTest -TestBase X             the guard of the suite checks itself, with
#                                     X\local in the place of the real profile;
#   -SelfTest -TestBase X -TestRun    one run of the script itself against the
#                                     test profile X (what the cases start).
# -TestFault needs -SelfTest -TestBase. Every other combination is refused
# here, before anything is read or changed.
if ($TestBase -and -not $SelfTest) {
    throw '-TestBase is only for the tests of this script and needs -SelfTest. Nothing was changed.'
}
if ($TestFault -and -not ($SelfTest -and $TestBase)) {
    throw '-TestFault is only for the tests of this script and needs -SelfTest -TestBase. Nothing was changed.'
}
if ($TestRun -and -not ($SelfTest -and $TestBase)) {
    throw '-TestRun is only for the tests of this script and needs -SelfTest -TestBase. Nothing was changed.'
}
if ($Keep -and (-not $SelfTest -or $TestBase)) {
    throw '-Keep is only for -SelfTest without -TestBase. Nothing was changed.'
}
$SuiteMode = [bool]$SelfTest -and -not $TestBase
$GuardMode = [bool]$SelfTest -and [bool]$TestBase -and -not $TestRun
if (($SuiteMode -or $GuardMode) -and ($Exe -or $Build -or $RestoreOnly -or $Source)) {
    throw '-SelfTest does not take -Exe, -Build, -RestoreOnly or -Source. Nothing was changed.'
}
if ($TestBase) {
    if (-not (Test-Path -LiteralPath $TestBase -PathType Container)) {
        throw "-TestBase must be an existing directory: $TestBase. Nothing was changed."
    }
    $TestBase = (Resolve-Path -LiteralPath $TestBase).Path
    $LocalAppData = Join-Path $TestBase 'local'
    $ReportBase = Join-Path $TestBase 'home'
    foreach ($needed in @($LocalAppData, $ReportBase)) {
        if (-not (Test-Path -LiteralPath $needed -PathType Container)) {
            throw "-TestBase needs the directory $needed. Nothing was changed."
        }
    }
} else {
    $LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $ReportBase = $HOME
}
$Faults = @()
if ($TestFault) { $Faults = @($TestFault -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
    throw 'Cannot determine the local application data folder. Nothing was changed.'
}
$Root = Join-Path $LocalAppData $AppId
$DataDir = Join-Path $Root 'data'
$Database = Join-Path $DataDir 'atlas.db'
$Wal = Join-Path $DataDir 'atlas.db-wal'
$Shm = Join-Path $DataDir 'atlas.db-shm'
$Journal = Join-Path $DataDir 'atlas.db-journal'
$Marker = Join-Path $Root 'storage.initialized'
$LogDir = Join-Path $Root 'logs'
$Report = Join-Path $ReportBase "atlas-sqlite-check-$Stamp"
$Backup = "$Root$BackupInfix$Stamp-$RunId"
$Stage = "$Root$StageInfix$Stamp-$RunId"
$StateDir = Join-Path $LocalAppData $StateDirName
$ManifestPath = Join-Path $StateDir "manifest-$RunId.txt"

$script:Results = New-Object System.Collections.ArrayList
$script:Started = New-Object System.Collections.ArrayList
$script:SqliteVersion = ''
$script:ExitTimesMs = New-Object System.Collections.ArrayList

# What this run has done so far. Each flag is set BEFORE the step it stands
# for, so that the restore in `finally` never trusts a step that only may
# have happened: it looks at the disk.
$script:HadOriginal = $false
$script:Fingerprint = $null
$script:ManifestWritten = $false
$script:StageTried = $false
$script:RenameTried = $false
$script:ActivateTried = $false
$script:Touched = $false

# The outcome, printed at the end of every run.
$script:OriginalWhere = 'unknown'
$script:TestWhere = 'none'
$script:OriginalInPlace = $false
$script:ManualSteps = 'none'

$script:Warnings = New-Object System.Collections.ArrayList
$script:LastProblem = ''
$script:StillRunning = ''

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function Write-Note([string]$Text) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
    Write-Host $line
    if (Test-Path -LiteralPath $Report) {
        Add-Content -LiteralPath (Join-Path $Report 'run.txt') -Value $line -Encoding UTF8
    }
}

function Add-Result([string]$Name, [string]$Status, [string]$Detail) {
    [void]$script:Results.Add([pscustomobject]@{ Scenario = $Name; Status = $Status; Detail = $Detail })
    Write-Note ('{0,-8} {1}: {2}' -f $Status, $Name, $Detail)
}

function Get-Sha([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return '-'
}

# The files of the storage with their sizes and hashes, appended to the report.
function Save-State([string]$Label) {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("== $Label")
    foreach ($path in @($Database, $Wal, $Shm, $Journal, $Marker, (Join-Path $Root 'storage.lock'))) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path -Force
            [void]$lines.Add(('{0}  {1,10}  {2}' -f (Get-Sha $path), $item.Length, $path))
        } elseif (Test-Path -LiteralPath $path) {
            [void]$lines.Add(('{0}  {1,10}  {2}' -f 'directory', '-', $path))
        } else {
            [void]$lines.Add(('{0}  {1,10}  {2}' -f 'absent', '-', $path))
        }
    }
    if (Test-Path -LiteralPath $DataDir) {
        $names = @(Get-ChildItem -LiteralPath $DataDir -Force | ForEach-Object { $_.Name }) -join ', '
        [void]$lines.Add("data directory holds: $names")
    }
    Add-Content -LiteralPath (Join-Path $Report 'states.txt') -Value $lines -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# Only for the tests of this script: makes the named step fail. A name that
# starts with "crash-" ends the process at once, without `finally`.
function Invoke-Fault([string]$Name) {
    if ($Faults -contains $Name) {
        if ($Name.StartsWith('crash-')) { [Environment]::Exit(99) }
        throw "injected test fault: $Name"
    }
}

function Get-TextSha([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '')
    } finally { $sha.Dispose() }
}

# Creates a file and fails if it already exists: nothing is ever overwritten.
function Write-NewFile([string]$Path, [string[]]$Lines) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        foreach ($line in $Lines) { $writer.WriteLine($line) }
        $writer.Flush()
    } finally { $stream.Dispose() }
}

# Reads "key=value" lines. Returns $null when the file cannot be read.
function Read-KeyValueFile([string]$Path) {
    try {
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    } catch { return $null }
    $table = @{}
    $order = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        $at = $line.IndexOf('=')
        if ($at -lt 1) { continue }
        $table[$line.Substring(0, $at)] = $line.Substring($at + 1)
        [void]$order.Add($line)
    }
    return [pscustomobject]@{ Table = $table; Lines = @($order) }
}

function Test-SamePath([string]$Left, [string]$Right) {
    $a = "$Left".TrimEnd('\', '/')
    $b = "$Right".TrimEnd('\', '/')
    if ($OnWindows) { return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase) }
    return [string]::Equals($a, $b, [System.StringComparison]::Ordinal)
}

# Names and sizes of everything in a directory. Contents are not read: the
# directory can be large and nothing in it is opened.
function Get-TreeFingerprint([string]$Path) {
    $base = (Get-Item -LiteralPath $Path -Force).FullName.TrimEnd('\', '/')
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @(Get-ChildItem -LiteralPath $base -Recurse -Force -ErrorAction Stop)) {
        $relative = $item.FullName.Substring($base.Length + 1).Replace('\', '/')
        if ($item.PSIsContainer) { $lines.Add("d|$relative") }
        else { $lines.Add("f|$relative|$($item.Length)") }
    }
    $lines.Sort([System.StringComparer]::Ordinal)
    return [pscustomobject]@{ Entries = $lines.Count; Digest = (Get-TextSha ($lines.ToArray() -join "`n")) }
}

# Moves a directory, retrying while files in it are still held (the WebView
# processes of the application take a moment to end).
function Move-Directory([string]$From, [string]$To) {
    $attempts = 15
    if ($TestBase) { $attempts = 1 }
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq $attempts) { throw }
            Start-Sleep -Seconds 1
        }
    }
}

# ---------------------------------------------------------------------------
# Safety: which run a directory belongs to
# ---------------------------------------------------------------------------

# The run id in the sentinel of a directory: $null when there is no sentinel,
# '?' when there is one that cannot be trusted.
function Get-SentinelId([string]$Directory) {
    $path = Join-Path $Directory $SentinelName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $read = Read-KeyValueFile $path
    if ($null -eq $read -or -not $read.Table.ContainsKey('run_id')) { return '?' }
    $id = "$($read.Table['run_id'])"
    if ($id -notmatch '^[0-9a-f]{32}$') { return '?' }
    return $id
}

# Every destructive step calls this first.
function Assert-TestRoot {
    $id = Get-SentinelId $Root
    if ($id -ne $RunId) {
        throw "Safety stop: $Root is not the test directory of this run (no $SentinelName with this run id). Nothing more is changed."
    }
}

# Throws when the folder cannot be listed: "could not look" must never be
# taken for "there is no backup".
function Get-LeftoverBackup {
    Invoke-Fault 'list-backups'
    return @(Get-ChildItem -LiteralPath $LocalAppData -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name.StartsWith("$AppId$BackupInfix") })
}

# The run id a backup directory carries in its name, or $null.
function Get-BackupRunId([string]$Name) {
    if ($Name -match '^com\.inlerno\.atlas\.sqlite-check-backup-\d{8}-\d{6}-([0-9a-f]{32})$') { return $Matches[1] }
    return $null
}

# The manifest of a run, checked: format, run id, its own checksum.
function Read-Manifest([string]$Id) {
    $path = Join-Path $StateDir "manifest-$Id.txt"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Error = "the manifest $path is missing"; Data = $null; Path = $path }
    }
    $read = Read-KeyValueFile $path
    if ($null -eq $read) {
        return [pscustomobject]@{ Ok = $false; Error = "the manifest $path cannot be read"; Data = $null; Path = $path }
    }
    $table = $read.Table
    foreach ($key in @('format', 'run_id', 'root', 'backup', 'entries', 'digest', 'check')) {
        if (-not $table.ContainsKey($key)) {
            return [pscustomobject]@{ Ok = $false; Error = "the manifest $path is damaged (no '$key')"; Data = $null; Path = $path }
        }
    }
    $body = @($read.Lines | Where-Object { -not $_.StartsWith('check=') })
    if ($table['check'] -ne (Get-TextSha ($body -join "`n"))) {
        return [pscustomobject]@{ Ok = $false; Error = "the manifest $path is damaged (checksum)"; Data = $null; Path = $path }
    }
    if ($table['format'] -ne '1' -or $table['run_id'] -ne $Id) {
        return [pscustomobject]@{ Ok = $false; Error = "the manifest $path is for another run or format"; Data = $null; Path = $path }
    }
    return [pscustomobject]@{ Ok = $true; Error = ''; Data = $table; Path = $path }
}

# Marker files next to the manifest: "touched" (the run is about to change
# the data path) and "done" (the data path is settled again). They are only
# ever created, never rewritten or deleted.
function Get-MarkerPath([string]$Kind, [string]$Id) {
    return (Join-Path $StateDir "$Kind-$Id.txt")
}

# The "touched" marker. Any file of that name means "touched": a remnant can
# only make the script more careful.
function Write-Marker([string]$Kind, [string]$Id) {
    if ($Kind -ne 'touched') { throw "Write-Marker writes only 'touched' markers; 'done' goes through Write-DoneMarker." }
    $path = Get-MarkerPath $Kind $Id
    if (Test-Path -LiteralPath $path) { return }
    Write-NewFile $path @("run_id=$Id", "written=$(Get-Date -Format 'yyyyMMdd-HHmmss')")
}

# The five lines of a "done" marker (see the description at the top).
$DoneFormatLine = 'format=atlas-sqlite-check-marker-1'
function Get-DoneLines([string]$Id) {
    return @($DoneFormatLine, 'kind=done', "run_id=$Id", "written=$(Get-Date -Format 'yyyyMMdd-HHmmss')", "end=$Id")
}

# Why the file at $Path is not a whole "done" marker of run $Id, or '' when
# it is one. Every line is compared as a whole and case-sensitively.
function Get-DoneDefect([string]$Path, [string]$Id) {
    $lines = $null
    try {
        if ($TestBase -and ($Faults -contains 'done-read-error')) { throw 'injected test fault: the marker cannot be read' }
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    } catch { return "it cannot be read ($($_.Exception.Message))" }
    $lines = @($lines)
    if ($lines.Count -eq 0) { return 'it is empty' }
    if ($lines.Count -ne 5) { return "it has $($lines.Count) line(s) instead of 5 (cut short or changed)" }
    if ($lines[0] -cne $DoneFormatLine) { return 'its first line is not the format line' }
    if ($lines[1] -cne 'kind=done') { return 'its second line is not "kind=done"' }
    if ($lines[2] -cnotmatch '^run_id=[0-9a-f]{32}$') { return 'it has no valid run_id line' }
    if ($lines[2] -cne "run_id=$Id") { return "its run_id is not the run id in the file name ($Id)" }
    if ($lines[3] -cnotmatch '^written=\d{8}-\d{6}$') { return 'its "written" line is not valid' }
    if ($lines[4] -cne "end=$Id") { return 'its last line is not the "end" line of this run (cut short or changed)' }
    return ''
}

# The "done" marker of a run: absent, valid or invalid (with the reason).
function Get-DoneState([string]$Id) {
    $path = Get-MarkerPath 'done' $Id
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ State = 'absent'; Id = $Id; Path = $path; Reason = '' } }
    $defect = Get-DoneDefect $path $Id
    if ($defect) { return [pscustomobject]@{ State = 'invalid'; Id = $Id; Path = $path; Reason = $defect } }
    return [pscustomobject]@{ State = 'valid'; Id = $Id; Path = $path; Reason = '' }
}

# Every entry named done-*.txt that is not a whole "done" marker. Throws when
# the directory of the manifests cannot be listed.
function Get-InvalidDoneMarkers {
    if (-not (Test-Path -LiteralPath $StateDir)) { return @() }
    $bad = @()
    foreach ($entry in @(Get-ChildItem -LiteralPath $StateDir -Force -ErrorAction Stop)) {
        if ($entry.Name -notmatch '^done-.*\.txt$') { continue }
        if ($entry.Name -notmatch '^done-([0-9a-f]{32})\.txt$') {
            $bad += [pscustomobject]@{ State = 'invalid'; Id = ''; Path = $entry.FullName; Reason = 'its name carries no run id' }
            continue
        }
        $state = Get-DoneState $Matches[1]
        if ($state.State -eq 'invalid') { $bad += $state }
    }
    return $bad
}

# Writes the "done" marker of a run: a temporary file in the same directory,
# flushed to the disk, read back and checked, then renamed into place.
# File.Move never overwrites, in .NET Framework (Windows PowerShell 5.1) and
# in .NET (PowerShell 7) alike. Nothing is deleted on failure: a temporary
# file that stays is not a marker. Throws unless a valid marker is in place
# afterwards.
function Write-DoneMarker([string]$Id) {
    $existing = Get-DoneState $Id
    if ($existing.State -eq 'valid') { return }
    if ($existing.State -eq 'invalid') {
        throw "the marker $($existing.Path) exists and is not a valid `"done`" marker ($($existing.Reason)); it was not overwritten"
    }
    $final = $existing.Path
    $temp = Join-Path $StateDir "tmp-done-$Id-$([guid]::NewGuid().ToString('N')).tmp"
    Invoke-Fault 'done-temp-write'
    $stream = [System.IO.File]::Open($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        $lines = @(Get-DoneLines $Id)
        if ($TestBase -and ($Faults -contains 'done-temp-partial')) { $lines = @($lines[0..1]) }
        foreach ($line in $lines) { $writer.WriteLine($line) }
        $writer.Flush()
        # Through the cache of the operating system to the disk.
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    $defect = Get-DoneDefect $temp $Id
    if ($defect) { throw "the temporary marker $temp does not read back ($defect); the run is not marked as finished" }
    Invoke-Fault 'done-rename'
    # Only for the tests: another file takes the final name at the last moment.
    if ($TestBase -and ($Faults -contains 'done-final-appears')) { [System.IO.File]::WriteAllText($final, 'not written by this run') }
    [System.IO.File]::Move($temp, $final)
    $after = Get-DoneState $Id
    if ($after.State -ne 'valid') { throw "the marker $final is not valid after the rename ($($after.Reason))" }
}

# The ids of the runs that touched the data path and have no valid "done"
# marker. Throws when the directory of the manifests cannot be listed.
function Get-TouchedRuns {
    if (-not (Test-Path -LiteralPath $StateDir)) { return @() }
    $ids = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $StateDir -Force -ErrorAction Stop)) {
        if ($file.Name -match '^touched-([0-9a-f]{32})\.txt$') {
            $id = $Matches[1]
            if ((Get-DoneState $id).State -ne 'valid') { $ids += $id }
        }
    }
    return $ids
}

# Where an unfinished run stands, judged from its manifest and the disk.
# Nothing is moved here.
#   settled  nothing of the run is left in the data path;
#   pending  a backup or the marked test directory of the run is there: the
#            restore knows what to do with it;
#   problem  the data path holds a directory that can be proven to be
#            neither the test directory of the run nor the original data.
function Get-RunState([string]$Id) {
    $manifest = Read-Manifest $Id
    if (-not $manifest.Ok) {
        return [pscustomobject]@{ State = 'problem'; Id = $Id; Text = "run $Id changed the data path and was not finished, and $($manifest.Error)" }
    }
    $data = $manifest.Data
    if (-not (Test-SamePath $data['root'] $Root)) {
        return [pscustomobject]@{ State = 'settled'; Id = $Id; Text = 'another data directory' }
    }
    $rootExists = Test-Path -LiteralPath $Root
    $rootId = $null
    if ($rootExists) { $rootId = Get-SentinelId $Root }
    $stageLeft = $data.ContainsKey('stage') -and (Test-Path -LiteralPath $data['stage'])

    if ($data['backup'] -ne 'none') {
        if (Test-Path -LiteralPath $data['backup']) { return [pscustomobject]@{ State = 'pending'; Id = $Id; Text = 'the backup exists' } }
        if (-not $rootExists) {
            return [pscustomobject]@{ State = 'problem'; Id = $Id; Text = "run $Id renamed the data directory to $($data['backup']), but neither that backup nor $Root exists" }
        }
        if ($rootId -eq $Id) {
            return [pscustomobject]@{ State = 'problem'; Id = $Id; Text = "the test directory of run $Id is at $Root, but the backup $($data['backup']) named by its manifest is not there" }
        }
        if ($null -eq $rootId) {
            # No sentinel: the original data, put back, or the test directory that lost its sentinel?
            $now = $null
            try { $now = Get-TreeFingerprint $Root } catch { $now = $null }
            if ($null -ne $now -and "$($now.Entries)" -eq $data['entries'] -and $now.Digest -eq $data['digest']) {
                return [pscustomobject]@{ State = 'settled'; Id = $Id; Text = 'the data directory matches the fingerprint of the manifest' }
            }
            return [pscustomobject]@{ State = 'problem'; Id = $Id; Text = "run $Id was not finished: the directory at $Root has no sentinel and does not match the fingerprint of the original data (names, types, sizes), so it is not known whether it is your data or the test directory" }
        }
        return [pscustomobject]@{ State = 'problem'; Id = $Id; Text = "run $Id was not finished: the directory at $Root carries a sentinel that is damaged or of another run" }
    }

    # The run found no data directory.
    if (-not $rootExists) { return [pscustomobject]@{ State = 'settled'; Id = $Id; Text = 'the data path is empty' } }
    if ($stageLeft) { return [pscustomobject]@{ State = 'settled'; Id = $Id; Text = 'the test directory never took the place' } }
    if ($rootId -eq $Id) { return [pscustomobject]@{ State = 'pending'; Id = $Id; Text = 'the marked test directory is in place' } }
    $what = 'has no sentinel'
    if ($null -ne $rootId) { $what = 'carries a sentinel that is damaged or of another run' }
    return [pscustomobject]@{ State = 'problem'; Id = $Id; Text = "run $Id put its test directory at $Root (there was no data directory before it) and was not finished; the directory that is there now $what, so it cannot be proven to be that test directory" }
}

# The problems of the unfinished runs. With -Close, runs that are settled
# get their "done" marker. Throws when the markers cannot be listed.
function Get-RunProblems([switch]$Close) {
    $problems = @()
    # A file that claims to be a "done" marker and is not one is a problem of
    # its own: it is reported, never repaired, and its run is not closed.
    $badIds = @()
    foreach ($bad in @(Get-InvalidDoneMarkers)) {
        $whose = 'of no known run'
        if ($bad.Id) { $whose = "of run $($bad.Id)"; $badIds += $bad.Id }
        $problems += [pscustomobject]@{ State = 'problem'; Id = $bad.Id; Text = "the file $($bad.Path) $whose is not a valid `"done`" marker: $($bad.Reason). It was not changed, and the run is not taken as finished" }
    }
    foreach ($id in @(Get-TouchedRuns)) {
        if ($badIds -contains $id) { continue }
        $state = Get-RunState $id
        if ($state.State -eq 'problem') { $problems += $state }
        elseif ($state.State -eq 'settled' -and $Close) { Write-DoneMarker $id }
    }
    return $problems
}

# ---------------------------------------------------------------------------
# Safety: processes
# ---------------------------------------------------------------------------

# Every process with its name and command line. Throws when the list cannot
# be had: then nothing is known and nothing may be changed.
function Get-ProcessSnapshot {
    if ($TestBase) {
        $file = Join-Path $TestBase 'processes.txt'
        $list = @()
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($file)) {
                if ($line -eq '!error') { throw 'injected test fault: the process list is not available' }
                $parts = $line.Split('|')
                if ($parts.Count -lt 3) { continue }
                $command = $parts[2]
                if ($command -eq '<unreadable>') { $command = $null }
                $list += [pscustomobject]@{ Id = $parts[0]; Name = $parts[1]; CommandLine = $command }
            }
        }
        return $list
    }
    if ($OnWindows) {
        return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            ForEach-Object { [pscustomobject]@{ Id = $_.ProcessId; Name = $_.Name; CommandLine = $_.CommandLine } })
    }
    # Not Windows: only so that the script itself can be exercised.
    return @(Get-Process -ErrorAction Stop |
        ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.ProcessName; CommandLine = $_.CommandLine } })
}

# Processes that work with the data directory of ATLAS:
#   App      the application itself (by the name of its executable);
#   WebView  WebView2 processes whose command line names the data directory
#            or the executable of ATLAS;
#   Unknown  WebView2 processes whose command line cannot be read, so that
#            it is not known whose they are.
# WebView2 processes of other applications are in none of the three.
function Get-Blocking {
    $names = @('atlas')
    if ($Exe) {
        $own = [System.IO.Path]::GetFileNameWithoutExtension($Exe)
        if ($own -and ($names -notcontains $own)) { $names += $own }
    }
    $app = @(); $web = @(); $unknown = @()
    foreach ($process in @(Get-ProcessSnapshot)) {
        $name = "$($process.Name)"
        if ($name.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { $name = $name.Substring(0, $name.Length - 4) }
        if ($names -contains $name) { $app += $process; continue }
        if ($name -ne 'msedgewebview2') { continue }
        $command = $process.CommandLine
        if ([string]::IsNullOrEmpty($command)) { $unknown += $process; continue }
        if ($command.IndexOf($Root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $web += $process; continue }
        foreach ($candidate in $names) {
            if ($command.IndexOf("--webview-exe-name=$candidate.exe", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $web += $process
                break
            }
        }
    }
    return [pscustomobject]@{ App = $app; WebView = $web; Unknown = $unknown }
}

function Format-Processes($List) {
    return (@($List | ForEach-Object { "$($_.Name) (id $($_.Id))" }) -join ', ')
}

# Throws unless it is certain that nothing of ATLAS is running. Never ends a
# process.
function Assert-NoBlockingProcess {
    try { $blocking = Get-Blocking }
    catch { throw "The list of processes cannot be read ($($_.Exception.Message)), so it is not known whether ATLAS is running. Nothing was changed." }
    if (@($blocking.App).Count -gt 0) {
        throw "ATLAS is running: $(Format-Processes $blocking.App). Close it and start the script again. Nothing was changed."
    }
    if (@($blocking.WebView).Count -gt 0) {
        throw "WebView2 processes of ATLAS are still running: $(Format-Processes $blocking.WebView). Wait until they end (or sign out and in again) and start the script again. Nothing was changed."
    }
    if (@($blocking.Unknown).Count -gt 0) {
        throw "It cannot be told whose these WebView2 processes are: $(Format-Processes $blocking.Unknown). Close the applications they belong to (or sign out other users) and start the script again. Nothing was changed."
    }
}

# Waits until it is certain that nothing of ATLAS is running: no application,
# no WebView2 process of it and no WebView2 process whose owner is unknown.
# Returns $false on timeout and when the processes cannot be listed: then
# the end of ATLAS is NOT confirmed. $script:StillRunning says what was seen.
function Wait-AppGone([int]$Seconds) {
    if ($TestBase) { $Seconds = 1 }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        try {
            $blocking = Get-Blocking
            $left = @($blocking.App) + @($blocking.WebView) + @($blocking.Unknown)
            if ($left.Count -eq 0) {
                $script:StillRunning = ''
                return $true
            }
            $script:StillRunning = Format-Processes $left
            if (@($blocking.Unknown).Count -gt 0) { $script:StillRunning += ' (WebView2 with an unreadable command line: owner unknown)' }
        } catch {
            $script:StillRunning = "the list of processes cannot be read: $($_.Exception.Message)"
            return $false
        }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 500
    }
}

# ---------------------------------------------------------------------------
# Safety: isolation of the real data directory and its restore
# ---------------------------------------------------------------------------

function Write-RestoreInstructions([string]$Why) {
    # The runs that are not finished, with their ids and manifests.
    $runLines = @()
    try {
        $open = @(Get-TouchedRuns)
        if ($open.Count -gt 0) {
            $runLines += ''
            $runLines += 'Runs of the script that changed the data path and are not finished:'
            foreach ($id in $open) {
                $runLines += "  run id $id"
                $runLines += "    manifest: $(Join-Path $StateDir "manifest-$id.txt")"
            }
            $runLines += "The script moves a directory out of '$Root' only when it holds the file"
            $runLines += "'$SentinelName' with the run id of such a run. A directory without that"
            $runLines += 'file, or with a damaged one, is NOT moved, deleted or overwritten'
            $runLines += 'automatically: it may be your data. Look into it yourself:'
            $runLines += '  - it is leftovers of the test (a fresh atlas.db, logs of the test run):'
            $runLines += "    move it away by hand, then run the script with -RestoreOnly;"
            $runLines += '  - it is your data, you have checked that, and nothing else has to come'
            $runLines += '    back: close the run by hand with its "done" marker (see below) and run'
            $runLines += '    the script with -RestoreOnly to check;'
            $runLines += '  - you cannot tell what the directory is: do NOT create the marker. Keep'
            $runLines += '    everything as it is and compare the directory with the backup first.'
            $runLines += ''
            $runLines += 'Closing a run by hand. The "done" marker only tells the script that this one'
            $runLines += 'run is finished. It repairs nothing and restores nothing. Create it only'
            $runLines += "after you have looked at '$Root' and at the backups and know that your data"
            $runLines += 'is where it belongs. The command writes exactly what the script checks:'
            foreach ($id in $open) {
                $target = Get-MarkerPath 'done' $id
                $runLines += "  run $id"
                $runLines += ('    $id = ' + "'$id'" + '; [System.IO.File]::WriteAllLines(' + "'$target'" + ', [string[]]@(' + "'$DoneFormatLine'" + ", 'kind=done', " + '"run_id=$id", (' + "'written='" + " + (Get-Date -Format 'yyyyMMdd-HHmmss')), " + '"end=$id"))')
            }
        }
        $invalid = @(Get-InvalidDoneMarkers)
        if ($invalid.Count -gt 0) {
            $runLines += ''
            $runLines += 'Files that are named like a "done" marker and are NOT valid markers. The'
            $runLines += 'script did not change them and will not: it stops with exit code 3 until'
            $runLines += 'you have dealt with them.'
            foreach ($bad in $invalid) {
                $runLines += "  $($bad.Path)"
                if ($bad.Id) { $runLines += "    run id: $($bad.Id)" }
                $runLines += "    reason: $($bad.Reason)"
                $runLines += "    Check the directories first. Then move the file aside, for example"
                $runLines += "        Rename-Item -LiteralPath '$($bad.Path)' -NewName 'invalid-$(Split-Path -Leaf $bad.Path)'"
                if ($bad.Id) { $runLines += '    and, if the run really is finished, write the marker with the command above.' }
            }
        }
    } catch {
        $runLines += ''
        $runLines += "Unfinished runs: NOT KNOWN, $StateDir could not be listed ($($_.Exception.Message))."
    }
    $backupLines = @('  (no backup directory found)')
    try {
        $backups = @(Get-LeftoverBackup | ForEach-Object { $_.FullName })
        if ($backups.Count -gt 0) { $backupLines = @($backups | ForEach-Object { "  $_" }) }
    } catch {
        $backupLines = @(
            "  NOT KNOWN: $LocalAppData could not be listed ($($_.Exception.Message)).",
            "  Look there yourself for directories named $AppId$BackupInfix<time>-<id>.")
    }
    $text = @(
        'ATLAS SQLite foundation check: manual action is needed.',
        "Reason: $Why",
        '',
        "Data directory of ATLAS: $Root",
        'Backup(s) of your original data (never deleted by the script):'
    ) + $backupLines + @(
        "Manifests of the runs:   $StateDir",
        "Report directory:        $Report",
        "Run id of this run:      $RunId"
    ) + $runLines + @(
        '',
        'Nothing was deleted. To restore by hand:',
        '  1. Close every ATLAS window. In Task Manager end atlas.exe; wait until',
        '     the msedgewebview2.exe processes that belong to it are gone.',
        "  2. Look at '$Root'.",
        "     - It contains the file '$SentinelName': it is a test directory of",
        '       the script. Move it away, for example:',
        "           Move-Item -LiteralPath '$Root' -Destination '$Report\test-root-manual'",
        "     - It exists WITHOUT '$SentinelName': do not touch it. Compare it with",
        '       the backup first and decide which one holds your data.',
        '     - It does not exist: go on with step 3.',
        '  3. Put the backup back. The backup that belongs to a test directory has',
        "     the same run id at the end of its name as 'run_id=' in '$SentinelName'",
        '     and as its manifest-<id>.txt:',
        "           Rename-Item -LiteralPath '<backup directory>' -NewName '$AppId'",
        '',
        'Or, once the reason above is removed, run the script with -RestoreOnly: it',
        'does steps 2 and 3 only when the run ids and the manifest agree.'
    )
    $path = Join-Path $Report 'RESTORE-INSTRUCTIONS.txt'
    if (Test-Path -LiteralPath $path) { $path = Join-Path $Report "RESTORE-INSTRUCTIONS-$([guid]::NewGuid().ToString('N').Substring(0, 8)).txt" }
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8
    $script:ManualSteps = "see $path"
    Write-Host ''
    $text | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
}

# Takes the test directory of run $Id out of the data path: into the report,
# or, if that fails, renamed aside. Returns $false when it is still there.
function Remove-TestCopyFromRoot([string]$Id) {
    if ((Get-SentinelId $Root) -ne $Id) {
        $script:LastProblem = "$Root is not the test directory of run $Id"
        return $false
    }
    $target = Join-Path $Report 'test-root'
    if (Test-Path -LiteralPath $target) { $target = Join-Path $Report "test-root-$Id" }
    try {
        Invoke-Fault 'test-root-move'
        Move-Directory $Root $target
        $script:TestWhere = $target
        Write-Note "Test directory moved to $target"
        return $true
    } catch {
        $first = $_.Exception.Message
        # For example the report is on another drive. A rename in place needs no copy.
        $aside = "$Root$StageInfix$Stamp-$Id-aside"
        try {
            Invoke-Fault 'test-root-aside'
            if (Test-Path -LiteralPath $aside) { throw "$aside already exists" }
            if ((Get-SentinelId $Root) -ne $Id) { throw 'the test directory is no longer whole' }
            Rename-Item -LiteralPath $Root -NewName (Split-Path -Leaf $aside) -ErrorAction Stop
            $script:TestWhere = $aside
            Write-Note "Test directory renamed to $aside (it could not be moved into the report: $first)"
            return $true
        } catch {
            $script:TestWhere = $Root
            $script:LastProblem = "the test directory could not be moved away: $first; $($_.Exception.Message)"
            return $false
        }
    }
}

# Renames a backup back to the data path. Returns $false when the original
# data is not in its place afterwards.
function Restore-Backup([string]$BackupPath, $Expected) {
    $script:OriginalWhere = $BackupPath
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
        $script:OriginalWhere = 'unknown'
        $script:LastProblem = "the backup $BackupPath is not where it was left"
        return $false
    }
    if (Test-Path -LiteralPath $Root) {
        $script:LastProblem = "$Root is occupied; the backup was not moved over it"
        return $false
    }
    # Only for the tests: something changes the backup at the last moment.
    if ($TestBase -and ($Faults -contains 'tamper-backup')) {
        [System.IO.File]::WriteAllText((Join-Path $BackupPath 'added-by-the-fault.txt'), 'x')
    }
    # The backup is compared with the fingerprint BEFORE it is moved. The
    # fingerprint covers names, types and sizes, not the contents of files.
    if ($null -eq $Expected) {
        $script:LastProblem = "there is no fingerprint to check the backup $BackupPath against; it was not moved"
        return $false
    }
    $found = $null
    try { $found = Get-TreeFingerprint $BackupPath }
    catch {
        $script:LastProblem = "the backup $BackupPath cannot be read ($($_.Exception.Message)); it was not moved"
        return $false
    }
    if ("$($found.Entries)" -ne "$($Expected.Entries)" -or $found.Digest -ne $Expected.Digest) {
        $script:LastProblem = "the backup $BackupPath does not match the fingerprint taken before the run (names, types or sizes changed); it was not moved and the data path was left empty"
        return $false
    }
    try {
        Invoke-Fault 'backup-restore'
        Rename-Item -LiteralPath $BackupPath -NewName $AppId -ErrorAction Stop
    } catch {
        $script:LastProblem = "the backup could not be renamed back: $($_.Exception.Message)"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container) -or (Test-Path -LiteralPath $BackupPath)) {
        $script:OriginalWhere = 'unknown'
        $script:LastProblem = 'the rename back could not be verified'
        return $false
    }
    # Only for the tests: something changes the directory right after the rename.
    if ($TestBase -and ($Faults -contains 'tamper-after-restore')) {
        [System.IO.File]::WriteAllText((Join-Path $Root 'added-after-restore.txt'), 'x')
    }
    # Checked once more after the rename. Until this check passes the restore
    # is not confirmed, and a failed check is a failed restore.
    $now = $null
    $checkError = ''
    try {
        if ($TestBase -and ($Faults -contains 'postcheck-error')) { throw 'injected test fault: the restored directory cannot be read' }
        $now = Get-TreeFingerprint $Root
    } catch {
        $now = $null
        $checkError = $_.Exception.Message
    }
    if ($null -eq $now -or "$($now.Entries)" -ne "$($Expected.Entries)" -or $now.Digest -ne $Expected.Digest) {
        $how = 'does not match the fingerprint taken before the run (names, types or sizes differ)'
        if ($null -eq $now) { $how = "could not be checked against the fingerprint taken before the run ($checkError)" }
        $script:OriginalWhere = "$Root (moved back from $BackupPath; fingerprint NOT confirmed)"
        $script:OriginalInPlace = $false
        $script:LastProblem = "the backup was ALREADY renamed back to $Root, but the directory $how. The restore is NOT confirmed. The directory at $Root was not moved, deleted or overwritten and no backup directory of it is left: look into $Root yourself. When it is in order, run the script with -RestoreOnly: it checks the fingerprint again and moves nothing"
        Write-Note "The data directory was renamed back to $Root, but the check after the rename FAILED."
        return $false
    }
    $script:OriginalWhere = $Root
    $script:OriginalInPlace = $true
    Write-Note "Original data directory restored: $Root"
    Write-Note 'The restored directory matches the fingerprint taken before the run (names, types and sizes; contents are not compared).'
    return $true
}

function Enter-Isolation {
    # Never isolate the data for an application that cannot be started.
    if ((-not $TestBase -or $Exe) -and (-not $Exe -or -not (Test-Path -LiteralPath $Exe -PathType Leaf))) {
        throw "The application is not there ('$Exe'). Nothing was changed."
    }
    Assert-NoBlockingProcess
    try { $leftovers = @(Get-LeftoverBackup) }
    catch { throw "$LocalAppData cannot be listed ($($_.Exception.Message)), so it is not known whether a backup of an earlier run exists. Nothing was changed." }
    if ($leftovers.Count -gt 0) {
        $names = ($leftovers | ForEach-Object { $_.FullName }) -join '; '
        throw "A previous run of this script was not restored: $names. Run the script with -RestoreOnly first. Nothing was changed."
    }
    # A run that changed the data path and was not finished: the directory
    # there may be its test directory without a sentinel. It must not be
    # taken for the data of the user.
    try { $unfinished = @(Get-RunProblems -Close) }
    catch { throw "The markers of earlier runs in $StateDir cannot be read ($($_.Exception.Message)). Nothing was changed." }
    if ($unfinished.Count -gt 0) {
        throw "An earlier run of this script is not finished: $(@($unfinished | ForEach-Object { $_.Text }) -join '; '). Run the script with -RestoreOnly first. Nothing was changed."
    }
    if (Test-Path -LiteralPath $Root) {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
            throw "$Root is not a directory. Nothing was changed."
        }
        if ($null -ne (Get-SentinelId $Root)) {
            throw "A test directory of a previous run is still at $Root. Run the script with -RestoreOnly first. Nothing was changed."
        }
        $script:HadOriginal = $true
        $script:Fingerprint = Get-TreeFingerprint $Root
        $script:OriginalWhere = $Root
        $script:OriginalInPlace = $true
        Write-Note "Existing data directory found: $($script:Fingerprint.Entries) entries."
    } else {
        $script:OriginalWhere = 'none existed before the run'
        $script:OriginalInPlace = $true
        Write-Note 'No existing data directory: nothing to back up.'
    }
    foreach ($taken in @($Backup, $Stage, $ManifestPath)) {
        if (Test-Path -LiteralPath $taken) { throw "The name $taken is already taken. Nothing was changed." }
    }

    # 1. The manifest, before anything is renamed.
    $backupField = 'none'
    $entries = '0'
    $digest = 'none'
    if ($script:HadOriginal) {
        $backupField = $Backup
        $entries = "$($script:Fingerprint.Entries)"
        $digest = $script:Fingerprint.Digest
    }
    $body = @(
        'format=1',
        "run_id=$RunId",
        "created=$Stamp",
        "root=$Root",
        "backup=$backupField",
        "entries=$entries",
        "digest=$digest",
        "stage=$Stage",
        "report=$Report"
    )
    try {
        Invoke-Fault 'manifest-write'
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -ErrorAction Stop | Out-Null }
        Write-NewFile $ManifestPath ($body + @("check=$(Get-TextSha ($body -join "`n"))"))
    } catch {
        throw "The manifest could not be written ($($_.Exception.Message)). Nothing was changed."
    }
    $script:ManifestWritten = $true
    $manifest = Read-Manifest $RunId
    if (-not $manifest.Ok) { throw "The manifest does not read back: $($manifest.Error). The data directory was not touched." }
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $Report 'manifest-copy.txt')
    Write-Note "Run id $RunId; manifest $ManifestPath"

    # 2. The test directory, prepared and marked next to the data directory.
    $script:StageTried = $true
    Invoke-Fault 'stage-create'
    New-Item -ItemType Directory -Path $Stage -ErrorAction Stop | Out-Null
    Invoke-Fault 'sentinel-write'
    Write-NewFile (Join-Path $Stage $SentinelName) @(
        'Test directory of tools/windows/sqlite-foundation-check.ps1',
        "run_id=$RunId",
        "created=$Stamp")
    if ((Get-SentinelId $Stage) -ne $RunId) { throw 'The sentinel of the test directory does not read back. The data directory was not touched.' }

    # From here on the data path is changed: that is recorded first.
    Invoke-Fault 'touched-write'
    Write-Marker 'touched' $RunId
    $script:Touched = $true

    # 3. The original data directory goes aside.
    if ($script:HadOriginal) {
        Assert-NoBlockingProcess
        Invoke-Fault 'backup-rename'
        Write-Note "Renaming the data directory to $Backup"
        $script:RenameTried = $true
        $script:OriginalInPlace = $false
        $script:OriginalWhere = "$Root or $Backup"
        Rename-Item -LiteralPath $Root -NewName (Split-Path -Leaf $Backup) -ErrorAction Stop
        Invoke-Fault 'crash-after-backup'
        if ((Test-Path -LiteralPath $Root) -or -not (Test-Path -LiteralPath $Backup -PathType Container)) {
            throw "The rename could not be verified. No test is run."
        }
        $script:OriginalWhere = $Backup
        Invoke-Fault 'backup-verify'
        $after = Get-TreeFingerprint $Backup
        if ($after.Entries -ne $script:Fingerprint.Entries -or $after.Digest -ne $script:Fingerprint.Digest) {
            throw 'The backup does not match the fingerprint taken before the rename. No test is run; the directory is put back.'
        }
        Write-Note 'Backup verified against the fingerprint.'
    }

    # 4. The marked test directory takes the place.
    $script:ActivateTried = $true
    Invoke-Fault 'stage-move'
    Rename-Item -LiteralPath $Stage -NewName $AppId -ErrorAction Stop
    Assert-TestRoot
    $script:TestWhere = $Root
    Write-Note "Isolated test directory in place: $Root"
    Invoke-Fault 'crash-after-isolation'
}

# Undoes Enter-Isolation, whatever step it reached. Returns $true when the
# original data is in its place (or there was none).
function Exit-Isolation {
    # Only processes this script started are ended.
    foreach ($process in @($script:Started)) {
        try {
            if (-not $process.HasExited) {
                Write-Note "Ending a leftover ATLAS process $($process.Id)"
                $process.Kill()
                [void]$process.WaitForExit(10000)
            }
        } catch { Write-Note "Could not end process: $($_.Exception.Message)" }
    }
    # The manifest set of this run says whether its test directory took the
    # data path: "touched" is written and the prepared directory has left its
    # place. If so, what is in the data path must carry the sentinel of this
    # run. Without it nothing is moved: the directory may be anything.
    $installed = $script:ActivateTried -and (Test-Path -LiteralPath (Get-MarkerPath 'touched' $RunId)) -and -not (Test-Path -LiteralPath $Stage)
    if ($installed -and (Test-Path -LiteralPath $Root) -and ((Get-SentinelId $Root) -ne $RunId)) {
        $script:OriginalInPlace = $false
        if ($script:HadOriginal) {
            if (Test-Path -LiteralPath $Backup) { $script:OriginalWhere = $Backup } else { $script:OriginalWhere = 'unknown' }
        } else { $script:OriginalWhere = 'none existed before the run' }
        $script:TestWhere = "$Root ? (the sentinel of run $RunId is missing or damaged: not confirmed)"
        Write-RestoreInstructions "run $RunId put its test directory at $Root, but the directory that is there now does not carry the sentinel of this run (it is missing, damaged or of another run). It cannot be proven to be the test directory, so it was not moved or deleted, and no backup was moved over it."
        return $false
    }

    # Nothing in the data path is moved while a process may still work with
    # it. Processes the script did not start are never ended: it only waits.
    $testInPlace = (Test-Path -LiteralPath $Root) -and ((Get-SentinelId $Root) -eq $RunId)
    $backupExists = Test-Path -LiteralPath $Backup
    if (($testInPlace -or $backupExists) -and -not (Wait-AppGone 30)) {
        if ($backupExists) { $script:OriginalWhere = $Backup }
        if ($testInPlace) { $script:TestWhere = $Root }
        $script:OriginalInPlace = $false
        Write-RestoreInstructions "it cannot be confirmed that every ATLAS and WebView2 process has ended: $($script:StillRunning). Nothing was moved: the backup and the test directory are where they were. Close these processes (the script does not end them), then run the script with -RestoreOnly."
        return $false
    }

    # The test directory, if it is in the data path.
    if (Test-Path -LiteralPath $Root) {
        $rootId = Get-SentinelId $Root
        if ($rootId -eq $RunId) {
            if (-not (Remove-TestCopyFromRoot $RunId)) {
                Write-RestoreInstructions $script:LastProblem
                return $false
            }
        } elseif (Test-Path -LiteralPath $Backup) {
            Write-RestoreInstructions "$Root exists but is not the test directory of this run; it was left untouched."
            return $false
        }
        # Otherwise it is the original that never left, checked below.
    }
    # The prepared test directory, if it never took the place.
    if (Test-Path -LiteralPath $Stage) {
        $target = Join-Path $Report 'test-stage'
        try {
            Move-Directory $Stage $target
            $script:TestWhere = $target
        } catch {
            $script:TestWhere = $Stage
            Write-Note "The prepared test directory stays at $Stage (it is not in the data path)."
        }
    }

    # The original.
    if (Test-Path -LiteralPath $Backup) {
        if (-not (Restore-Backup $Backup $script:Fingerprint)) {
            Write-RestoreInstructions $script:LastProblem
            return $false
        }
        return $true
    }
    if (-not $script:HadOriginal) {
        $script:OriginalWhere = 'none existed before the run'
        $script:OriginalInPlace = $true
        return $true
    }
    # There was an original and no backup exists: it must still be in place.
    if ((Test-Path -LiteralPath $Root -PathType Container) -and ($null -eq (Get-SentinelId $Root))) {
        $script:OriginalWhere = "$Root (never moved)"
        $script:OriginalInPlace = $true
        $now = $null
        try { $now = Get-TreeFingerprint $Root } catch { $now = $null }
        if ($null -eq $now -or $now.Digest -ne $script:Fingerprint.Digest) {
            [void]$script:Warnings.Add("The data directory does not match the fingerprint taken at the start (names and sizes). Look at $Root.")
        }
        return $true
    }
    $script:OriginalWhere = 'unknown'
    $script:OriginalInPlace = $false
    Write-RestoreInstructions "the original data directory is neither at $Root nor at $Backup."
    return $false
}

# -RestoreOnly: puts back what an interrupted run left. Moves something only
# when the run ids and the manifest prove what belongs together. Returns the
# exit code.
function Invoke-RestoreOnly {
    try { $backups = @(Get-LeftoverBackup) }
    catch {
        $script:OriginalInPlace = $false
        $script:OriginalWhere = "not known: $LocalAppData could not be listed"
        Write-RestoreInstructions "$LocalAppData cannot be listed ($($_.Exception.Message)), so it is not known whether a backup exists. Nothing was moved."
        return 3
    }
    # A file that is named like a "done" marker and is not one stops the
    # restore before anything is moved, whatever else is on the disk.
    $invalidDone = @(Get-InvalidDoneMarkers)
    if ($invalidDone.Count -gt 0) {
        $script:OriginalInPlace = $false
        $script:OriginalWhere = 'not confirmed'
        if ($backups.Count -ge 1) { $script:OriginalWhere = (@($backups | ForEach-Object { $_.FullName }) -join '; ') }
        $what = @($invalidDone | ForEach-Object { 'the file ' + $_.Path + ' is not a valid "done" marker (' + $_.Reason + ')' }) -join '; '
        Write-RestoreInstructions "$what. Nothing was moved and the file was not changed."
        return 3
    }
    $rootExists = Test-Path -LiteralPath $Root
    $rootId = $null
    if ($rootExists) { $rootId = Get-SentinelId $Root }

    if ($backups.Count -eq 0 -and $null -eq $rootId) {
        # No backup and no sentinel is not yet "nothing to restore": a run
        # that was not finished may have left its test directory unmarked.
        $unfinished = @(Get-RunProblems -Close)
        if ($unfinished.Count -gt 0) {
            $script:OriginalInPlace = $false
            $script:OriginalWhere = 'not confirmed'
            if ($rootExists) { $script:TestWhere = "$Root ? (not confirmed)" }
            Write-RestoreInstructions "$(@($unfinished | ForEach-Object { $_.Text }) -join '; '). Nothing was moved."
            return 3
        }
        if ($rootExists) { $script:OriginalWhere = "$Root (in place)" } else { $script:OriginalWhere = 'no data directory exists' }
        $script:OriginalInPlace = $true
        Write-Note 'Nothing to restore: no backup, no test directory and no unfinished run.'
        return 0
    }

    $script:OriginalInPlace = $false
    $script:OriginalWhere = 'unknown'
    if ($backups.Count -ge 1) { $script:OriginalWhere = (@($backups | ForEach-Object { $_.FullName }) -join '; ') }
    if ($null -ne $rootId) { $script:TestWhere = $Root }

    $stop = $null
    $backupPath = $null
    $expected = $null
    $moveTestId = $null
    if ($backups.Count -gt 1) {
        $stop = 'more than one backup directory exists; the script does not guess which one to put back'
    } else {
        try { Assert-NoBlockingProcess } catch { $stop = $_.Exception.Message -replace ' Nothing was changed\.$', '' }
    }
    if (-not $stop -and $backups.Count -eq 0) {
        # Only a test directory.
        if ($rootId -eq '?') { $stop = "the sentinel in $Root cannot be read, so the run it belongs to is not known" }
        else {
            $manifest = Read-Manifest $rootId
            if (-not $manifest.Ok) { $stop = $manifest.Error }
            elseif (-not (Test-SamePath $manifest.Data['root'] $Root)) { $stop = "the manifest $($manifest.Path) is for another data directory" }
            elseif ($manifest.Data['backup'] -ne 'none') { $stop = "the manifest says the original data was renamed to $($manifest.Data['backup']), but no backup directory is there" }
            else { $moveTestId = $rootId }
        }
    }
    if (-not $stop -and $backups.Count -eq 1) {
        $backupPath = $backups[0].FullName
        $backupId = Get-BackupRunId $backups[0].Name
        if ($null -eq $backupId) { $stop = "the backup $backupPath carries no run id in its name (made by another version of the script?)" }
        else {
            $manifest = Read-Manifest $backupId
            if (-not $manifest.Ok) { $stop = $manifest.Error }
            elseif (-not (Test-SamePath $manifest.Data['root'] $Root)) { $stop = "the manifest $($manifest.Path) is for another data directory" }
            elseif (-not (Test-SamePath $manifest.Data['backup'] $backupPath)) { $stop = "the manifest $($manifest.Path) names another backup" }
            else {
                $now = $null
                try { $now = Get-TreeFingerprint $backupPath } catch { $now = $null }
                if ($null -eq $now) { $stop = "the backup $backupPath cannot be read" }
                elseif ("$($now.Entries)" -ne $manifest.Data['entries'] -or $now.Digest -ne $manifest.Data['digest']) {
                    $stop = "the backup $backupPath does not match the fingerprint in its manifest (names and sizes changed)"
                } else {
                    # Restore-Backup compares the backup with the manifest once more, right before the rename.
                    $expected = [pscustomobject]@{ Entries = $manifest.Data['entries']; Digest = $manifest.Data['digest'] }
                    if ($rootExists) {
                        if ($null -eq $rootId) { $stop = "$Root is occupied by a directory without $SentinelName; it may be data, so it is not touched" }
                        elseif ($rootId -ne $backupId) { $stop = "the test directory at $Root (run $rootId) and the backup (run $backupId) are from different runs" }
                        else { $moveTestId = $rootId }
                    }
                }
            }
        }
    }
    if ($stop) {
        Write-RestoreInstructions "$stop. Nothing was moved."
        return 3
    }

    if ($moveTestId) {
        if (-not (Remove-TestCopyFromRoot $moveTestId)) {
            Write-RestoreInstructions "$($script:LastProblem). The backup was not touched."
            return 3
        }
    }
    if ($backupPath) {
        if (-not (Restore-Backup $backupPath $expected)) {
            Write-RestoreInstructions $script:LastProblem
            return 3
        }
    } else {
        $script:OriginalWhere = 'none existed before that run'
        $script:OriginalInPlace = $true
    }
    # The runs that are settled now get their "done" marker; one that is not
    # keeps the restore from reporting success.
    $unfinished = @(Get-RunProblems -Close)
    if ($unfinished.Count -gt 0) {
        $script:OriginalInPlace = $false
        Write-RestoreInstructions "$(@($unfinished | ForEach-Object { $_.Text }) -join '; ')."
        return 3
    }
    Write-Note 'Restore finished.'
    return 0
}

# The outcome of a run that changed nothing itself: is the data in its place,
# or did an earlier run leave it renamed?
function Set-OutcomeFromDisk {
    try { $backups = @(Get-LeftoverBackup | ForEach-Object { $_.FullName }) }
    catch {
        # Not known is not "in place": the run ends with exit code 3.
        $script:OriginalInPlace = $false
        $script:OriginalWhere = "not known: $LocalAppData could not be listed ($($_.Exception.Message))"
        $script:ManualSteps = "look at $LocalAppData yourself: this run changed nothing, but it could not check for a backup of an earlier run"
        return
    }
    $rootId = $null
    $rootExists = Test-Path -LiteralPath $Root
    if ($rootExists) { $rootId = Get-SentinelId $Root }
    if ($backups.Count -eq 0 -and $null -eq $rootId) {
        $unfinished = $null
        try { $unfinished = @(Get-RunProblems) } catch { $unfinished = $null }
        if ($null -eq $unfinished -or $unfinished.Count -gt 0) {
            $script:OriginalInPlace = $false
            $script:OriginalWhere = 'not confirmed: an earlier run of the script is not finished'
            if ($rootExists) { $script:TestWhere = "$Root ? (not confirmed)" }
            $script:ManualSteps = 'an earlier run was not finished: run the script with -RestoreOnly and follow its instructions'
            return
        }
        $script:OriginalInPlace = $true
        if ($rootExists) { $script:OriginalWhere = "$Root (in place, not touched)" }
        else { $script:OriginalWhere = 'no data directory exists' }
        return
    }
    $script:OriginalInPlace = $false
    $script:OriginalWhere = 'unknown'
    if ($backups.Count -gt 0) { $script:OriginalWhere = ($backups -join '; ') }
    if ($null -ne $rootId) { $script:TestWhere = $Root }
    $script:ManualSteps = 'an earlier run was not restored: run the script with -RestoreOnly'
}

# Where everything is, at the end of every run.
function Write-Outcome {
    $inPlace = 'NO'
    if ($script:OriginalInPlace) { $inPlace = 'yes' }
    $aside = @()
    $asideError = $null
    try {
        $aside = @(Get-ChildItem -LiteralPath $LocalAppData -Directory -Force -ErrorAction Stop |
            Where-Object { $_.Name.StartsWith("$AppId$StageInfix") } | ForEach-Object { $_.FullName })
    } catch { $asideError = $_.Exception.Message }
    $lines = @(
        "original data:           $($script:OriginalWhere)",
        "original path restored:  $inPlace",
        "test copy:               $($script:TestWhere)",
        "manual steps:            $($script:ManualSteps)"
    )
    foreach ($warning in @($script:Warnings)) { $lines += "WARNING: $warning" }
    if ($aside.Count -gt 0) { $lines += "test directories set aside (not in the data path, safe to delete by hand): $($aside -join '; ')" }
    if ($asideError) { $lines += "test directories set aside: NOT KNOWN, $LocalAppData could not be listed ($asideError)" }
    Set-Content -LiteralPath (Join-Path $Report 'outcome.txt') -Value $lines -Encoding UTF8
    Write-Host ''
    $lines | ForEach-Object { Write-Host $_ }
}

# ---------------------------------------------------------------------------
# Finding the application
# ---------------------------------------------------------------------------

# A path as the platform writes it. Only for exercising the script outside
# Windows, where the application has no .exe and paths use '/'.
function ConvertTo-PlatformPath([string]$Path) {
    if ($OnWindows) { return $Path }
    return ($Path -replace '\\', '/' -replace '\.exe$', '')
}

function Test-Interactive {
    if ($TestBase) { return $false }
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { return $false }
}

# A JSON file as an object. Throws, with the reason, when it is missing,
# unreadable, not JSON or not a JSON object.
function Read-JsonObject([string]$Path, [string]$What) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$What is missing" }
    $text = $null
    try { $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
    catch { throw "$What cannot be read" }
    $value = $null
    try { $value = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$What is not valid JSON" }
    if ($null -eq $value -or $value -isnot [System.Management.Automation.PSCustomObject]) { throw "$What is not a JSON object" }
    return $value
}

# A string property of a JSON object, or $null when it is absent or not a string.
function Get-JsonString($Object, [string]$Name) {
    if ($null -eq $Object -or $Object -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string]) { return $null }
    return $property.Value
}

# The `name = "..."` of every table of a Cargo.toml, by table. A name counts
# only for the table it stands in. Throws when the file is missing or cannot
# be read, or when a table has two names.
function Get-CargoTableNames([string]$Path, [string]$What) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$What is missing" }
    $lines = $null
    try { $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8) }
    catch { throw "$What cannot be read" }
    $names = @{}
    $table = ''
    foreach ($line in $lines) {
        if ($line -match '^\s*\[\[') { $table = '[[array]]'; continue }
        if ($line -match '^\s*\[\s*([^\]]+?)\s*\]\s*(#.*)?$') { $table = $Matches[1]; continue }
        if ($line -match '^\s*name\s*=\s*"([^"]*)"\s*(#.*)?$') {
            if ($names.ContainsKey($table)) { throw "$What has two names in [$table]" }
            $names[$table] = $Matches[1]
        }
    }
    return $names
}

# Why a directory is not a copy of the ATLAS repository, or '' when it is
# one. Several independent signs must agree; the identifier is the one this
# script isolates the data of. Nothing is run and nothing is written.
function Get-SourceDefect([string]$Directory) {
    try {
        $package = Read-JsonObject (Join-Path $Directory 'package.json') 'package.json'
        $name = Get-JsonString $package 'name'
        if ($name -cne 'atlas') { return "package.json: `"name`" is not `"atlas`"" }
        $scripts = $null
        if ($null -ne $package.PSObject.Properties['scripts']) { $scripts = $package.PSObject.Properties['scripts'].Value }
        if (-not (Get-JsonString $scripts 'build')) { return 'package.json: there is no "build" script' }

        $cargo = Get-CargoTableNames (ConvertTo-PlatformPath (Join-Path $Directory 'src-tauri\Cargo.toml')) 'src-tauri/Cargo.toml'
        if (-not $cargo.ContainsKey('package') -or $cargo['package'] -cne 'atlas') { return 'src-tauri/Cargo.toml: name in [package] is not "atlas"' }
        if (-not $cargo.ContainsKey('lib') -or $cargo['lib'] -cne 'atlas_lib') { return 'src-tauri/Cargo.toml: name in [lib] is not "atlas_lib"' }

        $tauri = Read-JsonObject (ConvertTo-PlatformPath (Join-Path $Directory 'src-tauri\tauri.conf.json')) 'src-tauri/tauri.conf.json'
        if ((Get-JsonString $tauri 'identifier') -cne $AppId) { return "src-tauri/tauri.conf.json: `"identifier`" is not `"$AppId`", the application whose data this script isolates" }
        if ((Get-JsonString $tauri 'productName') -cne 'ATLAS') { return 'src-tauri/tauri.conf.json: "productName" is not "ATLAS"' }
    } catch {
        return "$($_.Exception.Message)"
    }
    return ''
}

# The repository to build from: -Source, or the current directory if it is one.
function Get-SourceDirectory {
    $candidate = $Source
    if (-not $candidate) {
        if ($TestBase) { $candidate = Join-Path $TestBase 'cwd' } else { $candidate = (Get-Location).ProviderPath }
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        if ($Source) { throw "-Source is not an existing directory: $Source. Nothing was changed." }
        throw '-Build needs a copy of the ATLAS repository: pass -Source <folder> or start the script in that folder. Nothing was changed.'
    }
    $defect = Get-SourceDefect $candidate
    if ($defect) {
        if ($Source) { throw "-Source is not a copy of the ATLAS repository: $defect. Nothing was changed." }
        throw "-Build needs a copy of the ATLAS repository: pass -Source <folder> or start the script in that folder (the current directory is not one: $defect). Nothing was changed."
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

# The places the application is looked for when -Exe is not given. In the
# tests they lie below -TestBase.
function Get-ExeCandidates {
    if ($TestBase) {
        $current = Join-Path $TestBase 'cwd'
        $here = Join-Path $TestBase 'scriptdir'
        $programs = @((Join-Path $TestBase 'programfiles'))
    } else {
        $current = (Get-Location).ProviderPath
        $here = $PSScriptRoot
        $programs = @()
        foreach ($name in @('ProgramFiles', 'ProgramFiles(x86)')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ($value -and ($programs -notcontains $value)) { $programs += $value }
        }
    }
    $list = @(
        (Join-Path $current 'src-tauri\target\release\atlas.exe'),
        (Join-Path $current 'atlas.exe'),
        (Join-Path $here 'atlas.exe'),
        (Join-Path $LocalAppData 'ATLAS\ATLAS.exe'),
        (Join-Path $LocalAppData 'Programs\ATLAS\ATLAS.exe')
    )
    foreach ($folder in $programs) { $list += (Join-Path $folder 'ATLAS\ATLAS.exe') }
    return @($list | ForEach-Object { ConvertTo-PlatformPath $_ })
}

# The application this run will start, as a full path. Throws, before
# anything is changed, when it is not certain which one.
function Resolve-AtlasExe([string]$Built) {
    if ($Exe) {
        $given = ConvertTo-PlatformPath $Exe
        if (-not (Test-Path -LiteralPath $given -PathType Leaf)) { throw "The application given with -Exe does not exist: $Exe. Nothing was changed." }
        return (Resolve-Path -LiteralPath $given).Path
    }
    if ($Built) {
        if (-not (Test-Path -LiteralPath $Built -PathType Leaf)) { throw "The build did not leave the application at $Built. Nothing was changed." }
        return (Resolve-Path -LiteralPath $Built).Path
    }
    $found = @()
    foreach ($candidate in @(Get-ExeCandidates)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $full = (Resolve-Path -LiteralPath $candidate).Path
        $known = $false
        foreach ($other in $found) { if (Test-SamePath $other $full) { $known = $true } }
        if (-not $known) { $found += $full }
    }
    $searched = (@(Get-ExeCandidates) | ForEach-Object { "  $_" }) -join [Environment]::NewLine
    if ($found.Count -eq 1) {
        Write-Note "Application found: $($found[0])"
        return $found[0]
    }
    if (-not (Test-Interactive)) {
        if ($found.Count -gt 1) { throw "Several copies of the application were found: $($found -join '; '). Pass the one to test with -Exe. Nothing was changed." }
        throw "The application was not found. Pass it with -Exe or build it with -Build. Looked in:$([Environment]::NewLine)$searched$([Environment]::NewLine)Nothing was changed."
    }
    if ($found.Count -gt 1) {
        Write-Host 'Several copies of ATLAS were found:'
        for ($i = 0; $i -lt $found.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $found[$i]) }
        $answer = Read-Host 'Number of the one to test (empty = stop)'
        $number = 0
        if (-not [int]::TryParse("$answer".Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $found.Count) {
            throw 'No application was chosen. Nothing was changed.'
        }
        return $found[$number - 1]
    }
    Write-Host 'ATLAS was not found in these places:'
    Write-Host $searched
    $answer = "$(Read-Host 'Full path to atlas.exe (empty = stop)')".Trim().Trim('"')
    if (-not $answer) { throw 'No application was given. Nothing was changed.' }
    $answer = ConvertTo-PlatformPath $answer
    if (-not (Test-Path -LiteralPath $answer -PathType Leaf)) { throw "The application does not exist: $answer. Nothing was changed." }
    return (Resolve-Path -LiteralPath $answer).Path
}

# ---------------------------------------------------------------------------
# Running the application
# ---------------------------------------------------------------------------

function Get-LogLines {
    if (-not (Test-Path -LiteralPath $LogDir)) { return @() }
    $lines = New-Object System.Collections.ArrayList
    foreach ($file in @(Get-ChildItem -LiteralPath $LogDir -Filter 'atlas.*.log' -File | Sort-Object Name)) {
        # The application keeps the file open for writing.
        $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            while ($null -ne ($line = $reader.ReadLine())) { [void]$lines.Add($line) }
        } finally { $stream.Dispose() }
    }
    return @($lines)
}

function Start-Atlas {
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "The application is not there: '$Exe'." }
    $process = Start-Process -FilePath $Exe -WorkingDirectory $Report -PassThru
    # Windows PowerShell 5.1 reports no exit code unless the handle was taken early.
    $null = $process.Handle
    [void]$script:Started.Add($process)
    return $process
}

# Waits until the log has $Count new storage results after line $From.
function Wait-Storage([int]$From, [int]$Count) {
    $deadline = (Get-Date).AddSeconds($StartTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $all = @(Get-LogLines)
        if ($all.Count -gt $From) {
            $new = @($all[$From..($all.Count - 1)])
            $found = @($new | Where-Object { $_ -match 'database opened|database unavailable' })
            if ($found.Count -ge $Count) { return $new }
        }
        Start-Sleep -Milliseconds 300
    }
    throw "No storage result in the application log within $StartTimeoutSec s."
}

# Closes the main window as a user would and measures the time until the
# process is gone. Returns milliseconds, or -1 if the process had to be killed.
function Stop-Atlas($Process) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($OnWindows) {
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            $Process.Refresh()
            if ($Process.HasExited -or $Process.MainWindowHandle -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 200
        }
        $watch.Restart()
        if (-not $Process.HasExited) { [void]$Process.CloseMainWindow() }
    } else {
        # Not Windows: this branch exists only so that the script itself can
        # be exercised by its author. Its results are not a Windows check.
        $window = $null
        foreach ($line in @(& wmctrl -l -p 2>$null)) {
            $fields = @("$line" -split '\s+')
            if ($fields.Count -ge 3 -and $fields[2] -eq "$($Process.Id)") { $window = $fields[0] }
        }
        $watch.Restart()
        if ($window) { & wmctrl -i -c $window 2>$null } else { & wmctrl -c ATLAS 2>$null }
    }
    if ($Process.WaitForExit($ExitTimeoutSec * 1000)) {
        $watch.Stop()
        return [int]$watch.ElapsedMilliseconds
    }
    Write-Note "The application did not exit within $ExitTimeoutSec s; ending it."
    $Process.Kill()
    [void]$Process.WaitForExit(10000)
    return -1
}

# One or more instances: start, wait for the storage result, close normally.
function Invoke-Run([string]$Name, [int]$Instances = 1) {
    Assert-TestRoot
    $from = @(Get-LogLines).Count
    $processes = @()
    for ($i = 0; $i -lt $Instances; $i++) { $processes += Start-Atlas }
    $exitMs = @()
    $codes = @()
    try {
        [void](Wait-Storage $from $Instances)
        Start-Sleep -Seconds 2
    } finally {
        foreach ($process in $processes) {
            $exitMs += Stop-Atlas $process
            $code = '?'
            try { $code = $process.ExitCode } catch { $code = '?' }
            $codes += $code
        }
    }
    # The WebView processes outlive the window for a moment; the next step
    # must not find the files still held.
    if (-not (Wait-AppGone 20)) { Write-Note "The end of ATLAS is not confirmed after the window was closed: $($script:StillRunning)" }
    Start-Sleep -Milliseconds 500
    $all = @(Get-LogLines)
    $lines = @()
    if ($all.Count -gt $from) { $lines = @($all[$from..($all.Count - 1)]) }
    Set-Content -LiteralPath (Join-Path $Report "log-$Name.txt") -Value $lines -Encoding UTF8
    $storage = @($lines | Where-Object { $_ -match 'database ' })
    foreach ($line in $storage) {
        if ($line -match 'sqlite_version="?([0-9.]+)') { $script:SqliteVersion = $Matches[1] }
    }
    Save-State "after $Name"
    Add-Content -LiteralPath (Join-Path $Report 'runs.txt') -Encoding UTF8 -Value (
        '{0}: exit codes [{1}], exit time ms [{2}]' -f $Name, ($codes -join ', '), ($exitMs -join ', '))
    return [pscustomobject]@{
        Lines    = $lines
        Storage  = $storage
        Text     = ($storage -join "`n")
        ExitMs   = $exitMs
        Codes    = $codes
        Closed   = @($lines | Where-Object { $_ -match 'database closed' }).Count
        Graceful = (@($exitMs | Where-Object { $_ -lt 0 }).Count -eq 0)
    }
}

function Invoke-Scenario([string]$Name, [scriptblock]$Body) {
    Write-Note "--- $Name"
    try {
        Assert-TestRoot
        Save-State "before $Name"
        & $Body
    } catch {
        Add-Result $Name 'FAIL' $_.Exception.Message
    }
}

function Find-Python {
    foreach ($candidate in @(@('py', '-3'), @('python'), @('python3'))) {
        $command = Get-Command $candidate[0] -ErrorAction SilentlyContinue
        if ($null -eq $command) { continue }
        $arguments = @()
        if ($candidate.Count -gt 1) { $arguments = @($candidate[1..($candidate.Count - 1)]) }
        try {
            $version = & $candidate[0] @arguments -c 'import sqlite3; print(sqlite3.sqlite_version)' 2>$null
            if ($LASTEXITCODE -eq 0 -and $version) {
                return [pscustomobject]@{ Command = $candidate[0]; Arguments = $arguments; Sqlite = "$version".Trim() }
            }
        } catch { continue }
    }
    return $null
}

# ---------------------------------------------------------------------------
# -SelfTest: the tests of this script
# ---------------------------------------------------------------------------
# Every case builds a profile of its own in a temporary directory and runs
# this file against it with -SelfTest -TestBase -TestRun. In that mode the
# script never starts ATLAS and never looks at %LOCALAPPDATA%, so the tests
# do not touch any real data. Faults are injected with -TestFault.
#
# The suite does not take that on trust: everything named com.inlerno.atlas*
# in the profile is recorded before and after, and the suite fails when the
# two records differ or when one of them cannot be taken completely.
# -SelfTest -TestBase makes this guard check itself against a test profile.

if ($SuiteMode -or $GuardMode) {
    # The folder that is watched: the real %LOCALAPPDATA%, or <TestBase>\local
    # when the guard checks itself (the real one is not read then).
    $ProfileParent = $LocalAppData

    # Only for the tests of the record itself, set by the cases below: the
    # relative path at which listing or hashing must fail.
    $script:SnapshotFailList = ''
    $script:SnapshotFailHash = ''

    # The record of everything in $Parent whose name starts with the
    # identifier of ATLAS, one line per object, sorted, so that the order in
    # which the file system lists things does not matter:
    #   d|<relative path>                      a directory
    #   f|<relative path>|<size>|<SHA-256>     a file
    #   l|<relative path>                      a junction or symbolic link,
    #                                          recorded and never followed,
    #                                          so that a loop cannot trap it
    # The walk is its own, one directory at a time, and every error stops it:
    # a record that leaves something out would prove nothing.
    function Get-ProfileSnapshot([string]$Parent) {
        if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw "the folder $Parent does not exist" }
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $queue = New-Object System.Collections.Queue
        $top = $null
        try { $top = @(Get-ChildItem -LiteralPath $Parent -Force -ErrorAction Stop) }
        catch { throw "the folder $Parent cannot be listed: $($_.Exception.Message)" }
        foreach ($entry in $top) {
            if ($entry.Name.StartsWith($AppId, [System.StringComparison]::OrdinalIgnoreCase)) { $queue.Enqueue(@($entry, $entry.Name)) }
        }
        while ($queue.Count -gt 0) {
            $pair = $queue.Dequeue()
            $item = $pair[0]
            $relative = $pair[1]
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $lines.Add("l|$relative")
                continue
            }
            if ($item.PSIsContainer) {
                $lines.Add("d|$relative")
                $children = $null
                try {
                    if ($script:SnapshotFailList -and $script:SnapshotFailList -eq $relative) { throw 'injected test fault: the directory cannot be listed' }
                    $children = @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)
                } catch { throw "the directory $relative cannot be listed: $($_.Exception.Message)" }
                foreach ($child in $children) { $queue.Enqueue(@($child, "$relative/$($child.Name)")) }
                continue
            }
            $hash = $null
            try {
                if ($script:SnapshotFailHash -and $script:SnapshotFailHash -eq $relative) { throw 'injected test fault: the file cannot be read' }
                $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            } catch { throw "the file $relative cannot be read: $($_.Exception.Message)" }
            if (-not $hash) { throw "the file $relative gave no hash" }
            $lines.Add("f|$relative|$($item.Length)|$hash")
        }
        $lines.Sort([System.StringComparer]::Ordinal)
        return ($lines.ToArray() -join "`n")
    }

    function Get-SnapshotCount([string]$Snapshot) {
        if (-not $Snapshot) { return 0 }
        return @($Snapshot -split "`n").Count
    }

    $guardFaults = @('profile-initial-error', 'profile-final-error', 'profile-change')
    if ($GuardMode) {
        foreach ($fault in $Faults) {
            if ($guardFaults -notcontains $fault) { throw "-SelfTest -TestBase without -TestRun knows only these faults: $($guardFaults -join ', '). Nothing was changed." }
        }
    }

    # ATLAS must not be running: its files are held and change, and a failed
    # record must not be the way this is found out. A WebView2 process whose
    # command line cannot be read may be one of ATLAS: not knowing is not
    # "not running". No process is ended here; the self-test only stops.
    $alive = $null
    $unknown = $null
    try {
        $blocking = Get-Blocking
        $alive = @($blocking.App) + @($blocking.WebView)
        $unknown = @($blocking.Unknown)
    } catch {
        Write-Host "It cannot be checked whether ATLAS is running: $($_.Exception.Message)"
        Write-Host 'The self-test was not started.'
        exit 2
    }
    if ($alive.Count -gt 0) {
        Write-Host "ATLAS is running: $(Format-Processes $alive)."
        Write-Host 'Close ATLAS and try again.'
        Write-Host 'The self-test was not started.'
        exit 2
    }
    if ($unknown.Count -gt 0) {
        Write-Host "It cannot be told whose these WebView2 processes are: $(Format-Processes $unknown)."
        Write-Host 'Their command line cannot be read, so they may belong to ATLAS, and the self-test stops rather than assume they do not.'
        Write-Host 'Close the applications they belong to (or sign out other users) and try again. The script does not end them.'
        Write-Host 'The self-test was not started.'
        exit 2
    }

    # The record before the first test case. Without it nothing is run.
    $profileBefore = $null
    try {
        if ($Faults -contains 'profile-initial-error') { throw 'injected test fault: the profile cannot be read' }
        $profileBefore = Get-ProfileSnapshot $ProfileParent
    } catch {
        Write-Host "The profile cannot be recorded completely: $($_.Exception.Message)"
        Write-Host "Watched: everything named $AppId* in $ProfileParent"
        Write-Host 'The self-test was not started: it could not prove afterwards that the profile is unchanged.'
        exit 2
    }
    Write-Host "Profile watched: $ProfileParent ($AppId*): $(Get-SnapshotCount $profileBefore) objects recorded"

    if ($GuardMode) {
        # The guard checks itself: no test case is run. A fault may change
        # the TEST profile between the two records.
        if ($Faults -contains 'profile-change') {
            if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root | Out-Null }
            [System.IO.File]::WriteAllText((Join-Path $Root 'changed-by-the-fault.txt'), 'x')
        }
        $problem = ''
        try {
            if ($Faults -contains 'profile-final-error') { throw 'injected test fault: the profile cannot be read' }
            $profileAfter = Get-ProfileSnapshot $ProfileParent
            if ($profileAfter -cne $profileBefore) { $problem = 'the profile changed between the two records' }
        } catch { $problem = "the profile cannot be recorded completely afterwards: $($_.Exception.Message)" }
        if ($problem) {
            Write-Host "FAILED  profile guard: $problem"
            exit 1
        }
        Write-Host 'ok      profile guard: the profile is unchanged (guard self-check; the test cases are not run in this mode)'
        exit 0
    }

    # The tests run this very file as a child process.
    $Script = $PSCommandPath
    $Shell = (Get-Process -Id $PID).Path
    $OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows
    $AppId = 'com.inlerno.atlas'
    $SentinelName = '.atlas-sqlite-check-test-root'
    # Kept short: Windows PowerShell 5.1 cannot go beyond 260 characters, and the
    # backup directories of the script carry a time and a 32 digit run id.
    $Work = Join-Path ([System.IO.Path]::GetTempPath()) ("asct-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $Work | Out-Null

    # What the tests must leave alone, besides the profile: the real ATLAS.
    function Test-SamePathForTest([string]$Left, [string]$Right) { return ("$Left".TrimEnd('\', '/') -ieq "$Right".TrimEnd('\', '/')) }
    # The whole list, so that an error is an error and not "no such process".
    function Get-AtlasProcessIds { return @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -eq 'atlas' } | ForEach-Object { $_.Id }) }
    $atlasBefore = @(Get-AtlasProcessIds)

    $script:Failures = New-Object System.Collections.ArrayList
    $script:Checks = 0
    $script:Case = ''
    $script:CaseFailed = $false
    $script:CaseSkipped = ''
    $script:Cases = New-Object System.Collections.ArrayList

    function Check([bool]$Condition, [string]$What) {
        $script:Checks++
        if (-not $Condition) {
            $script:CaseFailed = $true
            [void]$script:Failures.Add("$($script:Case): $What")
            Write-Host "    FAILED: $What" -ForegroundColor Red
        }
    }

    function Start-Case([string]$Name) {
        Stop-Case
        $script:Case = $Name
        $script:CaseFailed = $false
        $script:CaseSkipped = ''
    }

    # Marks the current case as not run here, with the reason. A skipped case
    # is counted and shown; it is never shown as passed.
    function Skip-Case([string]$Why) { $script:CaseSkipped = $Why }

    function Stop-Case {
        if ($script:Case) {
            $status = 'ok'
            if ($script:CaseSkipped) { $status = 'SKIPPED' }
            if ($script:CaseFailed) { $status = 'FAILED' }
            [void]$script:Cases.Add("$status  $($script:Case)")
            Write-Host ("{0,-7} {1}" -f $status, $script:Case)
            if ($status -eq 'SKIPPED') { Write-Host "        reason: $($script:CaseSkipped)" }
            $script:Case = ''
        }
    }

    # Names and CONTENTS of everything below a directory.
    function Get-Snapshot([string]$Directory) {
        if (-not (Test-Path -LiteralPath $Directory)) { return '<absent>' }
        $base = (Get-Item -LiteralPath $Directory -Force).FullName.TrimEnd('\', '/')
        $lines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in @(Get-ChildItem -LiteralPath $base -Recurse -Force)) {
            $relative = $item.FullName.Substring($base.Length + 1).Replace('\', '/')
            if ($item.PSIsContainer) { $lines.Add("d|$relative") }
            else { $lines.Add("f|$relative|$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)") }
        }
        $lines.Sort([System.StringComparer]::Ordinal)
        return ($lines.ToArray() -join "`n")
    }

    # A profile with (or without) a data directory that stands for the user's.
    function New-Base([string]$Name, [bool]$WithOriginal = $true) {
        $base = Join-Path $Work $Name
        New-Item -ItemType Directory -Path (Join-Path $base 'local') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $base 'home') -Force | Out-Null
        if ($WithOriginal) {
            $root = Join-Path (Join-Path $base 'local') $AppId
            New-Item -ItemType Directory -Path (Join-Path $root 'data') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'logs') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path (Join-Path $root 'EBWebView') 'Default') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path (Join-Path $root 'data') 'atlas.db'), 'USER DATABASE - must never change')
            [System.IO.File]::WriteAllText((Join-Path $root 'storage.initialized'), 'marker')
            [System.IO.File]::WriteAllText((Join-Path (Join-Path $root 'logs') 'atlas.2026-11-01.log'), 'old log')
            [System.IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $root 'EBWebView') 'Default') 'Cookies'), 'cookies')
            # A name that is not ASCII (U+0416 U+0443 U+0440).
            $cyrillic = ([string][char]0x0416) + ([string][char]0x0443) + ([string][char]0x0440) + '.txt'
            [System.IO.File]::WriteAllText((Join-Path $root $cyrillic), 'note')
        }
        return $base
    }

    function Get-Root([string]$Base) { return (Join-Path (Join-Path $Base 'local') $AppId) }
    function Get-Local([string]$Base) { return (Join-Path $Base 'local') }
    function Get-StateDir([string]$Base) { return (Join-Path (Join-Path $Base 'local') "$AppId.sqlite-check") }

    function Get-Backups([string]$Base) {
        return @(Get-ChildItem -LiteralPath (Get-Local $Base) -Directory -Force |
            Where-Object { $_.Name.StartsWith("$AppId.sqlite-check-backup-") })
    }

    function Get-Manifests([string]$Base) {
        $state = Get-StateDir $Base
        if (-not (Test-Path -LiteralPath $state)) { return @() }
        return @(Get-ChildItem -LiteralPath $state -File -Filter 'manifest-*.txt')
    }

    function Test-IsTestDir([string]$Directory) {
        return (Test-Path -LiteralPath (Join-Path $Directory $SentinelName) -PathType Leaf)
    }

    # Runs the script; returns its exit code. The output goes to a file.
    function Invoke-Check([string]$Base, [string[]]$Arguments) {
        $script:RunNumber++
        $log = Join-Path $Base ("run-{0:d2}.txt" -f $script:RunNumber)
        $all = @('-NoLogo', '-NoProfile')
        if ($OnWindows) { $all += @('-ExecutionPolicy', 'Bypass') }
        $all += @('-File', $Script, '-SelfTest', '-TestBase', $Base, '-TestRun') + $Arguments
        $code = Invoke-Shell $all $log
        $script:LastLog = $log
        return $code
    }

    # Runs the shell and writes everything it prints to a file, one line of the
    # child per line of the file. Not `*> file`: Windows PowerShell 5.1 would
    # wrap long lines at the width of the console and turn what the child writes
    # to its error stream into terminating errors.
    function Invoke-Shell([string[]]$All, [string]$Log) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $lines = @(& $Shell @All 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        [System.IO.File]::WriteAllLines($Log, [string[]]$lines)
        return $code
    }
    $script:RunNumber = 0
    $script:LastLog = ''

    function Get-LastOutput { return ([System.IO.File]::ReadAllText($script:LastLog)) }

    # An interrupted run: the process ends right after the isolation, no `finally`.
    function New-InterruptedBase([string]$Name, [bool]$WithOriginal = $true) {
        $base = New-Base $Name $WithOriginal
        $code = Invoke-Check $base @('-TestFault', 'crash-after-isolation')
        Check ($code -eq 99) "setup: the interrupted run must end with 99, got $code"
        return $base
    }

    # ---------------------------------------------------------------------------
    # Normal runs
    # ---------------------------------------------------------------------------

    Start-Case 'normal run: the original comes back unchanged'
    $base = New-Base 'normal'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @()
    Check ($code -eq 0) "exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original data is unchanged'
    Check (-not (Test-IsTestDir (Get-Root $base))) 'the data path does not hold a test directory'
    Check (@(Get-Backups $base).Count -eq 0) 'no backup directory is left'
    Check (@(Get-Manifests $base).Count -eq 1) 'the manifest is kept'
    Check ((Get-LastOutput) -match 'original path restored:\s+yes') 'the outcome says the path is restored'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $base 'home') -Recurse -Force -Filter $SentinelName).Count -eq 1) 'the test directory is in the report'

    Start-Case 'normal run twice: the manifest of the first run is not overwritten'
    $first = (Get-Manifests $base)[0]
    $firstHash = (Get-FileHash -LiteralPath $first.FullName -Algorithm SHA256).Hash
    $code = Invoke-Check $base @()
    Check ($code -eq 0) "exit code 0, got $code"
    Check (@(Get-Manifests $base).Count -eq 2) 'two manifests exist'
    Check ((Get-FileHash -LiteralPath $first.FullName -Algorithm SHA256).Hash -eq $firstHash) 'the first manifest is unchanged'
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original data is unchanged'

    Start-Case 'normal run without a data directory: nothing is left in the data path'
    $base = New-Base 'no-original' $false
    $code = Invoke-Check $base @()
    Check ($code -eq 0) "exit code 0, got $code"
    Check (-not (Test-Path -LiteralPath (Get-Root $base))) 'the data path is empty again'
    Check (@(Get-Backups $base).Count -eq 0) 'no backup directory'

    Start-Case 'a failing scenario: the original comes back'
    $base = New-Base 'scenario-fault'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'scenario')
    Check ($code -eq 1) "exit code 1, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original data is unchanged'
    Check (@(Get-Backups $base).Count -eq 0) 'no backup directory is left'

    # ---------------------------------------------------------------------------
    # A step of Enter-Isolation fails
    # ---------------------------------------------------------------------------

    foreach ($fault in @(
            @{ Name = 'manifest-write'; Code = 2; Moved = $false },
            @{ Name = 'stage-create'; Code = 1; Moved = $false },
            @{ Name = 'sentinel-write'; Code = 1; Moved = $false },
            @{ Name = 'backup-rename'; Code = 1; Moved = $false },
            @{ Name = 'backup-verify'; Code = 1; Moved = $true },
            @{ Name = 'stage-move'; Code = 1; Moved = $true })) {
        Start-Case "fault '$($fault.Name)': the original is in its place afterwards"
        $base = New-Base "fault-$($fault.Name)"
        $before = Get-Snapshot (Get-Root $base)
        $code = Invoke-Check $base @('-TestFault', $fault.Name)
        Check ($code -eq $fault.Code) "exit code $($fault.Code), got $code"
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original data is unchanged and in its place'
        Check (-not (Test-IsTestDir (Get-Root $base))) 'the data path does not hold a test directory'
        Check (@(Get-Backups $base).Count -eq 0) 'no backup directory is left'
        $output = Get-LastOutput
        Check ($output -match 'original path restored:\s+yes') 'the outcome says where the original is'
        Check ($output -match 'test copy:') 'the outcome says where the test copy is'
        Check ($output -match 'manual steps:\s+none') 'no manual step is asked for'
        $again = Invoke-Check $base @('-RestoreOnly')
        Check ($again -eq 0) "-RestoreOnly afterwards: exit code 0, got $again"
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) '-RestoreOnly afterwards changes nothing'
    }

    Start-Case "fault 'sentinel-write' without a data directory: no unmarked directory in the data path"
    $base = New-Base 'fault-sentinel-no-original' $false
    $code = Invoke-Check $base @('-TestFault', 'sentinel-write')
    Check ($code -eq 1) "exit code 1, got $code"
    Check (-not (Test-Path -LiteralPath (Get-Root $base))) 'the data path stays empty'

    # ---------------------------------------------------------------------------
    # A step of the restore fails
    # ---------------------------------------------------------------------------

    Start-Case "fault 'test-root-move': the test directory is renamed aside, the original comes back"
    $base = New-Base 'fault-test-root-move'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'test-root-move')
    Check ($code -eq 0) "exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original data is unchanged'
    $aside = @(Get-ChildItem -LiteralPath (Get-Local $base) -Directory -Force | Where-Object { $_.Name.EndsWith('-aside') })
    Check ($aside.Count -eq 1 -and (Test-IsTestDir $aside[0].FullName)) 'the test directory lies aside with its sentinel'

    Start-Case 'the test directory cannot be moved at all: stop, backup intact, then -RestoreOnly'
    $base = New-Base 'fault-test-root-stuck'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'test-root-move,test-root-aside')
    Check ($code -eq 3) "exit code 3, got $code"
    $backups = @(Get-Backups $base)
    Check ($backups.Count -eq 1) 'exactly one backup directory'
    if ($backups.Count -eq 1) { Check ((Get-Snapshot $backups[0].FullName) -eq $before) 'the backup holds the original data unchanged' }
    Check (Test-IsTestDir (Get-Root $base)) 'the test directory is still in the data path'
    $output = Get-LastOutput
    Check ($output -match 'original path restored:\s+NO') 'the outcome says the path is NOT restored'
    Check ($output -match 'manual steps:\s+see ') 'the outcome points at the instructions'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $base 'home') -Recurse -Filter 'RESTORE-INSTRUCTIONS*.txt').Count -ge 1) 'the instructions are written'
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) '-RestoreOnly brings the original back unchanged'
    Check (@(Get-Backups $base).Count -eq 0) 'no backup directory is left'
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "second -RestoreOnly: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the second -RestoreOnly changes nothing'

    Start-Case "fault 'backup-restore': stop, backup intact, then -RestoreOnly"
    $base = New-Base 'fault-backup-restore'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'backup-restore')
    Check ($code -eq 3) "exit code 3, got $code"
    $backups = @(Get-Backups $base)
    Check ($backups.Count -eq 1) 'exactly one backup directory'
    if ($backups.Count -eq 1) { Check ((Get-Snapshot $backups[0].FullName) -eq $before) 'the backup holds the original data unchanged' }
    Check (-not (Test-Path -LiteralPath (Get-Root $base))) 'the data path is empty (the test directory was moved away)'
    Check ((Get-LastOutput) -match 'original path restored:\s+NO') 'the outcome says the path is NOT restored'
    $code = Invoke-Check $base @('-RestoreOnly', '-TestFault', 'backup-restore')
    Check ($code -eq 3) "-RestoreOnly that fails too: exit code 3, got $code"
    $backups = @(Get-Backups $base)
    Check ($backups.Count -eq 1 -and (Get-Snapshot $backups[0].FullName) -eq $before) 'the backup is still intact'
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original is back unchanged'

    # ---------------------------------------------------------------------------
    # Interrupted runs and -RestoreOnly
    # ---------------------------------------------------------------------------

    Start-Case 'interrupted after the isolation: a new run refuses, -RestoreOnly restores, twice is safe'
    $base = New-Base 'interrupted'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'crash-after-isolation')
    Check ($code -eq 99) "the interrupted run ends with 99, got $code"
    Check (Test-IsTestDir (Get-Root $base)) 'the test directory is in the data path'
    Check (@(Get-Backups $base).Count -eq 1) 'one backup directory'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @()
    Check ($code -eq 3) "a new run refuses with 3 (the data is not in its place), got $code"
    Check ((Get-LastOutput) -match 'run the script with -RestoreOnly') 'the refusal points at -RestoreOnly'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the refused run moved nothing'
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original is back unchanged'
    Check (@(Get-Backups $base).Count -eq 0) 'no backup directory is left'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "second -RestoreOnly: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the second -RestoreOnly moved nothing'
    $code = Invoke-Check $base @()
    Check ($code -eq 0) "a normal run works again: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original is unchanged after it'

    Start-Case 'interrupted right after the rename: only a backup exists, -RestoreOnly restores'
    $base = New-Base 'only-backup'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'crash-after-backup')
    Check ($code -eq 99) "the interrupted run ends with 99, got $code"
    Check (-not (Test-Path -LiteralPath (Get-Root $base))) 'the data path is empty'
    Check (@(Get-Backups $base).Count -eq 1) 'one backup directory'
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original is back unchanged'

    Start-Case 'only a test directory (there was no data directory): -RestoreOnly moves it away'
    $base = New-InterruptedBase 'only-test-root' $false
    Check (Test-IsTestDir (Get-Root $base)) 'the test directory is in the data path'
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly: exit code 0, got $code"
    Check (-not (Test-Path -LiteralPath (Get-Root $base))) 'the data path is empty again'
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "second -RestoreOnly: exit code 0, got $code"

    Start-Case 'only a test directory, but its manifest names a backup that is gone: stop'
    $base = New-InterruptedBase 'test-root-backup-gone'
    $elsewhere = Join-Path $base 'moved-by-the-test'
    Move-Item -LiteralPath (Get-Backups $base)[0].FullName -Destination $elsewhere
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    Check ((Get-LastOutput) -match 'no backup directory is there') 'the reason is named'

    Start-Case 'backup and test directory from different runs: stop, nothing moved'
    $base = New-InterruptedBase 'different-runs'
    $sentinel = Join-Path (Get-Root $base) $SentinelName
    $other = [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllLines($sentinel, @('Test directory', "run_id=$other"))
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    Check ((Get-LastOutput) -match 'different runs') 'the reason is named'

    Start-Case 'the sentinel of the test directory is damaged: stop, nothing moved'
    $base = New-InterruptedBase 'damaged-sentinel'
    [System.IO.File]::WriteAllText((Join-Path (Get-Root $base) $SentinelName), 'garbage')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'

    Start-Case 'several backups: stop, nothing moved, no guess'
    $base = New-InterruptedBase 'several-backups'
    $second = Join-Path (Get-Local $base) "$AppId.sqlite-check-backup-20260101-000000-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $second | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $second 'file'), 'another backup')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    Check ((Get-LastOutput) -match 'more than one backup') 'the reason is named'
    $code = Invoke-Check $base @()
    Check ($code -eq 3) "a normal run refuses with 3 (the data is not in its place), got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the refused run moved nothing'

    Start-Case 'the manifest is missing: stop; put back: restore'
    $base = New-InterruptedBase 'manifest-missing'
    $manifest = (Get-Manifests $base)[0].FullName
    $kept = Join-Path $base 'manifest-kept-by-the-test.txt'
    Move-Item -LiteralPath $manifest -Destination $kept
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    Check ((Get-LastOutput) -match 'is missing') 'the reason is named'
    Move-Item -LiteralPath $kept -Destination $manifest
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "with the manifest back: exit code 0, got $code"
    Check (-not (Test-IsTestDir (Get-Root $base)) -and (Test-Path -LiteralPath (Join-Path (Join-Path (Get-Root $base) 'data') 'atlas.db'))) 'the original is back'

    Start-Case 'the manifest is damaged: stop, nothing moved'
    $base = New-InterruptedBase 'manifest-damaged'
    $manifest = (Get-Manifests $base)[0].FullName
    $text = [System.IO.File]::ReadAllText($manifest)
    [System.IO.File]::WriteAllText($manifest, ($text -replace 'entries=\d+', 'entries=1'))
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    Check ((Get-LastOutput) -match 'damaged') 'the reason is named'

    Start-Case 'the manifest is cut short: stop, nothing moved'
    $base = New-InterruptedBase 'manifest-truncated'
    $manifest = (Get-Manifests $base)[0].FullName
    [System.IO.File]::WriteAllText($manifest, 'format=1')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'

    Start-Case 'the backup no longer matches its manifest: stop; when it matches again: restore'
    $base = New-InterruptedBase 'backup-changed'
    $extra = Join-Path (Get-Backups $base)[0].FullName 'added-by-the-test.txt'
    [System.IO.File]::WriteAllText($extra, 'x')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    Check ((Get-LastOutput) -match 'does not match the fingerprint') 'the reason is named'
    Remove-Item -LiteralPath $extra
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "when it matches again: exit code 0, got $code"

    Start-Case 'the data path is occupied by a directory without a sentinel: stop, nothing moved'
    $base = New-InterruptedBase 'occupied'
    Remove-Item -LiteralPath (Join-Path (Get-Root $base) $SentinelName) -Force
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    Check ((Get-LastOutput) -match 'it may be data') 'the reason is named'

    Start-Case 'a backup made by an older version of the script (no run id): stop, nothing moved'
    $base = New-Base 'old-backup' $false
    $old = Join-Path (Get-Local $base) "$AppId.sqlite-check-backup-20261115-190917"
    New-Item -ItemType Directory -Path $old | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $old 'file'), 'data')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "-RestoreOnly: exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    $code = Invoke-Check $base @()
    Check ($code -eq 3) "a normal run refuses with 3 (the data is not in its place), got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the refused run moved nothing'

    Start-Case '-RestoreOnly with nothing to restore: exit 0, nothing moved'
    $base = New-Base 'nothing-to-restore'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "exit code 0, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'

    # ---------------------------------------------------------------------------
    # Processes
    # ---------------------------------------------------------------------------

    function Set-Processes([string]$Base, [string[]]$Lines) {
        [System.IO.File]::WriteAllLines((Join-Path $Base 'processes.txt'), $Lines)
    }

    foreach ($entry in @(
            @{ Name = 'ATLAS is running'; Lines = @('100|atlas.exe|C:\x\atlas.exe'); Pattern = 'ATLAS is running' },
            @{ Name = 'the installed ATLAS.exe is running'; Lines = @('100|ATLAS.exe|C:\Program Files\ATLAS\ATLAS.exe'); Pattern = 'ATLAS is running' },
            @{ Name = 'a WebView2 process of ATLAS (by the executable name) is left'; Lines = @('200|msedgewebview2.exe|msedgewebview2.exe --type=renderer --webview-exe-name=atlas.exe'); Pattern = 'WebView2 processes of ATLAS' },
            @{ Name = 'a WebView2 process with an unreadable command line'; Lines = @('300|msedgewebview2.exe|<unreadable>'); Pattern = 'cannot be told whose' })) {
        Start-Case "processes: $($entry.Name) -> refuse before any change"
        $base = New-Base ("proc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Set-Processes $base $entry.Lines
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @()
        Check ($code -eq 2) "exit code 2, got $code"
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was changed'
        Check ((Get-LastOutput) -match $entry.Pattern) 'the reason is named'
    }

    Start-Case 'processes: a WebView2 process that names the data directory -> refuse'
    $base = New-Base 'proc-by-directory'
    Set-Processes $base @("200|msedgewebview2.exe|msedgewebview2.exe --user-data-dir=`"$(Get-Root $base)\EBWebView`" --type=gpu-process")
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @()
    Check ($code -eq 2) "exit code 2, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was changed'

    Start-Case 'processes: WebView2 of another application and unrelated processes -> the run goes on'
    $base = New-Base 'proc-foreign'
    $before = Get-Snapshot (Get-Root $base)
    Set-Processes $base @(
        '400|msedgewebview2.exe|msedgewebview2.exe --webview-exe-name=Teams.exe --user-data-dir="C:\Users\u\AppData\Local\Teams\EBWebView"',
        '401|explorer.exe|C:\Windows\explorer.exe',
        '402|atlas-helper.exe|C:\other\atlas-helper.exe')
    $code = Invoke-Check $base @()
    Check ($code -eq 0) "exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original data is unchanged'

    Start-Case 'processes: ATLAS is running during -RestoreOnly -> stop, nothing moved; afterwards restore'
    $base = New-InterruptedBase 'proc-restore'
    Set-Processes $base @('100|atlas.exe|C:\x\atlas.exe')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    Remove-Item -LiteralPath (Join-Path $base 'processes.txt')
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "after ATLAS was closed: exit code 0, got $code"

    # ---------------------------------------------------------------------------
    # Processes that are still there when the run wants to restore
    # ---------------------------------------------------------------------------

    # processes-after-scenario.txt becomes the process list once the (imitated)
    # scenario has run: what a run of the application can leave behind.
    foreach ($entry in @(
            @{ Name = 'a WebView2 process with an unreadable command line stays'; Lines = @('300|msedgewebview2.exe|<unreadable>'); Pattern = 'owner unknown' },
            @{ Name = 'a WebView2 process of ATLAS stays'; Lines = @('200|msedgewebview2.exe|msedgewebview2.exe --type=renderer --webview-exe-name=atlas.exe'); Pattern = 'msedgewebview2\.exe \(id 200\)' },
            @{ Name = 'the application itself stays'; Lines = @('100|atlas.exe|C:\x\atlas.exe'); Pattern = 'atlas\.exe \(id 100\)' },
            @{ Name = 'the process list cannot be read'; Lines = @('!error'); Pattern = 'list of processes cannot be read' })) {
        Start-Case "after the scenario $($entry.Name): nothing is moved, exit 3; -RestoreOnly restores once it is gone"
        $base = New-Base ("after-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $before = Get-Snapshot (Get-Root $base)
        [System.IO.File]::WriteAllLines((Join-Path $base 'processes-after-scenario.txt'), $entry.Lines)
        $code = Invoke-Check $base @()
        Check ($code -eq 3) "exit code 3, got $code"
        $output = Get-LastOutput
        Check ($output -match 'cannot be confirmed that every ATLAS and WebView2 process has ended') 'the end of ATLAS is reported as not confirmed'
        Check ($output -match $entry.Pattern) 'what is still running is named'
        Check ($output -match 'original path restored:\s+NO') 'the outcome says the path is NOT restored'
        Check ($output -notmatch 'Test directory moved|Original data directory restored') 'nothing was moved or restored'
        Check (Test-IsTestDir (Get-Root $base)) 'the test directory is still in the data path'
        $backups = @(Get-Backups $base)
        Check ($backups.Count -eq 1) 'exactly one backup directory'
        if ($backups.Count -eq 1) { Check ((Get-Snapshot $backups[0].FullName) -eq $before) 'the backup holds the original data unchanged' }
        Check (@(Get-ChildItem -LiteralPath (Join-Path $base 'home') -Recurse -Force -Filter $SentinelName).Count -eq 0) 'no test directory was taken into the report'
        Check (@(Get-ChildItem -LiteralPath (Join-Path $base 'home') -Recurse -Filter 'RESTORE-INSTRUCTIONS*.txt').Count -ge 1) 'the instructions are written'
        # Still there: -RestoreOnly must not move anything either.
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 3) "-RestoreOnly while it is still there: exit code 3, got $code"
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) '-RestoreOnly while it is still there moved nothing'
        # Gone.
        Remove-Item -LiteralPath (Join-Path $base 'processes.txt') -Force
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 0) "-RestoreOnly after it is gone: exit code 0, got $code"
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original is back unchanged'
        Check (@(Get-Backups $base).Count -eq 0) 'no backup directory is left'
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 0) "second -RestoreOnly: exit code 0, got $code"
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the second -RestoreOnly moved nothing'
    }

    Start-Case 'the process list cannot be read during -RestoreOnly: stop, nothing moved; afterwards restore'
    $base = New-InterruptedBase 'proc-list-error'
    Set-Processes $base @('!error')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    Check ((Get-LastOutput) -match 'list of processes cannot be read') 'the reason is named'
    Remove-Item -LiteralPath (Join-Path $base 'processes.txt') -Force
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "afterwards: exit code 0, got $code"

    Start-Case 'the process list cannot be read before the run: refuse before any change'
    $base = New-Base 'proc-list-error-start'
    Set-Processes $base @('!error')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @()
    Check ($code -eq 2) "exit code 2, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was changed'

    # ---------------------------------------------------------------------------
    # The backups cannot be listed
    # ---------------------------------------------------------------------------

    Start-Case 'the backups cannot be listed during -RestoreOnly: a refusal, not "nothing to restore"'
    $base = New-InterruptedBase 'list-error-restore'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly', '-TestFault', 'list-backups')
    Check ($code -eq 3) "exit code 3, got $code"
    $output = Get-LastOutput
    Check ($output -notmatch 'Nothing to restore') 'it does not say "nothing to restore"'
    Check ($output -match 'cannot be listed') 'the reason is named'
    Check ($output -match 'original path restored:\s+NO') 'the outcome does not claim the data is in place'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "once the listing works: exit code 0, got $code"
    Check (-not (Test-IsTestDir (Get-Root $base)) -and @(Get-Backups $base).Count -eq 0) 'the original is back'

    Start-Case 'the backups cannot be listed and there is nothing to restore: still a refusal'
    $base = New-Base 'list-error-clean'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly', '-TestFault', 'list-backups')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-LastOutput) -notmatch 'Nothing to restore') 'it does not say "nothing to restore"'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'

    Start-Case 'the backups cannot be listed before a run: refuse, nothing changed, no claim that the data is in place'
    $base = New-Base 'list-error-start'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-TestFault', 'list-backups')
    Check ($code -eq 3) "exit code 3 (the state could not be checked), got $code"
    $output = Get-LastOutput
    Check ($output -match 'cannot be listed') 'the reason is named'
    Check ($output -match 'original path restored:\s+NO') 'the outcome does not claim the data is in place'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was changed'

    # ---------------------------------------------------------------------------
    # The backup changes between its first check and the restore
    # ---------------------------------------------------------------------------

    Start-Case 'the backup changes during the run: the restore stops before the backup is moved; then -RestoreOnly'
    $base = New-Base 'tamper-run'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'tamper-backup')
    Check ($code -eq 3) "exit code 3, got $code"
    $output = Get-LastOutput
    Check ($output -match 'does not match the fingerprint') 'the reason is named'
    Check ($output -match 'it was not moved') 'it says the backup was not moved'
    Check ($output -notmatch 'Original data directory restored') 'nothing was restored'
    Check (-not (Test-Path -LiteralPath (Get-Root $base))) 'the data path is not occupied'
    $backups = @(Get-Backups $base)
    Check ($backups.Count -eq 1) 'the backup is where it was'
    if ($backups.Count -eq 1) {
        $added = Join-Path $backups[0].FullName 'added-by-the-fault.txt'
        Check (Test-Path -LiteralPath $added) 'the change is in the backup'
        # Still changed: -RestoreOnly refuses too.
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 3) "-RestoreOnly while it is changed: exit code 3, got $code"
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) '-RestoreOnly while it is changed moved nothing'
        Remove-Item -LiteralPath $added -Force
        Check ((Get-Snapshot $backups[0].FullName) -eq $before) 'without the change the backup holds the original data'
    }
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly after the change is undone: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original is back unchanged'

    Start-Case 'the backup changes between the check of -RestoreOnly and its rename: stop before the move'
    $base = New-InterruptedBase 'tamper-restore'
    $code = Invoke-Check $base @('-RestoreOnly', '-TestFault', 'tamper-backup')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-LastOutput) -match 'it was not moved') 'it says the backup was not moved'
    Check (-not (Test-Path -LiteralPath (Get-Root $base))) 'the data path is not occupied by the backup'
    $backups = @(Get-Backups $base)
    Check ($backups.Count -eq 1) 'the backup is where it was'
    if ($backups.Count -eq 1) { Remove-Item -LiteralPath (Join-Path $backups[0].FullName 'added-by-the-fault.txt') -Force }
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly after the change is undone: exit code 0, got $code"
    Check ((Test-Path -LiteralPath (Join-Path (Join-Path (Get-Root $base) 'data') 'atlas.db')) -and @(Get-Backups $base).Count -eq 0) 'the original is back'

    # ---------------------------------------------------------------------------
    # Group A: the sentinel of the installed test directory is lost
    # ---------------------------------------------------------------------------

    function Get-RunIds([string]$Base) {
        return @(Get-Manifests $Base | ForEach-Object { $_.BaseName.Substring('manifest-'.Length) })
    }

    function Get-Instructions([string]$Base) {
        $text = ''
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Base 'home') -Recurse -Filter 'RESTORE-INSTRUCTIONS*.txt')) {
            $text += [System.IO.File]::ReadAllText($file.FullName)
        }
        return $text
    }

    # The command the instructions give to close run $Id by hand, as written
    # into RESTORE-INSTRUCTIONS.txt, or '' when there is none.
    function Get-ManualCloseCommand([string]$Base, [string]$Id) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Base 'home') -Recurse -Filter 'RESTORE-INSTRUCTIONS*.txt' | Sort-Object LastWriteTime -Descending)) {
            foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                if ($line.Contains('WriteAllLines(') -and $line.Contains("'$Id'")) { return $line.Trim() }
            }
        }
        return ''
    }

    # Runs that command, exactly as a user would paste it.
    function Invoke-ManualClose([string]$Base, [string]$Id) {
        $command = Get-ManualCloseCommand $Base $Id
        Check ($command -ne '') 'the instructions give a command that closes the run by hand'
        Check ($command -notmatch 'New-Item') 'the command does not create an empty file'
        if ($command -ne '') { Invoke-Expression $command }
    }

    function Get-DonePath([string]$Base, [string]$Id) { return (Join-Path (Get-StateDir $Base) "done-$Id.txt") }

    function Get-TempMarkers([string]$Base) {
        $state = Get-StateDir $Base
        if (-not (Test-Path -LiteralPath $state)) { return @() }
        return @(Get-ChildItem -LiteralPath $state -Force | Where-Object { $_.Name.StartsWith('tmp-done-') })
    }

    function Get-ManifestHashes([string]$Base) {
        return (@(Get-Manifests $Base | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ',')
    }

    function Test-Done([string]$Base, [string]$Id) {
        return (Test-Path -LiteralPath (Join-Path (Get-StateDir $Base) "done-$Id.txt"))
    }

    # What every case of this group must show after a stop.
    function Check-SentinelStop([string]$Base, [int]$Code, [string]$Id, [string]$ManifestHashes) {
        $output = Get-LastOutput
        Check ($Code -eq 3) "exit code 3, got $Code"
        Check ($output -notmatch 'Nothing to restore') 'it does not say "nothing to restore"'
        Check ($output -match 'original path restored:\s+NO') 'the data path is not reported as restored'
        Check ($output -notmatch 'Test directory moved|Test directory renamed|Original data directory restored') 'nothing was moved or restored'
        Check (Test-Path -LiteralPath (Get-Root $Base) -PathType Container) 'the unknown directory is still in the data path'
        Check ((Get-ManifestHashes $Base) -eq $ManifestHashes) 'the manifest is unchanged'
        Check (-not (Test-Done $Base $Id)) 'the run is not marked as finished'
        $instructions = Get-Instructions $Base
        Check ($instructions.Contains($Id)) 'the instructions name the run id'
        Check ($instructions.Contains((Get-Root $Base))) 'the instructions name the data path'
        Check ($instructions -match 'NOT moved, deleted or overwritten') 'the instructions say what is not moved automatically'
    }

    foreach ($entry in @(
            @{ Name = 'removed'; Fault = 'drop-sentinel'; Original = $false },
            @{ Name = 'damaged'; Fault = 'damage-sentinel'; Original = $false },
            @{ Name = 'removed'; Fault = 'drop-sentinel'; Original = $true },
            @{ Name = 'damaged'; Fault = 'damage-sentinel'; Original = $true })) {
        $kind = 'no data directory before the run'
        if ($entry.Original) { $kind = 'data directory and backup' }
        Start-Case "A: $kind, test directory installed, sentinel $($entry.Name): stop, nothing moved; resolved by hand, then -RestoreOnly"
        $base = New-Base ("sentinel-" + [guid]::NewGuid().ToString('N').Substring(0, 8)) $entry.Original
        $before = '<absent>'
        if ($entry.Original) { $before = Get-Snapshot (Get-Root $base) }
        $code = Invoke-Check $base @('-TestFault', $entry.Fault)
        $id = @(Get-RunIds $base)[0]
        $hashes = Get-ManifestHashes $base
        Check-SentinelStop $base $code $id $hashes
        $unknown = Get-Snapshot (Get-Root $base)
        $backups = @(Get-Backups $base)
        if ($entry.Original) {
            Check ($backups.Count -eq 1) 'exactly one backup directory'
            if ($backups.Count -eq 1) { Check ((Get-Snapshot $backups[0].FullName) -eq $before) 'the backup holds the original data unchanged' }
        } else {
            Check ($backups.Count -eq 0) 'no backup directory (there was no data directory)'
        }
        # -RestoreOnly cannot decide either.
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @('-RestoreOnly')
        Check-SentinelStop $base $code $id $hashes
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) '-RestoreOnly moved nothing'
        # A new run must not take the unknown directory for the data of the user.
        $code = Invoke-Check $base @()
        Check ($code -eq 3) "a new run refuses with 3, got $code"
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the refused run changed nothing'
        Check ((Get-Snapshot (Get-Root $base)) -eq $unknown) 'the unknown directory was not overwritten'
        # By hand: the user looks into the directory and moves it away.
        Move-Item -LiteralPath (Get-Root $base) -Destination (Join-Path $base 'moved-away-by-hand')
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 0) "-RestoreOnly after the directory was moved away by hand: exit code 0, got $code"
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data path holds exactly what was there before the run'
        Check (@(Get-Backups $base).Count -eq 0) 'no backup directory is left'
        Check (Test-Done $base $id) 'the run is marked as finished'
        Check ((Get-ManifestHashes $base) -eq $hashes) 'the manifest is still unchanged'
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 0) "second -RestoreOnly: exit code 0, got $code"
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the second -RestoreOnly changed nothing'
        $code = Invoke-Check $base @()
        Check ($code -eq 0) "a normal run works again: exit code 0, got $code"
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'and leaves the data path as it was'
    }

    Start-Case 'A: interrupted run without a data directory, sentinel removed afterwards: -RestoreOnly does not say "nothing to restore"'
    $base = New-InterruptedBase 'sentinel-interrupted' $false
    $id = @(Get-RunIds $base)[0]
    $hashes = Get-ManifestHashes $base
    Remove-Item -LiteralPath (Join-Path (Get-Root $base) $SentinelName) -Force
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check-SentinelStop $base $code $id $hashes
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'

    Start-Case 'A: the manifest says the test directory was installed, but the data path holds an unknown directory: stop; acknowledged by hand'
    $base = New-InterruptedBase 'unknown-directory' $false
    $id = @(Get-RunIds $base)[0]
    $hashes = Get-ManifestHashes $base
    Move-Item -LiteralPath (Get-Root $base) -Destination (Join-Path $base 'test-dir-taken-out-by-the-test')
    New-Item -ItemType Directory -Path (Join-Path (Get-Root $base) 'data') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path (Join-Path (Get-Root $base) 'data') 'atlas.db'), 'data that appeared later')
    $unknown = Get-Snapshot (Get-Root $base)
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check-SentinelStop $base $code $id $hashes
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved'
    $code = Invoke-Check $base @()
    Check ($code -eq 3) "a new run refuses with 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the refused run changed nothing'
    # An empty "done" file, the old way to close a run, is not accepted any more.
    $empty = Join-Path (Get-StateDir $base) "done-$id.txt"
    New-Item -ItemType File -Path $empty | Out-Null
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "an empty done file does not close the run: exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was moved and the empty file was not changed'
    Remove-Item -LiteralPath $empty -Force
    # By hand: the user decides that the directory is data and closes the run with the command of the instructions.
    Invoke-ManualClose $base $id
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly after the run was closed by hand: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $unknown) 'the directory in the data path was not touched'

    Start-Case 'A: a truly clean state still means "nothing to restore"'
    $base = New-Base 'clean-state'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "exit code 0, got $code"
    Check ((Get-LastOutput) -match 'Nothing to restore') 'it says "nothing to restore"'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was changed'

    Start-Case "A: fault 'touched-write': the data path was not touched"
    $base = New-Base 'fault-touched-write'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'touched-write')
    Check ($code -eq 1) "exit code 1, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the original data is unchanged and in its place'
    Check (@(Get-Backups $base).Count -eq 0) 'no backup directory'

    # ---------------------------------------------------------------------------
    # Group B: the check after the rename back does not pass
    # ---------------------------------------------------------------------------

    # What every case of this group must show after the failed second check.
    function Check-UnconfirmedRestore([string]$Base, [int]$Code, [string]$Id) {
        $output = Get-LastOutput
        Check ($Code -eq 3) "exit code 3, got $Code"
        Check ($output -match 'original path restored:\s+NO') 'the restore is not reported as confirmed'
        Check ($output -match 'fingerprint NOT confirmed') 'the outcome says where the data is and that it is not confirmed'
        Check ($output -notmatch 'Original data directory restored') 'it does not say "restored"'
        Check (Test-Path -LiteralPath (Join-Path (Join-Path (Get-Root $Base) 'data') 'atlas.db')) 'the directory really is in the data path'
        Check (@(Get-Backups $Base).Count -eq 0) 'no backup directory is left (it was renamed back)'
        Check (-not (Test-Done $Base $Id)) 'the run is not marked as finished'
        $instructions = Get-Instructions $Base
        Check ($instructions -match 'ALREADY renamed back') 'the instructions say the directory is already in the data path'
        Check ($instructions -match 'NOT confirmed') 'the instructions say the restore is not confirmed'
        Check ($instructions.Contains($Id)) 'the instructions name the run id'
    }

    Start-Case 'B: the directory differs after the rename back: restore fails with 3; -RestoreOnly overwrites nothing; fixed by hand'
    $base = New-Base 'postcheck-mismatch'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'tamper-after-restore')
    $id = @(Get-RunIds $base)[0]
    $hashes = Get-ManifestHashes $base
    Check-UnconfirmedRestore $base $code $id
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "-RestoreOnly: exit code 3, got $code"
    Check ((Get-LastOutput) -notmatch 'Nothing to restore') 'it does not say "nothing to restore"'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) '-RestoreOnly moved and overwrote nothing'
    $code = Invoke-Check $base @()
    Check ($code -eq 3) "a new run refuses with 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the refused run changed nothing'
    # By hand: the user removes what does not belong there.
    Remove-Item -LiteralPath (Join-Path (Get-Root $base) 'added-after-restore.txt') -Force
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly after the fix: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data path holds the original data unchanged'
    Check (Test-Done $base $id) 'the run is marked as finished'
    Check ((Get-ManifestHashes $base) -eq $hashes) 'the manifest is unchanged'

    Start-Case 'B: the check after the rename back cannot be done: restore fails with 3; a later -RestoreOnly confirms it'
    $base = New-Base 'postcheck-error'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'postcheck-error')
    $id = @(Get-RunIds $base)[0]
    Check-UnconfirmedRestore $base $code $id
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the contents in the data path are the original ones'
    $code = Invoke-Check $base @('-RestoreOnly', '-TestFault', 'postcheck-error')
    Check ($code -eq 0 -or $code -eq 3) "a second -RestoreOnly ends with 0 or 3, got $code"
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data path holds the original data unchanged'
    Check (Test-Done $base $id) 'the run is marked as finished'

    foreach ($entry in @(
            @{ Name = 'interrupted after the isolation'; Fault = 'crash-after-isolation' },
            @{ Name = 'interrupted right after the rename'; Fault = 'crash-after-backup' })) {
        Start-Case "B: -RestoreOnly ($($entry.Name)) meets the failed second check: 3, then no overwrite, then fixed by hand"
        $base = New-Base ("postcheck-restore-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $before = Get-Snapshot (Get-Root $base)
        $code = Invoke-Check $base @('-TestFault', $entry.Fault)
        Check ($code -eq 99) "setup: the interrupted run ends with 99, got $code"
        $id = @(Get-RunIds $base)[0]
        $code = Invoke-Check $base @('-RestoreOnly', '-TestFault', 'tamper-after-restore')
        Check-UnconfirmedRestore $base $code $id
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 3) "second -RestoreOnly: exit code 3, got $code"
        Check ((Get-LastOutput) -notmatch 'Nothing to restore') 'it does not say "nothing to restore"'
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the second -RestoreOnly moved and overwrote nothing'
        Remove-Item -LiteralPath (Join-Path (Get-Root $base) 'added-after-restore.txt') -Force
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 0) "-RestoreOnly after the fix: exit code 0, got $code"
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data path holds the original data unchanged'
    }

    # ---------------------------------------------------------------------------
    # Group C: the "done" marker
    # ---------------------------------------------------------------------------

    function Get-ValidDoneLines([string]$Id) {
        return @('format=atlas-sqlite-check-marker-1', 'kind=done', "run_id=$Id", 'written=20261116-093000', "end=$Id")
    }

    Start-Case 'C: the marker the script writes is whole, and a finished run stays finished'
    $base = New-Base 'done-own'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @()
    Check ($code -eq 0) "exit code 0, got $code"
    $id = @(Get-RunIds $base)[0]
    $done = Get-DonePath $base $id
    Check (Test-Path -LiteralPath $done -PathType Leaf) 'the done marker exists'
    $lines = @([System.IO.File]::ReadAllLines($done))
    Check ($lines.Count -eq 5 -and $lines[0] -ceq 'format=atlas-sqlite-check-marker-1' -and $lines[1] -ceq 'kind=done' -and $lines[2] -ceq "run_id=$id" -and $lines[3] -cmatch '^written=\d{8}-\d{6}$' -and $lines[4] -ceq "end=$id") 'it has exactly the five documented lines'
    Check (@(Get-TempMarkers $base).Count -eq 0) 'no temporary file is left'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "-RestoreOnly: exit code 0, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the valid marker was not rewritten and nothing was moved'

    $foreign = [guid]::NewGuid().ToString('N')
    foreach ($entry in @(
            @{ Name = 'empty'; Kind = 'lines'; Lines = @() },
            @{ Name = 'cut short (three of five lines)'; Kind = 'cut' },
            @{ Name = 'cut short (the last line is missing)'; Kind = 'cut4' },
            @{ Name = 'with the run id of another run'; Kind = 'foreign' },
            @{ Name = 'in the old two-line format'; Kind = 'old' },
            @{ Name = 'with an extra line'; Kind = 'extra' },
            @{ Name = 'that only contains the run id somewhere'; Kind = 'substring' },
            @{ Name = 'that cannot be read (a directory of that name)'; Kind = 'directory' })) {
        Start-Case "C: a done marker $($entry.Name) does not close the run: exit 3, nothing changed; replaced by hand, then fine"
        $base = New-Base ("done-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $before = Get-Snapshot (Get-Root $base)
        $code = Invoke-Check $base @()
        Check ($code -eq 0) "setup: a normal run ends with 0, got $code"
        $id = @(Get-RunIds $base)[0]
        $done = Get-DonePath $base $id
        $hashes = Get-ManifestHashes $base
        $valid = Get-ValidDoneLines $id
        Remove-Item -LiteralPath $done -Force
        switch ($entry.Kind) {
            'lines' { [System.IO.File]::WriteAllLines($done, [string[]]@()) }
            'cut' { [System.IO.File]::WriteAllLines($done, [string[]]@($valid[0..2])) }
            'cut4' { [System.IO.File]::WriteAllLines($done, [string[]]@($valid[0..3])) }
            'foreign' { [System.IO.File]::WriteAllLines($done, [string[]]@(Get-ValidDoneLines $foreign)) }
            'old' { [System.IO.File]::WriteAllLines($done, [string[]]@("run_id=$id", 'written=20261116-093000')) }
            'extra' { [System.IO.File]::WriteAllLines($done, [string[]]@($valid + @('more=1'))) }
            'substring' { [System.IO.File]::WriteAllLines($done, [string[]]@($valid[0], $valid[1], "x run_id=$id y", $valid[3], $valid[4])) }
            'directory' { New-Item -ItemType Directory -Path $done | Out-Null }
        }
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @('-RestoreOnly')
        $output = Get-LastOutput
        Check ($code -eq 3) "-RestoreOnly: exit code 3, got $code"
        Check ($output -notmatch 'Nothing to restore') 'it does not say "nothing to restore"'
        Check ($output -match 'not a valid "done" marker') 'the invalid marker is reported'
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the marker was not changed and nothing was moved'
        $instructions = Get-Instructions $base
        Check ($instructions.Contains($done)) 'the instructions name the exact path of the marker'
        Check ($instructions.Contains($id)) 'the instructions name the run id'
        Check ($instructions -match 'repairs nothing and restores nothing') 'the instructions say what the marker does not do'
        Check ($instructions -match 'do NOT create the marker') 'the instructions say when not to create it'
        Check ($instructions -notmatch 'New-Item -ItemType File') 'the instructions do not offer an empty file'
        # A new run and a second -RestoreOnly: the same, still nothing changed.
        $code = Invoke-Check $base @()
        Check ($code -eq 3) "a new run refuses with 3, got $code"
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 3) "second -RestoreOnly: exit code 3, got $code"
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'still nothing was changed'
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data of the user is unchanged'
        Check ((Get-ManifestHashes $base) -eq $hashes) 'the manifest is unchanged'
        # By hand, as the instructions say: the invalid file aside, the whole marker in its place.
        Rename-Item -LiteralPath $done -NewName ("invalid-" + (Split-Path -Leaf $done))
        Invoke-ManualClose $base $id
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 0) "-RestoreOnly after the marker was replaced by hand: exit code 0, got $code"
        $code = Invoke-Check $base @()
        Check ($code -eq 0) "a normal run works again: exit code 0, got $code"
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data of the user is unchanged'
    }

    Start-Case 'C: an invalid done marker while a backup and a test directory wait: nothing is moved; without it the restore goes on'
    $base = New-InterruptedBase 'done-pending'
    $id = @(Get-RunIds $base)[0]
    $done = Get-DonePath $base $id
    [System.IO.File]::WriteAllText($done, '')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-LastOutput) -notmatch 'Test directory moved|Original data directory restored') 'neither the test directory nor the backup was moved'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was changed'
    Check (@(Get-Backups $base).Count -eq 1 -and (Test-IsTestDir (Get-Root $base))) 'the backup and the test directory are where they were'
    Rename-Item -LiteralPath $done -NewName "invalid-done-$id.txt"
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "after the file was moved aside: exit code 0, got $code"
    Check (@(Get-Backups $base).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path (Join-Path (Get-Root $base) 'data') 'atlas.db'))) 'the original is back'
    Check (@([System.IO.File]::ReadAllLines($done)).Count -eq 5) 'the script wrote the whole marker itself'

    Start-Case 'C: the markers cannot be read at all: a refusal'
    $base = New-Base 'done-read-error'
    $code = Invoke-Check $base @()
    Check ($code -eq 0) "setup: a normal run ends with 0, got $code"
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly', '-TestFault', 'done-read-error')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-LastOutput) -notmatch 'Nothing to restore') 'it does not say "nothing to restore"'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was changed'

    Start-Case 'C: a file named like a done marker without a run id is reported, not ignored'
    $base = New-Base 'done-no-id'
    $code = Invoke-Check $base @()
    $stray = Join-Path (Get-StateDir $base) 'done-run id.txt'
    [System.IO.File]::WriteAllText($stray, 'x')
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was changed'

    Start-Case 'C: a temporary marker file that was left behind does not close the run'
    $base = New-InterruptedBase 'done-temp-left' $false
    $id = @(Get-RunIds $base)[0]
    Remove-Item -LiteralPath (Join-Path (Get-Root $base) $SentinelName) -Force
    $temp = Join-Path (Get-StateDir $base) "tmp-done-$id-$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllLines($temp, [string[]]@(Get-ValidDoneLines $id))
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "exit code 3, got $code"
    Check (-not (Test-Path -LiteralPath (Get-DonePath $base $id))) 'no done marker appeared'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the temporary file was neither used nor deleted, nothing was moved'

    foreach ($entry in @(
            @{ Name = 'the temporary file cannot be written'; Fault = 'done-temp-write'; Temp = 0 },
            @{ Name = 'the temporary file is written only in part'; Fault = 'done-temp-partial'; Temp = 1 },
            @{ Name = 'the rename into place fails'; Fault = 'done-rename'; Temp = 1 })) {
        Start-Case "C: $($entry.Name): no done marker, exit 3; a later -RestoreOnly closes the run"
        $base = New-Base ("done-w-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $before = Get-Snapshot (Get-Root $base)
        $code = Invoke-Check $base @('-TestFault', $entry.Fault)
        $id = @(Get-RunIds $base)[0]
        $done = Get-DonePath $base $id
        Check ($code -eq 3) "exit code 3 (the run is not confirmed as finished), got $code"
        Check (-not (Test-Path -LiteralPath $done)) 'no done marker exists'
        Check (@(Get-TempMarkers $base).Count -eq $entry.Temp) "temporary files left: $($entry.Temp) (they are not deleted)"
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data of the user is in its place and unchanged'
        Check ((Get-LastOutput) -match 'could not be marked as finished') 'the reason is named'
        $temps = @(Get-TempMarkers $base | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ','
        $code = Invoke-Check $base @('-RestoreOnly')
        Check ($code -eq 0) "-RestoreOnly: exit code 0, got $code"
        Check (@([System.IO.File]::ReadAllLines($done)).Count -eq 5) 'the whole done marker is written now'
        Check ((@(Get-TempMarkers $base | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ',') -eq $temps) 'the old temporary files are still there, unchanged, and no new one is left'
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data of the user is unchanged'
    }

    Start-Case 'C: a file that takes the final name at the last moment is never overwritten'
    $base = New-Base 'done-final-appears'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-TestFault', 'done-final-appears')
    $id = @(Get-RunIds $base)[0]
    $done = Get-DonePath $base $id
    Check ($code -eq 3) "exit code 3, got $code"
    Check (([System.IO.File]::ReadAllText($done)) -eq 'not written by this run') 'the file that was there first is unchanged'
    Check (@(Get-TempMarkers $base).Count -eq 1) 'the temporary file stays'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 3) "-RestoreOnly: exit code 3 (the file is not a valid marker), got $code"
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'nothing was changed'
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data of the user is unchanged'
    Rename-Item -LiteralPath $done -NewName "invalid-done-$id.txt"
    $code = Invoke-Check $base @('-RestoreOnly')
    Check ($code -eq 0) "after the file was moved aside: exit code 0, got $code"

    # ---------------------------------------------------------------------------
    # Group D: finding the application, without paths of the repository
    # ---------------------------------------------------------------------------

    # A stand-in for the application, at a path below the test profile.
    function New-FakeExe([string]$Base, [string]$Relative) {
        $path = Join-Path $Base $Relative
        if (-not $OnWindows) { $path = $path -replace '\\', '/' -replace '\.exe$', '' }
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, 'not really ATLAS')
        return $path
    }

    # What a refusal before any change must show.
    function Check-EarlyStop([string]$Base, [int]$Code, [string]$State, [string]$Pattern) {
        Check ($Code -eq 2) "exit code 2, got $Code"
        Check ((Get-Snapshot (Get-Local $Base)) -eq $State) 'nothing was changed'
        Check (@(Get-Manifests $Base).Count -eq 0) 'no manifest was written'
        $runs = @(Get-ChildItem -LiteralPath (Join-Path $Base 'home') -Recurse -Filter 'run.txt')
        $text = ''
        foreach ($file in $runs) { $text += [System.IO.File]::ReadAllText($file.FullName) }
        Check ($text -match 'STOPPED before any change') 'the stop is written to run.txt'
        Check ($text -match $Pattern) 'the reason is written to run.txt'
        Check ((Get-LastOutput) -match 'original path restored:\s+yes') 'the outcome says the data is in its place'
    }

    Start-Case 'D: -Exe that does not exist: refuse before any change, the reason is in the report'
    $base = New-Base 'exe-missing'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-Exe', (Join-Path $base 'nowhere\atlas.exe'))
    Check-EarlyStop $base $code $state 'does not exist'

    Start-Case 'D: no -Exe and nothing found: refuse before any change, the places searched are listed'
    $base = New-Base 'exe-none'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-TestFault', 'resolve-exe')
    Check-EarlyStop $base $code $state 'was not found'
    Check ((Get-LastOutput) -match 'ATLAS') 'the places searched are named'

    Start-Case 'D: no -Exe and two copies found: no guess, refuse before any change'
    $base = New-Base 'exe-two'
    $null = New-FakeExe $base 'cwd\atlas.exe'
    $null = New-FakeExe $base 'local\ATLAS\ATLAS.exe'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-TestFault', 'resolve-exe')
    Check-EarlyStop $base $code $state 'Several copies'

    foreach ($entry in @(
            @{ Name = 'a build in the current directory'; Path = 'cwd\src-tauri\target\release\atlas.exe' },
            @{ Name = 'a copy next to the script'; Path = 'scriptdir\atlas.exe' },
            @{ Name = 'an installed copy below %LOCALAPPDATA%'; Path = 'local\ATLAS\ATLAS.exe' },
            @{ Name = 'an installed copy below Program Files'; Path = 'programfiles\ATLAS\ATLAS.exe' })) {
        Start-Case "D: no -Exe, only $($entry.Name): it is used, the data comes back"
        $base = New-Base ("exe-one-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $fake = New-FakeExe $base $entry.Path
        $before = Get-Snapshot (Get-Root $base)
        $code = Invoke-Check $base @('-TestFault', 'resolve-exe')
        Check ($code -eq 0) "exit code 0, got $code"
        Check ((Get-LastOutput).Contains("Application: $fake")) 'the copy found is named'
        Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data of the user is unchanged'
    }

    Start-Case 'D: environment.txt records the SHA-256 of the script itself'
    $base = New-Base 'script-hash'
    $code = Invoke-Check $base @()
    $environment = ''
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $base 'home') -Recurse -Filter 'environment.txt')) { $environment += [System.IO.File]::ReadAllText($file.FullName) }
    Check ($environment.Contains("script sha256: $((Get-FileHash -LiteralPath $Script -Algorithm SHA256).Hash)")) 'the hash is the hash of this file'

    Start-Case 'D: -Exe of a file that exists: it is used and recorded with its hash'
    $base = New-Base 'exe-given'
    $fake = New-FakeExe $base 'elsewhere\with space\atlas.exe'
    $before = Get-Snapshot (Get-Root $base)
    $code = Invoke-Check $base @('-Exe', $fake)
    Check ($code -eq 0) "exit code 0, got $code"
    $environment = ''
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $base 'home') -Recurse -Filter 'environment.txt')) { $environment += [System.IO.File]::ReadAllText($file.FullName) }
    Check ($environment.Contains("exe: $fake")) 'environment.txt names the application'
    Check ($environment -match 'exe sha256: [0-9A-F]{64}') 'environment.txt has its hash'
    Check ((Get-Snapshot (Get-Root $base)) -eq $before) 'the data of the user is unchanged'

    Start-Case 'D: -Build without -Source and outside a repository: refuse before any change'
    $base = New-Base 'build-no-source'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-Build')
    Check-EarlyStop $base $code $state 'needs a copy of the ATLAS repository'

    Start-Case 'D: -Build with a -Source that does not exist: refuse before any build and any change'
    $base = New-Base 'build-source-missing'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-Build', '-Source', (Join-Path $base 'no such folder'))
    Check-EarlyStop $base $code $state 'not an existing directory'

    # A directory with the signs of the ATLAS repository, or with one of them wrong.
    function New-SourceTree([string]$Directory, [hashtable]$With) {
        $o = @{ PackageName = 'atlas'; Build = $true; CargoName = 'atlas'; LibName = 'atlas_lib'; Identifier = 'com.inlerno.atlas'; ProductName = 'ATLAS' }
        foreach ($key in $With.Keys) { $o[$key] = $With[$key] }
        $tauriDir = Join-Path $Directory 'src-tauri'
        New-Item -ItemType Directory -Path $tauriDir -Force | Out-Null
        $packagePath = Join-Path $Directory 'package.json'
        $cargoPath = Join-Path $tauriDir 'Cargo.toml'
        $confPath = Join-Path $tauriDir 'tauri.conf.json'

        $scripts = '"dev": "vite"'
        if ($o.Build) { $scripts = '"dev": "vite", "build": "tsc && vite build", "tauri": "tauri"' }
        $package = '{ "name": "' + $o.PackageName + '", "private": true, "version": "0.1.0", "scripts": { ' + $scripts + ' } }'
        if ($o.ContainsKey('PackageText')) { $package = $o.PackageText }
        if ($o.ContainsKey('PackageIsDirectory')) { New-Item -ItemType Directory -Path $packagePath | Out-Null }
        else { [System.IO.File]::WriteAllText($packagePath, $package) }

        $cargo = @('[package]', ('name = "' + $o.CargoName + '"'), 'version = "0.1.0"', 'edition = "2024"', '')
        if ($o.LibName) { $cargo += @('[lib]', ('name = "' + $o.LibName + '"  # the library'), 'crate-type = ["staticlib", "cdylib", "rlib"]', '') }
        $cargo += @('[dependencies]', 'tauri = { version = "2", features = [] }')
        if ($o.ContainsKey('CargoLines')) { $cargo = $o.CargoLines }
        if ($o.ContainsKey('CargoIsDirectory')) { New-Item -ItemType Directory -Path $cargoPath | Out-Null }
        else { [System.IO.File]::WriteAllLines($cargoPath, [string[]]$cargo) }

        $conf = '{ "$schema": "https://schema.tauri.app/config/2", "productName": "' + $o.ProductName + '", "version": "0.1.0", "identifier": "' + $o.Identifier + '", "build": { "frontendDist": "../dist" } }'
        if ($o.ContainsKey('ConfText')) { $conf = $o.ConfText }
        if ($o.ContainsKey('ConfIsDirectory')) { New-Item -ItemType Directory -Path $confPath | Out-Null }
        elseif (-not $o.ContainsKey('NoConf')) { [System.IO.File]::WriteAllText($confPath, $conf) }
    }

    foreach ($entry in @(
            @{ Name = 'minimal {} and [package] (what used to be accepted)'; With = @{ PackageText = '{}'; CargoLines = @('[package]'); NoConf = $true }; Pattern = 'package\.json: "name" is not "atlas"' },
            @{ Name = 'another, complete Tauri project'; With = @{ PackageName = 'other-app'; CargoName = 'other-app'; LibName = 'other_app_lib'; Identifier = 'com.example.other'; ProductName = 'Other' }; Pattern = 'package\.json: "name" is not "atlas"' },
            @{ Name = 'a wrong package name in package.json'; With = @{ PackageName = 'atlas-fork' }; Pattern = 'package\.json: "name" is not "atlas"' },
            @{ Name = 'a package.json without a build script'; With = @{ Build = $false }; Pattern = 'there is no "build" script' },
            @{ Name = 'a wrong package name in Cargo.toml'; With = @{ CargoName = 'not-atlas' }; Pattern = 'name in \[package\] is not "atlas"' },
            @{ Name = 'the name "atlas" only in [dependencies]'; With = @{ CargoLines = @('[package]', 'version = "0.1.0"', '', '[lib]', 'name = "atlas_lib"', '', '[dependencies]', 'name = "atlas"') }; Pattern = 'name in \[package\] is not "atlas"' },
            @{ Name = 'a Cargo.toml without [lib]'; With = @{ LibName = '' }; Pattern = 'name in \[lib\] is not "atlas_lib"' },
            @{ Name = 'a wrong library name'; With = @{ LibName = 'other_lib' }; Pattern = 'name in \[lib\] is not "atlas_lib"' },
            @{ Name = 'two names in [package]'; With = @{ CargoLines = @('[package]', 'name = "atlas"', 'name = "atlas"', '[lib]', 'name = "atlas_lib"') }; Pattern = 'two names in \[package\]' },
            @{ Name = 'no tauri.conf.json'; With = @{ NoConf = $true }; Pattern = 'tauri\.conf\.json is missing' },
            @{ Name = 'a wrong identifier'; With = @{ Identifier = 'com.example.atlas' }; Pattern = '"identifier" is not "com\.inlerno\.atlas"' },
            @{ Name = 'a wrong product name'; With = @{ ProductName = 'Atlas Fork' }; Pattern = '"productName" is not "ATLAS"' },
            @{ Name = 'a package.json that is not valid JSON'; With = @{ PackageText = '{ "name": "atlas", ' }; Pattern = 'package\.json is not valid JSON' },
            @{ Name = 'a package.json that is a JSON array'; With = @{ PackageText = '["atlas"]' }; Pattern = 'package\.json is not a JSON object' },
            @{ Name = 'a tauri.conf.json that is not valid JSON'; With = @{ ConfText = '{ "identifier": "com.inlerno.atlas" ' }; Pattern = 'tauri\.conf\.json is not valid JSON' },
            @{ Name = 'a directory in the place of package.json'; With = @{ PackageIsDirectory = $true }; Pattern = 'package\.json is missing' },
            @{ Name = 'a directory in the place of Cargo.toml'; With = @{ CargoIsDirectory = $true }; Pattern = 'Cargo\.toml is missing' },
            @{ Name = 'a directory in the place of tauri.conf.json'; With = @{ ConfIsDirectory = $true }; Pattern = 'tauri\.conf\.json is missing' })) {
        Start-Case "D: -Source with $($entry.Name) is refused before any build and any change"
        $base = New-Base ("src-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $source = Join-Path $base 'some source'
        New-SourceTree $source $entry.With
        $sourceState = Get-Snapshot $source
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @('-Build', '-Source', $source)
        Check-EarlyStop $base $code $state 'not a copy of the ATLAS repository'
        $output = Get-LastOutput
        Check ($output -match $entry.Pattern) 'the exact reason is named'
        Check ($output -notmatch 'Building the application|was accepted') 'no build was started and the source was not accepted'
        Check ((Get-Snapshot $source) -eq $sourceState) 'nothing was written into the source (no node_modules, no target)'
    }

    Start-Case 'D: a directory with all the signs of ATLAS is accepted as a source, and the tests still build nothing'
    $base = New-Base 'src-right'
    $right = Join-Path $base 'repo copy'
    New-SourceTree $right @{}
    $sourceState = Get-Snapshot $right
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Check $base @('-Build', '-Source', $right)
    Check-EarlyStop $base $code $state 'was accepted'
    Check ((Get-LastOutput) -notmatch 'Building the application') 'no build was started'
    Check ((Get-Snapshot $right) -eq $sourceState) 'nothing was written into the source'

    Start-Case 'D: the real ATLAS repository this script lies in is accepted as a source'
    # Not a copy made by the test: the checkout itself. This file lies in
    # <repository>\tools\windows, so the repository is two levels up. It counts
    # as the real checkout only with what a test copy does not have: the Git
    # metadata, this very file at its place, the CI workflow and the storage
    # code the script checks. In GitHub Actions it must also be the workspace.
    $checkout = ''
    $why = ''
    $inActions = ($env:GITHUB_ACTIONS -eq 'true')
    $twoUp = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (-not $twoUp) { $why = 'the script does not lie two levels below anything' }
    elseif ((Split-Path -Leaf $PSScriptRoot) -ne 'windows' -or (Split-Path -Leaf (Split-Path -Parent $PSScriptRoot)) -ne 'tools') { $why = "the script lies in $PSScriptRoot, not in tools\windows of a repository" }
    else {
        foreach ($needed in @('.git', '.github/workflows/ci.yml', 'src-tauri/src/storage/mod.rs', 'src-tauri/Cargo.lock', 'package-lock.json')) {
            if (-not $why -and -not (Test-Path -LiteralPath (Join-Path $twoUp $needed))) { $why = "$twoUp has no $needed" }
        }
        if (-not $why) { $checkout = $twoUp }
    }
    if ($checkout -and $inActions) {
        Check (Test-SamePathForTest $checkout $env:GITHUB_WORKSPACE) "in GitHub Actions the checkout is the workspace ($env:GITHUB_WORKSPACE)"
    }
    if (-not $checkout) {
        if ($inActions) { Check $false "in GitHub Actions the real checkout must be found, and it was not: $why" }
        else { Skip-Case "the script is not run from a checkout of ATLAS ($why)" }
    } else {
        $base = New-Base 'src-real'
        $state = Get-Snapshot (Get-Local $base)
        $code = Invoke-Check $base @('-Build', '-Source', $checkout)
        Check-EarlyStop $base $code $state 'was accepted'
        Check ((Get-LastOutput).Contains("the source $checkout was accepted")) 'the checkout itself is the source that was accepted'
        Check ((Get-LastOutput) -notmatch 'Building the application') 'no build was started'
    }

    # ---------------------------------------------------------------------------
    # Group E: the record of the profile (on temporary trees only)
    # ---------------------------------------------------------------------------

    # A folder that stands for %LOCALAPPDATA%, with a data directory, a backup
    # and something that is not ATLAS.
    function New-ProfileTree([string]$Name) {
        $parent = Join-Path $Work $Name
        $root = Join-Path $parent $AppId
        New-Item -ItemType Directory -Path (Join-Path (Join-Path $root 'data') 'deep') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'empty') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $root 'data') 'atlas.db'), 'database')
        [System.IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $root 'data') 'deep') 'nested.txt'), 'nested')
        [System.IO.File]::WriteAllText((Join-Path $root 'storage.initialized'), 'marker')
        $backup = Join-Path $parent "$AppId.sqlite-check-backup-x"
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $backup 'kept.txt'), 'backup')
        New-Item -ItemType Directory -Path (Join-Path $parent 'another.app') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $parent 'another.app') 'file.txt'), 'not ATLAS')
        return $parent
    }

    # The error a record ends with, or '' when it is taken.
    function Get-SnapshotError([string]$Parent) {
        try { $null = Get-ProfileSnapshot $Parent; return '' } catch { return "$($_.Exception.Message)" }
    }

    Start-Case 'E: the record holds nested directories and files with size and SHA-256, and nothing that is not ATLAS'
    $tree = New-ProfileTree 'snap-nested'
    $one = Get-ProfileSnapshot $tree
    $expectedHash = (Get-FileHash -LiteralPath (Join-Path (Join-Path (Join-Path (Join-Path $tree $AppId) 'data') 'deep') 'nested.txt') -Algorithm SHA256).Hash
    Check ($one.Contains("d|$AppId/data/deep")) 'a nested directory is recorded as a directory'
    Check ($one.Contains("d|$AppId/empty")) 'an empty directory is recorded'
    Check ($one.Contains("f|$AppId/data/deep/nested.txt|6|$expectedHash")) 'a nested file is recorded with its size and SHA-256'
    Check ($one.Contains("f|$AppId.sqlite-check-backup-x/kept.txt|")) 'a backup directory next to the data directory is recorded'
    Check (-not $one.Contains('another.app')) 'a folder of another application is not recorded'
    Check ((Get-SnapshotCount $one) -eq 9) "nine objects are recorded (five directories, four files), got $(Get-SnapshotCount $one)"
    Check ((Get-ProfileSnapshot $tree) -ceq $one) 'a second record of the same tree is the same'

    Start-Case 'E: the order in which things were created does not change the record'
    $first = Join-Path $Work 'snap-order-1'
    $second = Join-Path $Work 'snap-order-2'
    foreach ($name in @('a.txt', 'b.txt', 'c.txt')) {
        New-Item -ItemType Directory -Path (Join-Path $first $AppId) -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $first $AppId) $name), $name)
    }
    foreach ($name in @('c.txt', 'a.txt', 'b.txt')) {
        New-Item -ItemType Directory -Path (Join-Path $second $AppId) -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $second $AppId) $name), $name)
    }
    Check ((Get-ProfileSnapshot $first) -ceq (Get-ProfileSnapshot $second)) 'two trees with the same content give the same record'

    Start-Case 'E: a change of the content of a file, with the same name and size, changes the record'
    $tree = New-ProfileTree 'snap-content'
    $before = Get-ProfileSnapshot $tree
    [System.IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $tree $AppId) 'data') 'atlas.db'), 'DATABASE')
    $after = Get-ProfileSnapshot $tree
    Check ($after -cne $before) 'the record differs'
    Check ((Get-SnapshotCount $after) -eq (Get-SnapshotCount $before)) 'the number of objects is the same: only the hash tells'

    Start-Case 'E: a change of the size of a file changes the record'
    $tree = New-ProfileTree 'snap-size'
    $before = Get-ProfileSnapshot $tree
    [System.IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path (Join-Path $tree $AppId) 'data') 'deep') 'nested.txt'), 'nested and longer')
    Check ((Get-ProfileSnapshot $tree) -cne $before) 'the record differs'

    Start-Case 'E: a file that is added, a file that is removed, a directory that is added: each changes the record'
    $tree = New-ProfileTree 'snap-add-remove'
    $before = Get-ProfileSnapshot $tree
    $added = Join-Path (Join-Path (Join-Path (Join-Path $tree $AppId) 'data') 'deep') 'added.txt'
    [System.IO.File]::WriteAllText($added, '')
    Check ((Get-ProfileSnapshot $tree) -cne $before) 'an added (even empty) file is noticed'
    Remove-Item -LiteralPath $added -Force
    Check ((Get-ProfileSnapshot $tree) -ceq $before) 'without it the record is the first one again'
    Remove-Item -LiteralPath (Join-Path (Join-Path $tree $AppId) 'storage.initialized') -Force
    Check ((Get-ProfileSnapshot $tree) -cne $before) 'a removed file is noticed'
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $tree $AppId) 'storage.initialized'), 'marker')
    Check ((Get-ProfileSnapshot $tree) -ceq $before) 'put back, the record is the first one again'
    New-Item -ItemType Directory -Path (Join-Path (Join-Path $tree $AppId) 'new-directory') | Out-Null
    Check ((Get-ProfileSnapshot $tree) -cne $before) 'an added empty directory is noticed'

    Start-Case 'E: a directory in the place of a file of the same name changes the record'
    $tree = New-ProfileTree 'snap-type'
    $before = Get-ProfileSnapshot $tree
    $marker = Join-Path (Join-Path $tree $AppId) 'storage.initialized'
    Remove-Item -LiteralPath $marker -Force
    New-Item -ItemType Directory -Path $marker | Out-Null
    Check ((Get-ProfileSnapshot $tree) -cne $before) 'the record differs'

    Start-Case 'E: a file that cannot be read (held exclusively) fails the record, it is not passed over'
    $tree = New-ProfileTree 'snap-locked'
    $held = Join-Path (Join-Path (Join-Path $tree $AppId) 'data') 'atlas.db'
    $lock = [System.IO.File]::Open($held, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { $failure = Get-SnapshotError $tree } finally { $lock.Dispose() }
    Check ($failure -ne '') 'the record fails'
    Check ($failure.Contains("$AppId/data/atlas.db")) 'the error names the file'
    Check ((Get-SnapshotError $tree) -eq '') 'once the file is free the record is taken'

    Start-Case 'E: an error while hashing or listing fails the record'
    $tree = New-ProfileTree 'snap-faults'
    $script:SnapshotFailHash = "$AppId/data/deep/nested.txt"
    try { $failure = Get-SnapshotError $tree } finally { $script:SnapshotFailHash = '' }
    Check ($failure.Contains('cannot be read') -and $failure.Contains('nested.txt')) 'a file that cannot be hashed fails the record and is named'
    $script:SnapshotFailList = "$AppId/data/deep"
    try { $failure = Get-SnapshotError $tree } finally { $script:SnapshotFailList = '' }
    Check ($failure.Contains('cannot be listed') -and $failure.Contains("$AppId/data/deep")) 'a directory that cannot be listed fails the record and is named'
    Check ((Get-SnapshotError (Join-Path $Work 'no-such-parent')) -ne '') 'a folder that does not exist fails the record'
    Check ((Get-SnapshotError $tree) -eq '') 'without the faults the record is taken'

    Start-Case 'E: a junction or symbolic link is recorded and not followed, so a loop does not trap the record'
    $tree = New-ProfileTree 'snap-link'
    $link = Join-Path (Join-Path (Join-Path $tree $AppId) 'data') 'loop'
    $made = $true
    try {
        # A link from inside the tree back to its top: a loop for a walk that follows links.
        if ($OnWindows) { New-Item -ItemType Junction -Path $link -Target (Join-Path $tree $AppId) -ErrorAction Stop | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $tree $AppId) -ErrorAction Stop | Out-Null }
    } catch { $made = $false }
    Check $made 'the link could be made for the test'
    if ($made) {
        $record = Get-ProfileSnapshot $tree
        Check ($record.Contains("l|$AppId/data/loop")) 'the link is recorded as a link'
        Check (-not $record.Contains("$AppId/data/loop/")) 'nothing behind the link is recorded'
        Check ((Get-SnapshotCount $record) -eq 10) "the record ends, with ten objects (the nine and the link), got $(Get-SnapshotCount $record)"
        # Taken down again without following it.
        if ($OnWindows) { [System.IO.Directory]::Delete($link) } else { Remove-Item -LiteralPath $link -Force }
    }

    Start-Case 'E: a path beyond 260 characters is recorded or fails the record, it is never left out'
    $tree = New-ProfileTree 'snap-long'
    $long = Join-Path $tree $AppId
    foreach ($n in 1..6) { $long = Join-Path $long ('long-directory-name-' + ('x' * 30) + "-$n") }
    $deepFile = Join-Path $long 'deep-file.txt'
    $created = $true
    try {
        $prefix = ''
        if ($OnWindows) { $prefix = '\\?\' }
        [void][System.IO.Directory]::CreateDirectory($prefix + $long)
        [System.IO.File]::WriteAllText($prefix + $deepFile, 'deep')
    } catch { $created = $false }
    if (-not $created) {
        Skip-Case 'a path that long could not be created here, so there is nothing to record'
    } else {
        Check ($deepFile.Length -gt 260) "the path is longer than 260 characters ($($deepFile.Length))"
        $record = ''
        $failure = ''
        try { $record = Get-ProfileSnapshot $tree } catch { $failure = "$($_.Exception.Message)" }
        Check (($failure -ne '') -or $record.Contains('deep-file.txt')) 'the deep file is in the record, or the record fails'
        Write-Host "        (here: $(if ($failure) { 'the record fails' } else { 'the deep file is recorded' }))"
        try { [System.IO.Directory]::Delete($prefix + (Join-Path (Join-Path $tree $AppId) ('long-directory-name-' + ('x' * 30) + '-1')), $true) } catch { $null = $_ }
    }

    # ---------------------------------------------------------------------------
    # Group F: the guard of the suite, end to end (-SelfTest -TestBase)
    # ---------------------------------------------------------------------------

    # Runs this file as `-SelfTest -TestBase <base>` plus arguments; returns the exit code.
    function Invoke-Guard([string]$Base, [string[]]$Arguments) {
        $script:RunNumber++
        $log = Join-Path $Base ("guard-{0:d2}.txt" -f $script:RunNumber)
        $all = @('-NoLogo', '-NoProfile')
        if ($OnWindows) { $all += @('-ExecutionPolicy', 'Bypass') }
        $all += @('-File', $Script, '-SelfTest', '-TestBase', $Base) + $Arguments
        $code = Invoke-Shell $all $log
        $script:LastLog = $log
        return $code
    }

    Start-Case 'F: the guard on an unchanged test profile: exit 0, and it watches the test profile, not the real one'
    $base = New-Base 'guard-clean'
    $state = Get-Snapshot (Get-Local $base)
    $code = Invoke-Guard $base @()
    $output = Get-LastOutput
    Check ($code -eq 0) "exit code 0, got $code"
    Check ($output.Contains("Profile watched: $(Get-Local $base)")) 'the test profile is the one watched'
    Check ($output -match 'profile guard: the profile is unchanged') 'the guard reports the profile as unchanged'
    Check ($output -match 'test cases are not run') 'no test case is run in this mode'
    Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the test profile is unchanged'

    foreach ($entry in @(
            @{ Name = 'the first record cannot be taken'; Fault = 'profile-initial-error'; Code = 2; Pattern = 'The self-test was not started' },
            @{ Name = 'the second record cannot be taken'; Fault = 'profile-final-error'; Code = 1; Pattern = 'cannot be recorded completely afterwards' },
            @{ Name = 'the profile changes between the two records'; Fault = 'profile-change'; Code = 1; Pattern = 'the profile changed between the two records' })) {
        Start-Case "F: $($entry.Name): the child process ends with a non-zero exit code"
        $base = New-Base ("guard-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $code = Invoke-Guard $base @('-TestFault', $entry.Fault)
        $output = Get-LastOutput
        Check ($code -eq $entry.Code) "exit code $($entry.Code), got $code"
        Check ($code -ne 0) 'the exit code is not zero'
        Check ($output -match $entry.Pattern) 'the reason is printed'
        Check ($output -notmatch 'profile guard: the profile is unchanged') 'it does not report the profile as unchanged'
    }

    Start-Case 'F: a file of the test profile that cannot be read: the suite is not started, exit code 2'
    $base = New-Base 'guard-locked'
    $held = Join-Path (Join-Path (Get-Root $base) 'data') 'atlas.db'
    $lock = [System.IO.File]::Open($held, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { $code = Invoke-Guard $base @() } finally { $lock.Dispose() }
    $output = Get-LastOutput
    Check ($code -eq 2) "exit code 2, got $code"
    Check ($output -match 'cannot be recorded completely') 'the reason is printed'
    Check ($output.Contains('data/atlas.db')) 'the file is named'
    $code = Invoke-Guard $base @()
    Check ($code -eq 0) "once the file is free: exit code 0, got $code"

    # The process list of these cases is a file of the test profile; no real
    # process is started, looked at or ended. Each refusal is also run with a
    # fault that would fail the first record: if the record were attempted, the
    # output would say so.
    foreach ($entry in @(
            @{ Name = 'ATLAS is running'; Lines = @('100|atlas.exe|C:\x\atlas.exe'); Pattern = 'ATLAS is running: atlas\.exe \(id 100\)'; Close = $true },
            @{ Name = 'a WebView2 process of ATLAS is running'; Lines = @('200|msedgewebview2.exe|msedgewebview2.exe --type=renderer --webview-exe-name=atlas.exe'); Pattern = 'ATLAS is running: msedgewebview2\.exe \(id 200\)'; Close = $true },
            @{ Name = 'a WebView2 process of unknown owner is running'; Lines = @('300|msedgewebview2.exe|<unreadable>'); Pattern = 'cannot be told whose these WebView2 processes are: msedgewebview2\.exe \(id 300\)'; Close = $false },
            @{ Name = 'a WebView2 process of unknown owner is running next to one of another application'; Lines = @('400|msedgewebview2.exe|msedgewebview2.exe --webview-exe-name=Teams.exe', '301|msedgewebview2.exe|<unreadable>'); Pattern = 'cannot be told whose these WebView2 processes are: msedgewebview2\.exe \(id 301\)'; Close = $false },
            @{ Name = 'the list of processes cannot be read'; Lines = @('!error'); Pattern = 'cannot be checked whether ATLAS is running'; Close = $false })) {
        Start-Case "F: $($entry.Name): the self-test stops with exit code 2 before the first record and before any test case"
        $base = New-Base ("guard-run-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Set-Processes $base $entry.Lines
        $state = Get-Snapshot (Get-Local $base)
        foreach ($arguments in @(@(), @('-TestFault', 'profile-initial-error'))) {
            $code = Invoke-Guard $base $arguments
            $output = Get-LastOutput
            Check ($code -eq 2) "exit code 2, got $code (arguments: $($arguments -join ' '))"
            Check ($output -match $entry.Pattern) 'the reason is printed, with the process'
            Check ($output.Contains('The self-test was not started.')) 'it says that the self-test was not started'
            Check ($output.Contains('Close ATLAS and try again.') -eq $entry.Close) 'it says "Close ATLAS and try again." exactly when ATLAS is what runs'
            Check ($output -notmatch 'Profile watched') 'the first record of the profile was not taken'
            Check ($output -notmatch 'cannot be recorded') 'the record was not even attempted (the fault that fails it did not fire)'
            Check ($output -notmatch 'profile guard:|cases:|^ok ') 'no guard check and no test case was run'
        }
        if ($entry.Name -match 'unknown owner') {
            Check ((Get-LastOutput) -match 'may belong to ATLAS') 'it explains that the owner cannot be determined and that this is why it stops'
            Check ((Get-LastOutput) -match 'does not end them') 'it says that no process is ended'
        }
        Check ((Get-Snapshot (Get-Local $base)) -eq $state) 'the test profile is unchanged'
    }

    Start-Case 'F: WebView2 of another application and unrelated processes do not stop the self-test'
    $base = New-Base 'guard-foreign'
    Set-Processes $base @(
        '400|msedgewebview2.exe|msedgewebview2.exe --webview-exe-name=Teams.exe --user-data-dir="C:\Users\u\AppData\Local\Teams\EBWebView"',
        '401|explorer.exe|C:\Windows\explorer.exe',
        '402|atlas-helper.exe|C:\other\atlas-helper.exe')
    $code = Invoke-Guard $base @()
    Check ($code -eq 0) "exit code 0, got $code"
    Check ((Get-LastOutput) -match 'Profile watched') 'the record was taken'

    # ---------------------------------------------------------------------------
    # Guard rails of the test switches
    # ---------------------------------------------------------------------------

    # Runs this file with exactly these arguments; returns the exit code.
    function Invoke-Raw([string]$Name, [string[]]$Arguments) {
        $log = Join-Path $Work "$Name.txt"
        $all = @('-NoLogo', '-NoProfile')
        if ($OnWindows) { $all += @('-ExecutionPolicy', 'Bypass') }
        $all += @('-File', $Script) + $Arguments
        $code = Invoke-Shell $all $log
        $script:LastLog = $log
        return $code
    }

    # The message of an uncaught error is wrapped by the shell: compare without white space.
    function Get-LastOutputFlat { return ((Get-LastOutput) -replace '\s', '') }

    $base = New-Base 'switches'
    $switchState = Get-Snapshot $base
    foreach ($entry in @(
            @{ Name = '-TestBase without -SelfTest'; Arguments = @('-TestBase', $base); Pattern = 'needs-SelfTest' },
            @{ Name = '-TestBase -TestRun without -SelfTest'; Arguments = @('-TestBase', $base, '-TestRun'); Pattern = 'needs-SelfTest' },
            @{ Name = '-TestFault alone'; Arguments = @('-TestFault', 'backup-restore'); Pattern = 'needs-SelfTest-TestBase' },
            @{ Name = '-TestFault with -SelfTest but without -TestBase'; Arguments = @('-SelfTest', '-TestFault', 'profile-change'); Pattern = 'needs-SelfTest-TestBase' },
            @{ Name = '-TestFault with -TestBase but without -SelfTest'; Arguments = @('-TestBase', $base, '-TestFault', 'backup-restore'); Pattern = 'needs-SelfTest' },
            @{ Name = '-TestRun alone'; Arguments = @('-TestRun'); Pattern = 'needs-SelfTest-TestBase' },
            @{ Name = '-Keep without -SelfTest'; Arguments = @('-Keep'); Pattern = 'onlyfor-SelfTest' },
            @{ Name = '-Keep with -SelfTest -TestBase'; Arguments = @('-SelfTest', '-TestBase', $base, '-Keep'); Pattern = 'onlyfor-SelfTestwithout-TestBase' },
            @{ Name = '-SelfTest with -Exe'; Arguments = @('-SelfTest', '-Exe', 'atlas.exe'); Pattern = 'doesnottake-Exe' },
            @{ Name = '-SelfTest -TestBase with -RestoreOnly and without -TestRun'; Arguments = @('-SelfTest', '-TestBase', $base, '-RestoreOnly'); Pattern = 'doesnottake-Exe' },
            @{ Name = '-SelfTest -TestBase with a fault of a script run'; Arguments = @('-SelfTest', '-TestBase', $base, '-TestFault', 'backup-restore'); Pattern = 'knowsonlythesefaults' })) {
        Start-Case "switches: $($entry.Name) is refused before anything is read or changed"
        $code = Invoke-Raw ("switch-" + [guid]::NewGuid().ToString('N').Substring(0, 8)) $entry.Arguments
        Check ($code -ne 0) "the script does not run, got $code"
        Check ((Get-LastOutputFlat) -match $entry.Pattern) 'the reason is named'
        Check ((Get-LastOutput) -notmatch 'Profile watched|Report directory') 'nothing was started'
        Check ((Get-Snapshot $base) -eq $switchState) 'the test profile is unchanged'
    }

    Start-Case 'the profile was not touched and ATLAS was not started by the tests'
    $profileAfter = $null
    $failure = ''
    try { $profileAfter = Get-ProfileSnapshot $ProfileParent } catch { $failure = "$($_.Exception.Message)" }
    Check ($failure -eq '') "the profile could be recorded completely afterwards ($failure)"
    Check (($null -ne $profileAfter) -and ($profileAfter -ceq $profileBefore)) "every object named $AppId* is unchanged: type, path, size and SHA-256 ($(Get-SnapshotCount $profileBefore) objects before)"
    Check (Test-SamePathForTest $ProfileParent ([Environment]::GetFolderPath('LocalApplicationData'))) 'the profile watched by the suite is the real one, not a test profile'
    $started = @(Get-AtlasProcessIds | Where-Object { $atlasBefore -notcontains $_ })
    Check ($started.Count -eq 0) "no new ATLAS process appeared (new: $($started -join ', '))"
    Check (-not (Test-SamePathForTest $Work $ProfileParent)) 'the tests worked in a temporary directory'
    Check (-not ($Work.TrimEnd('\', '/') + '/').Replace('\', '/').StartsWith((Join-Path $ProfileParent $AppId).Replace('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) 'the temporary directory is not inside the data of ATLAS'

    Stop-Case

    $skipped = @($script:Cases | Where-Object { $_.StartsWith('SKIPPED') }).Count
    Write-Host ''
    Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)); cases: $($script:Cases.Count); skipped: $skipped; checks: $($script:Checks); failed checks: $($script:Failures.Count)"
    if ($Keep) { Write-Host "Kept: $Work" }
    else { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:Failures.Count -gt 0) {
        $script:Failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Restore-only mode
# ---------------------------------------------------------------------------

# Two runs in the same second must not share a report directory.
for ($n = 2; Test-Path -LiteralPath $Report; $n++) { $Report = Join-Path $ReportBase "atlas-sqlite-check-$Stamp-$n" }
New-Item -ItemType Directory -Path $Report -ErrorAction Stop | Out-Null
Write-Note "Report directory: $Report"
Write-Note "Data directory of ATLAS: $Root"

if ($RestoreOnly) {
    $code = 3
    try {
        $code = Invoke-RestoreOnly
    } catch {
        Write-RestoreInstructions "the restore stopped: $($_.Exception.Message)"
        $code = 3
    }
    Write-Outcome
    exit $code
}

# ---------------------------------------------------------------------------
# Build and environment
# ---------------------------------------------------------------------------

# Everything up to the isolation changes nothing; a stop here is written to
# the report and ends with exit code 2 (3 if an earlier run left the data
# out of its place).
try {
    $environment = New-Object System.Collections.ArrayList
    [void]$environment.Add("script started: $Stamp")
    [void]$environment.Add("run id: $RunId")
    [void]$environment.Add("script: $PSCommandPath")
    [void]$environment.Add("script sha256: $(Get-Sha $PSCommandPath)")
    [void]$environment.Add("PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))")
    [void]$environment.Add("OS: $([Environment]::OSVersion.VersionString)")
    if (-not $TestBase) {
        foreach ($tool in @(@('rustc', '--version'), @('cargo', '--version'), @('node', '--version'))) {
            try {
                $output = & $tool[0] $tool[1] 2>$null
                [void]$environment.Add(('{0}: {1}' -f ($tool -join ' '), "$output".Trim()))
            } catch { [void]$environment.Add(('{0}: not available' -f $tool[0])) }
        }
    }
    Set-Content -LiteralPath (Join-Path $Report 'environment.txt') -Value $environment -Encoding UTF8

    $built = $null
    if ($Build) {
        $sourceDir = Get-SourceDirectory
        # The source is checked first; the tests never build or start anything.
        if ($TestBase) { throw "-TestBase does not build or start the application (the source $sourceDir was accepted). Nothing was changed." }
        Add-Content -LiteralPath (Join-Path $Report 'environment.txt') -Encoding UTF8 -Value "source: $sourceDir"
        try {
            $commit = & git -C $sourceDir rev-parse HEAD 2>$null
            if ($LASTEXITCODE -eq 0) { Add-Content -LiteralPath (Join-Path $Report 'environment.txt') -Encoding UTF8 -Value "source commit: $("$commit".Trim())" }
        } catch { $null = $_ }
        Write-Note "Building the application in $sourceDir (this takes several minutes)"
        Push-Location $sourceDir
        try {
            & npm ci; if ($LASTEXITCODE -ne 0) { throw 'npm ci failed. Nothing was changed.' }
            & npm run build; if ($LASTEXITCODE -ne 0) { throw 'npm run build failed. Nothing was changed.' }
            Push-Location (Join-Path $sourceDir 'src-tauri')
            try {
                & cargo build --locked --release --features tauri/custom-protocol
                if ($LASTEXITCODE -ne 0) { throw 'cargo build failed. Nothing was changed.' }
            } finally { Pop-Location }
        } finally { Pop-Location }
        $built = ConvertTo-PlatformPath (Join-Path $sourceDir 'src-tauri\target\release\atlas.exe')
    }
    # In the tests the application is looked for only when they ask for it.
    if (-not $TestBase -or $Exe -or ($Faults -contains 'resolve-exe')) {
        $Exe = Resolve-AtlasExe $built
        $versionInfo = ''
        try { $versionInfo = "$((Get-Item -LiteralPath $Exe).VersionInfo.ProductVersion)" } catch { $versionInfo = '' }
        Add-Content -LiteralPath (Join-Path $Report 'environment.txt') -Encoding UTF8 -Value @(
            "exe: $Exe", "exe sha256: $(Get-Sha $Exe)", "exe modified: $((Get-Item -LiteralPath $Exe).LastWriteTime.ToString('s'))", "exe version: $versionInfo")
        Write-Note "Application: $Exe"
    }
} catch {
    Write-Note "STOPPED before any change: $($_.Exception.Message)"
    Set-OutcomeFromDisk
    Write-Outcome
    if (-not $script:OriginalInPlace) { exit 3 }
    exit 2
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

$restored = $false
$failure = $null
try {
    Enter-Isolation
    $stash = Join-Path $Report 'stash'
    New-Item -ItemType Directory -Path $stash | Out-Null

    if ($TestBase) {
        # Test mode: the application is not started. What a scenario does to
        # the test directory is imitated, to prove that it stays in there.
        Assert-TestRoot
        New-Item -ItemType Directory -Path $DataDir | Out-Null
        Set-Content -LiteralPath $Database -Value 'written by the test mode' -Encoding ASCII
        Remove-Item -LiteralPath $DataDir -Recurse -Force
        # Imitates what a run of the application can leave behind: processes.
        $leftBehind = Join-Path $TestBase 'processes-after-scenario.txt'
        if (Test-Path -LiteralPath $leftBehind -PathType Leaf) {
            Copy-Item -LiteralPath $leftBehind -Destination (Join-Path $TestBase 'processes.txt') -Force
        }
        # Only for the tests: the sentinel of the test directory is lost.
        if ($Faults -contains 'drop-sentinel') { Remove-Item -LiteralPath (Join-Path $Root $SentinelName) -Force }
        if ($Faults -contains 'damage-sentinel') { [System.IO.File]::WriteAllText((Join-Path $Root $SentinelName), 'garbage') }
        Invoke-Fault 'scenario'
        Add-Result 'test-mode' 'PASS' 'isolation and restore only; the application is not started'
    } else {
        Invoke-Scenario '01-first-run' {
            $run = Invoke-Run '01-first-run'
            $problems = @()
            if ($run.Text -notmatch 'database opened') { $problems += 'no "database opened"' }
            if ($run.Text -notmatch 'created=true') { $problems += 'not created=true' }
            if ($run.Text -notmatch 'state="?ready') { $problems += 'state is not ready' }
            if (-not (Test-Path -LiteralPath $Database -PathType Leaf)) { $problems += 'no data\atlas.db' }
            if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) { $problems += 'no storage.initialized' }
            foreach ($stray in @($Wal, $Shm, $Journal)) {
                if (Test-Path -LiteralPath $stray) { $problems += "left behind: $(Split-Path -Leaf $stray)" }
            }
            if ($problems.Count -gt 0) { throw ($problems -join '; ') }
            Add-Result '01-first-run' 'PASS' "database created, SQLite $($script:SqliteVersion)"
        }

        Invoke-Scenario '02-second-run-and-exit' {
            $before = Get-Sha $Database
            $run = Invoke-Run '02-second-run-and-exit'
            $problems = @()
            if ($run.Text -notmatch 'created=false') { $problems += 'not created=false' }
            if ($run.Text -notmatch 'state="?ready') { $problems += 'state is not ready' }
            if ($run.Closed -lt 1) { $problems += 'no "database closed" in the log' }
            if (-not $run.Graceful) { $problems += 'the application had to be killed' }
            if ((Get-Sha $Database) -ne $before) { $problems += 'the database file changed' }
            if (Test-Path -LiteralPath $Journal) { $problems += 'atlas.db-journal left behind' }
            if ($problems.Count -gt 0) { throw ($problems -join '; ') }
            [void]$script:ExitTimesMs.Add($run.ExitMs[0])
            Add-Result '02-second-run-and-exit' 'PASS' "normal exit in $($run.ExitMs[0]) ms, exit code $($run.Codes[0])"
        }

        foreach ($case in @(
                @{ Name = '03-wal-file'; Files = @($Wal) },
                @{ Name = '04-shm-file'; Files = @($Shm) },
                @{ Name = '05-wal-and-shm-files'; Files = @($Wal, $Shm) })) {
            Invoke-Scenario $case.Name {
                $databaseBefore = Get-Sha $Database
                $planted = @{}
                try {
                    foreach ($file in $case.Files) {
                        Assert-TestRoot
                        Set-Content -LiteralPath $file -Value 'not written by ATLAS' -Encoding ASCII
                        $planted[$file] = Get-Sha $file
                    }
                    Save-State "$($case.Name): files planted"
                    $run = Invoke-Run $case.Name
                    $problems = @()
                    if ($run.Text -notmatch 'database unavailable') { $problems += 'not unavailable' }
                    if ($run.Text -notmatch 'unexpected WAL files') { $problems += 'reason is not "unexpected WAL files"' }
                    if ($run.Text -match 'database opened') { $problems += 'the database was opened' }
                    if ((Get-Sha $Database) -ne $databaseBefore) { $problems += 'the database file changed' }
                    foreach ($file in $case.Files) {
                        if ((Get-Sha $file) -ne $planted[$file]) { $problems += "$(Split-Path -Leaf $file) changed or disappeared" }
                    }
                    if ($problems.Count -gt 0) { throw ($problems -join '; ') }
                    Add-Result $case.Name 'PASS' 'unavailable; database and planted files unchanged'
                } finally {
                    # Only what this scenario planted is removed.
                    foreach ($file in $case.Files) {
                        Assert-TestRoot
                        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
                    }
                }
            }
        }

        Invoke-Scenario '06-opens-again-after-removal' {
            $before = Get-Sha $Database
            $run = Invoke-Run '06-opens-again-after-removal'
            if ($run.Text -notmatch 'state="?ready') { throw 'state is not ready after the files were removed' }
            if ((Get-Sha $Database) -ne $before) { throw 'the database file changed' }
            Add-Result '06-opens-again-after-removal' 'PASS' 'ready, database unchanged'
        }

        Invoke-Scenario '07-missing-database' {
            $kept = Join-Path $stash 'atlas.db.kept'
            Assert-TestRoot
            Move-Item -LiteralPath $Database -Destination $kept
            try {
                $run = Invoke-Run '07-missing-database'
                $problems = @()
                if ($run.Text -notmatch 'database file missing') { $problems += 'reason is not "database file missing"' }
                if (Test-Path -LiteralPath $Database) { $problems += 'a new database was created' }
                if ($problems.Count -gt 0) { throw ($problems -join '; ') }
                Add-Result '07-missing-database' 'PASS' 'unavailable; no new database was created'
            } finally {
                Assert-TestRoot
                if (Test-Path -LiteralPath $Database) { Move-Item -LiteralPath $Database -Destination (Join-Path $stash 'atlas.db.unexpected') }
                Move-Item -LiteralPath $kept -Destination $Database
            }
        }

        Invoke-Scenario '08-garbage-instead-of-database' {
            $kept = Join-Path $stash 'atlas.db.kept'
            Assert-TestRoot
            Move-Item -LiteralPath $Database -Destination $kept
            try {
                Set-Content -LiteralPath $Database -Value ('x' * 4096) -Encoding ASCII
                $garbage = Get-Sha $Database
                $run = Invoke-Run '08-garbage-instead-of-database'
                $problems = @()
                if ($run.Text -notmatch 'database unavailable') { $problems += 'not unavailable' }
                if ($run.Text -notmatch 'code=26') { $problems += 'no SQLITE_NOTADB (code=26) in the log' }
                if ((Get-Sha $Database) -ne $garbage) { $problems += 'the file was changed' }
                if ($problems.Count -gt 0) { throw ($problems -join '; ') }
                Add-Result '08-garbage-instead-of-database' 'PASS' 'unavailable (code 26); the file was not touched'
            } finally {
                Assert-TestRoot
                if (Test-Path -LiteralPath $Database) { Remove-Item -LiteralPath $Database -Force }
                Move-Item -LiteralPath $kept -Destination $Database
            }
        }

        Invoke-Scenario '09-read-only-attribute' {
            $before = Get-Sha $Database
            Assert-TestRoot
            Set-ItemProperty -LiteralPath $Database -Name IsReadOnly -Value $true
            try {
                $run = Invoke-Run '09-read-only-attribute'
                $line = @($run.Storage | Where-Object { $_ -match 'read-only|database unavailable|database opened' }) -join ' | '
                $problems = @()
                if ((Get-Sha $Database) -ne $before) { $problems += 'the database file changed' }
                if ($run.Text -match 'state="?ready') { $problems += 'reported as ready although the file is read-only' }
                if ($run.Text -notmatch 'read-only|database unavailable') { $problems += 'neither read-only nor unavailable' }
                if ($problems.Count -gt 0) { throw (($problems -join '; ') + " [$line]") }
                # Which of the two Windows gives is what this scenario is here to find out.
                $kind = 'unavailable'
                if ($run.Text -match 'opened read-only') { $kind = 'read-only' }
                Add-Result '09-read-only-attribute' 'PASS' "outcome: $kind; database unchanged. Log: $line"
            } finally {
                Assert-TestRoot
                Set-ItemProperty -LiteralPath $Database -Name IsReadOnly -Value $false
            }
        }

        Invoke-Scenario '10-two-instances' {
            $before = Get-Sha $Database
            $run = Invoke-Run '10-two-instances' 2
            $opened = @($run.Storage | Where-Object { $_ -match 'database opened' -and $_ -match 'state=' }).Count
            $problems = @()
            if ($opened -ne 2) { $problems += "$opened of 2 instances opened the database" }
            if (-not $run.Graceful) { $problems += 'an instance had to be killed' }
            if ((Get-Sha $Database) -ne $before) { $problems += 'the database file changed' }
            if ($problems.Count -gt 0) { throw ($problems -join '; ') }
            Add-Result '10-two-instances' 'PASS' "both opened; exit times $($run.ExitMs -join ', ') ms"
        }

        $python = Find-Python
        if ($null -eq $python) {
            Add-Result '11-real-wal-file' 'SKIPPED' 'no Python with sqlite3 found (py -3, python, python3)'
            Add-Result '12-database-in-wal-mode' 'SKIPPED' 'no Python with sqlite3 found'
        } else {
            Add-Content -LiteralPath (Join-Path $Report 'environment.txt') -Encoding UTF8 -Value "python sqlite3: $($python.Sqlite) via $($python.Command)"
            $helper = Join-Path $Report 'wal-helper.py'
            Set-Content -LiteralPath $helper -Encoding ASCII -Value @(
                'import os, shutil, sqlite3, sys',
                'mode = sys.argv[1]',
                'if mode == "make-wal":',
                '    # A real WAL with a committed change, made from a COPY of the test database.',
                '    database, work, target = sys.argv[2], sys.argv[3], sys.argv[4]',
                '    copy = os.path.join(work, "copy.db")',
                '    shutil.copyfile(database, copy)',
                '    connection = sqlite3.connect(copy)',
                '    assert connection.execute("pragma journal_mode=wal").fetchone()[0] == "wal"',
                '    connection.execute("create table planted (id integer primary key)")',
                '    connection.commit()',
                '    shutil.copyfile(copy + "-wal", target)',
                '    connection.close()',
                'elif mode == "switch-to-wal":',
                '    # What another program could do to the test database: WAL mode, closed cleanly.',
                '    connection = sqlite3.connect(sys.argv[2])',
                '    print(connection.execute("pragma journal_mode=wal").fetchone()[0])',
                '    connection.close()',
                'elif mode == "tables":',
                '    # The tables of a file taken alone (a copy, nothing next to it).',
                '    work = sys.argv[3]',
                '    copy = os.path.join(work, "alone.db")',
                '    shutil.copyfile(sys.argv[2], copy)',
                '    connection = sqlite3.connect(copy)',
                '    print(",".join(sorted(row[0] for row in connection.execute("select name from sqlite_master where type = ''table''"))))',
                '    connection.close()'
            )
            $pythonArguments = @($python.Arguments)

            Invoke-Scenario '11-real-wal-file' {
                $work = Join-Path $Report 'wal-work'
                New-Item -ItemType Directory -Path $work | Out-Null
                $databaseBefore = Get-Sha $Database
                try {
                    Assert-TestRoot
                    & $python.Command @pythonArguments $helper 'make-wal' $Database $work $Wal
                    if ($LASTEXITCODE -ne 0) { throw 'the helper could not make a WAL file' }
                    $walBefore = Get-Sha $Wal
                    Save-State '11-real-wal-file: real WAL planted'
                    $run = Invoke-Run '11-real-wal-file'
                    $aloneWork = Join-Path $Report 'wal-alone'
                    New-Item -ItemType Directory -Path $aloneWork | Out-Null
                    $tables = & $python.Command @pythonArguments $helper 'tables' $Database $aloneWork
                    $problems = @()
                    if ($run.Text -notmatch 'unexpected WAL files') { $problems += 'reason is not "unexpected WAL files"' }
                    if ((Get-Sha $Database) -ne $databaseBefore) { $problems += 'the database file changed' }
                    if ((Get-Sha $Wal) -ne $walBefore) { $problems += 'the WAL file changed or disappeared' }
                    if ("$tables" -match 'planted') { $problems += 'the content of the WAL is in the database' }
                    if ($problems.Count -gt 0) { throw ($problems -join '; ') }
                    Add-Result '11-real-wal-file' 'PASS' 'unavailable; database and WAL unchanged; nothing of the WAL in the database'
                } finally {
                    Assert-TestRoot
                    foreach ($file in @($Wal, $Shm)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
                }
            }

            Invoke-Scenario '12-database-in-wal-mode' {
                Assert-TestRoot
                $mode = & $python.Command @pythonArguments $helper 'switch-to-wal' $Database
                if ("$mode".Trim() -ne 'wal') { throw "the helper could not switch the test database to WAL (got '$mode')" }
                foreach ($file in @($Wal, $Shm)) {
                    if (Test-Path -LiteralPath $file) { throw "the helper left $(Split-Path -Leaf $file) behind; the scenario needs a cleanly closed database" }
                }
                $before = Get-Sha $Database
                $first = Invoke-Run '12-database-in-wal-mode'
                $problems = @()
                if ($first.Text -notmatch 'step=journal-mode mode=wal') { $problems += 'reason is not "step=journal-mode mode=wal"' }
                if ($first.Text -match 'state="?ready') { $problems += 'reported as ready' }
                if ((Get-Sha $Database) -ne $before) { $problems += 'the database file changed' }
                $left = @(@($Wal, $Shm) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { '{0} ({1} bytes)' -f (Split-Path -Leaf $_), (Get-Item -LiteralPath $_).Length }) -join ', '
                $second = Invoke-Run '12-database-in-wal-mode-next-start'
                if ($second.Text -notmatch 'database unavailable') { $problems += 'the next start is not unavailable' }
                if ((Get-Sha $Database) -ne $before) { $problems += 'the database file changed on the next start' }
                if ($problems.Count -gt 0) { throw ($problems -join '; ') }
                Add-Result '12-database-in-wal-mode' 'PASS' "unavailable, not switched back, database unchanged; SQLite left: $left"
            }
        }

        Invoke-Scenario '13-manual-reset' {
            # The documented reset: the data directory and the marker, on the test directory only.
            Assert-TestRoot
            if (Test-Path -LiteralPath $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
            if (Test-Path -LiteralPath $Marker) { Remove-Item -LiteralPath $Marker -Force }
            $run = Invoke-Run '13-manual-reset'
            $problems = @()
            if ($run.Text -notmatch 'created=true') { $problems += 'not created=true' }
            if ($run.Text -notmatch 'state="?ready') { $problems += 'state is not ready' }
            if ($problems.Count -gt 0) { throw ($problems -join '; ') }
            Add-Result '13-manual-reset' 'PASS' 'a new database was created after the reset'
        }
    }
} catch {
    $failure = $_.Exception.Message
    Write-Note "STOPPED: $failure"
} finally {
    if ($script:ManifestWritten -or $script:StageTried -or $script:RenameTried) {
        $restored = Exit-Isolation
        # The run is finished only when the data path is settled again.
        if ($restored -and $script:OriginalInPlace -and $script:Touched) {
            try { Write-DoneMarker $RunId }
            catch {
                $restored = $false
                $script:ManualSteps = 'run the script with -RestoreOnly'
                Write-RestoreInstructions "the data path is settled, but the run could not be marked as finished: $($_.Exception.Message). Run the script with -RestoreOnly: it checks the state again and writes the marker."
            }
        }
    } else {
        # Nothing was renamed or created by this run: there is nothing to put
        # back. What is on the disk decides what the outcome says.
        $restored = $true
        Set-OutcomeFromDisk
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$summary = New-Object System.Collections.ArrayList
[void]$summary.Add('ATLAS SQLite foundation check (issue #28)')
[void]$summary.Add("report:        $Report")
[void]$summary.Add("data dir:      $Root")
[void]$summary.Add("run id:        $RunId")
[void]$summary.Add("SQLite in log: $($script:SqliteVersion)")
[void]$summary.Add("normal exit:   $(@($script:ExitTimesMs) -join ', ') ms")
if ($failure) { [void]$summary.Add("stopped early: $failure") }
[void]$summary.Add('')
foreach ($result in @($script:Results)) {
    [void]$summary.Add(('{0,-8} {1,-36} {2}' -f $result.Status, $result.Scenario, $result.Detail))
}
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$skipped = @($script:Results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
$passed = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
[void]$summary.Add('')
[void]$summary.Add("PASS $passed, FAIL $failed, SKIPPED $skipped")
Set-Content -LiteralPath (Join-Path $Report 'summary.txt') -Value $summary -Encoding UTF8
Write-Host ''
$summary | ForEach-Object { Write-Host $_ }
Write-Outcome
Write-Host ''
Write-Host "Send the whole report directory: $Report"

if (-not $restored -or -not $script:OriginalInPlace) { exit 3 }
if ($failure -and -not $script:ManifestWritten) { exit 2 }
if ($failure -or $failed -gt 0 -or @($script:Warnings).Count -gt 0) { exit 1 }
exit 0
