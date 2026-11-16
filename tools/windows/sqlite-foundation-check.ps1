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

.PARAMETER Exe
    The application to run. Default: src-tauri\target\release\atlas.exe of the
    repository this script lies in.

.PARAMETER Build
    Build the application first: npm ci, npm run build, cargo build --locked
    --release --features tauri/custom-protocol.

.PARAMETER RestoreOnly
    Do not run any scenario: only put a data directory back that an
    interrupted run of this script left renamed. Safe to repeat.

.PARAMETER StartTimeoutSec
    How long to wait for the storage line in the application log.

.PARAMETER ExitTimeoutSec
    How long to wait for the application to exit after its window was closed.

.PARAMETER TestBase
    Only for the tests of this script (sqlite-foundation-check.tests.ps1). An
    existing directory that stands in for the profile: <TestBase>\local
    replaces %LOCALAPPDATA% and <TestBase>\home receives the report. With it
    the application is never started and no scenario runs: only the backup
    and restore steps are exercised.

.PARAMETER TestFault
    Only with -TestBase: comma separated names of steps that must fail.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\windows\sqlite-foundation-check.ps1 -Build

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\windows\sqlite-foundation-check.ps1 -RestoreOnly
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [switch]$Build,
    [switch]$RestoreOnly,
    [int]$StartTimeoutSec = 90,
    [int]$ExitTimeoutSec = 45,
    [string]$TestBase,
    [string]$TestFault
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

if ($TestFault -and -not $TestBase) {
    throw '-TestFault is only for the tests of this script and needs -TestBase. Nothing was changed.'
}
if ($TestBase) {
    if ($Build) { throw '-TestBase does not build or start the application. Nothing was changed.' }
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

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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

function Write-Marker([string]$Kind, [string]$Id) {
    $path = Get-MarkerPath $Kind $Id
    if (Test-Path -LiteralPath $path) { return }
    Write-NewFile $path @("run_id=$Id", "written=$(Get-Date -Format 'yyyyMMdd-HHmmss')")
}

# The ids of the runs that touched the data path and were not finished.
# Throws when the directory of the manifests cannot be listed.
function Get-TouchedRuns {
    if (-not (Test-Path -LiteralPath $StateDir)) { return @() }
    $ids = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $StateDir -File -Filter 'touched-*.txt' -ErrorAction Stop)) {
        if ($file.Name -match '^touched-([0-9a-f]{32})\.txt$') {
            if (-not (Test-Path -LiteralPath (Get-MarkerPath 'done' $Matches[1]))) { $ids += $Matches[1] }
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
    foreach ($id in @(Get-TouchedRuns)) {
        $state = Get-RunState $id
        if ($state.State -eq 'problem') { $problems += $state }
        elseif ($state.State -eq 'settled' -and $Close) { Write-Marker 'done' $id }
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
            $runLines += '  - it is your data and nothing else has to come back: tell the script that'
            $runLines += '    the run is finished by creating its "done" marker, for example'
            $runLines += "        New-Item -ItemType File -Path '$(Join-Path $StateDir 'done-<run id>.txt')'"
            $runLines += '    and run the script with -RestoreOnly to check.'
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
# Restore-only mode
# ---------------------------------------------------------------------------

if (-not $Exe -and -not $TestBase) { $Exe = Join-Path $RepoRoot 'src-tauri\target\release\atlas.exe' }
if ($Exe -and -not $OnWindows) { $Exe = $Exe -replace '\\', '/' -replace '\.exe$', '' }

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

$environment = New-Object System.Collections.ArrayList
[void]$environment.Add("script started: $Stamp")
[void]$environment.Add("run id: $RunId")
[void]$environment.Add("PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))")
[void]$environment.Add("OS: $([Environment]::OSVersion.VersionString)")
if (-not $TestBase) {
    foreach ($tool in @(@('rustc', '--version'), @('cargo', '--version'), @('node', '--version'), @('git', '-C', $RepoRoot, 'rev-parse', 'HEAD'))) {
        try {
            $rest = @($tool[1..($tool.Count - 1)])
            $output = & $tool[0] @rest 2>$null
            [void]$environment.Add(('{0}: {1}' -f ($tool -join ' '), "$output".Trim()))
        } catch { [void]$environment.Add(('{0}: not available' -f $tool[0])) }
    }
}
Set-Content -LiteralPath (Join-Path $Report 'environment.txt') -Value $environment -Encoding UTF8

if ($Build) {
    Write-Note 'Building the application (this takes several minutes)'
    Push-Location $RepoRoot
    try {
        & npm ci; if ($LASTEXITCODE -ne 0) { throw 'npm ci failed. Nothing was changed.' }
        & npm run build; if ($LASTEXITCODE -ne 0) { throw 'npm run build failed. Nothing was changed.' }
        Push-Location (Join-Path $RepoRoot 'src-tauri')
        try {
            & cargo build --locked --release --features tauri/custom-protocol
            if ($LASTEXITCODE -ne 0) { throw 'cargo build failed. Nothing was changed.' }
        } finally { Pop-Location }
    } finally { Pop-Location }
}
if (-not $TestBase) {
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        throw "The application was not found: $Exe. Build it (-Build) or pass -Exe. Nothing was changed."
    }
    $Exe = (Resolve-Path -LiteralPath $Exe).Path
    Add-Content -LiteralPath (Join-Path $Report 'environment.txt') -Encoding UTF8 -Value @(
        "exe: $Exe", "exe sha256: $(Get-Sha $Exe)", "exe modified: $((Get-Item -LiteralPath $Exe).LastWriteTime.ToString('s'))")
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
            try { Write-Marker 'done' $RunId }
            catch {
                $restored = $false
                Write-RestoreInstructions "the data path is settled, but the marker $(Get-MarkerPath 'done' $RunId) could not be written ($($_.Exception.Message)). Run the script with -RestoreOnly: it checks the state again and writes the marker."
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
[void]$summary.Add('ATLAS SQLite foundation check (issue #26)')
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
