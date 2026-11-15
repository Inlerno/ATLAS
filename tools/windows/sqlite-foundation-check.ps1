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
    the script does not try to redirect it. Instead it

      1. refuses to start while ATLAS is running or a previous run of this
         script was not restored;
      2. renames an existing data directory to
         com.inlerno.atlas.sqlite-check-backup-<timestamp> and verifies the rename;
      3. creates a fresh directory in its place and marks it with a sentinel
         file; every destructive step first checks that sentinel;
      4. in `finally` moves the test directory into the report (or, if that
         is not possible, renames it to com.inlerno.atlas.sqlite-check-test-<timestamp>)
         and renames the backup back.

    The backup is never deleted and never overwritten by this script. If the
    restore cannot be done safely the script stops, leaves everything where it
    is and writes RESTORE-INSTRUCTIONS.txt into the report directory.

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
    interrupted run of this script left renamed.

.PARAMETER StartTimeoutSec
    How long to wait for the storage line in the application log.

.PARAMETER ExitTimeoutSec
    How long to wait for the application to exit after its window was closed.

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
    [int]$ExitTimeoutSec = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants and paths
# ---------------------------------------------------------------------------

$AppId = 'com.inlerno.atlas'
$Sentinel = '.atlas-sqlite-check-test-root'
$BackupInfix = '.sqlite-check-backup-'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Windows PowerShell 5.1 has no $IsWindows; it only runs on Windows.
$OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
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
$Report = Join-Path $HOME "atlas-sqlite-check-$Stamp"
$Backup = "$Root$BackupInfix$Stamp"

$script:Results = New-Object System.Collections.ArrayList
$script:Started = New-Object System.Collections.ArrayList
$script:BackupMade = $false
$script:TestRootMade = $false
$script:SqliteVersion = ''
$script:ExitTimesMs = New-Object System.Collections.ArrayList

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
# Safety: isolation of the real data directory
# ---------------------------------------------------------------------------

function Get-AtlasProcess {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Exe)
    return @(Get-Process -Name $name -ErrorAction SilentlyContinue)
}

function Test-IsTestRoot {
    return (Test-Path -LiteralPath (Join-Path $Root $Sentinel) -PathType Leaf)
}

# Every destructive step calls this first.
function Assert-TestRoot {
    if (-not (Test-IsTestRoot)) {
        throw "Safety stop: $Root is not the test directory of this script (no $Sentinel). Nothing more is changed."
    }
}

function Get-LeftoverBackup {
    $parent = Split-Path -Parent $Root
    return @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith("$AppId$BackupInfix") })
}

function Get-EntryCount([string]$Path) {
    return @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop).Count
}

function Write-RestoreInstructions([string]$Why) {
    $text = @(
        'ATLAS SQLite foundation check: the data directory was NOT restored automatically.',
        "Reason: $Why",
        '',
        "Data directory of ATLAS:      $Root",
        "Backup of your original data: $Backup",
        "Report directory:             $Report",
        '',
        'Nothing was deleted. To restore by hand:',
        '  1. Close every ATLAS window. In Task Manager end atlas.exe and the',
        '     msedgewebview2.exe processes that belong to it.',
        "  2. If '$Root' exists and contains the file '$Sentinel', it is the test",
        '     directory of the script: move it away, for example into the report',
        '     directory:',
        "         Move-Item -LiteralPath '$Root' -Destination '$Report\test-root'",
        "     If it exists WITHOUT '$Sentinel', do not touch it and compare it with",
        '     the backup first.',
        '  3. Put the backup back (only if a backup directory exists):',
        "         Rename-Item -LiteralPath '$Backup' -NewName '$AppId'",
        '',
        'Or run the script again with -RestoreOnly: it performs steps 2 and 3 with',
        'the same safety checks.'
    )
    Set-Content -LiteralPath (Join-Path $Report 'RESTORE-INSTRUCTIONS.txt') -Value $text -Encoding UTF8
    Write-Host ''
    $text | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
}

# Moves a directory, retrying while files in it are still held (the WebView
# processes of the application take a moment to end).
function Move-Directory([string]$From, [string]$To) {
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        try {
            Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 15) { throw }
            Start-Sleep -Seconds 1
        }
    }
}

function Enter-Isolation {
    if (@(Get-AtlasProcess).Count -gt 0) {
        throw 'ATLAS is running. Close it and start the script again. Nothing was changed.'
    }
    $leftovers = @(Get-LeftoverBackup)
    if ($leftovers.Count -gt 0) {
        $names = ($leftovers | ForEach-Object { $_.FullName }) -join '; '
        throw "A previous run of this script was not restored: $names. Run the script with -RestoreOnly first. Nothing was changed."
    }
    if (Test-Path -LiteralPath $Root) {
        if (Test-IsTestRoot) {
            throw "A test directory of a previous run is still at $Root. Run the script with -RestoreOnly first. Nothing was changed."
        }
        if (Test-Path -LiteralPath $Backup) {
            throw "The backup name $Backup is already taken. Nothing was changed."
        }
        $before = Get-EntryCount $Root
        Set-Content -LiteralPath (Join-Path $Report 'isolation.txt') -Encoding UTF8 -Value @(
            "root=$Root", "backup=$Backup", "entries=$before", 'state=renaming')
        Write-Note "Existing data directory found ($before entries). Renaming it to $Backup"
        Rename-Item -LiteralPath $Root -NewName (Split-Path -Leaf $Backup) -ErrorAction Stop
        if ((Test-Path -LiteralPath $Root) -or -not (Test-Path -LiteralPath $Backup -PathType Container)) {
            throw "The rename could not be verified. Look at $Root and $Backup by hand. No test was run."
        }
        $script:BackupMade = $true
        $after = Get-EntryCount $Backup
        if ($after -ne $before) {
            throw "The backup holds $after entries, the original held $before. No test is run; the directory is put back."
        }
        Add-Content -LiteralPath (Join-Path $Report 'isolation.txt') -Value 'state=backed-up' -Encoding UTF8
        Write-Note 'Backup verified.'
    } else {
        Set-Content -LiteralPath (Join-Path $Report 'isolation.txt') -Encoding UTF8 -Value @(
            "root=$Root", 'backup=none (no data directory existed)')
        Write-Note 'No existing data directory: nothing to back up.'
    }
    New-Item -ItemType Directory -Path $Root -ErrorAction Stop | Out-Null
    Set-Content -LiteralPath (Join-Path $Root $Sentinel) -Encoding UTF8 -Value @(
        'Test directory of tools/windows/sqlite-foundation-check.ps1', "created=$Stamp")
    $script:TestRootMade = $true
    Write-Note "Isolated test directory created: $Root"
}

# Returns $true when the original state is back (or there was nothing to put back).
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
    if (Test-Path -LiteralPath $Root) {
        if (-not (Test-IsTestRoot)) {
            Write-RestoreInstructions "$Root exists but is not the test directory of this script; it was left untouched."
            return $false
        }
        $target = Join-Path $Report 'test-root'
        if (Test-Path -LiteralPath $target) { $target = Join-Path $Report "test-root-$Stamp" }
        try {
            Move-Directory $Root $target
            Write-Note "Test directory moved to $target"
        } catch {
            # For example the report is on another drive. A rename in place needs no copy.
            $aside = "$Root.sqlite-check-test-$Stamp"
            try {
                if (Test-Path -LiteralPath $aside) { throw "$aside already exists" }
                if (-not (Test-IsTestRoot)) { throw 'the test directory is no longer whole' }
                Rename-Item -LiteralPath $Root -NewName (Split-Path -Leaf $aside) -ErrorAction Stop
                Write-Note "Test directory renamed to $aside (it could not be moved into the report)"
            } catch {
                Write-RestoreInstructions "the test directory could not be moved away: $($_.Exception.Message)"
                return $false
            }
        }
    }
    if ($script:BackupMade -or (Test-Path -LiteralPath $Backup)) {
        if (-not (Test-Path -LiteralPath $Backup -PathType Container)) {
            Write-RestoreInstructions "the backup $Backup is not where it was left."
            return $false
        }
        if (Test-Path -LiteralPath $Root) {
            Write-RestoreInstructions "$Root is occupied; the backup was not moved over it."
            return $false
        }
        try {
            Rename-Item -LiteralPath $Backup -NewName $AppId -ErrorAction Stop
        } catch {
            Write-RestoreInstructions "the backup could not be renamed back: $($_.Exception.Message)"
            return $false
        }
        if (-not (Test-Path -LiteralPath $Root -PathType Container) -or (Test-Path -LiteralPath $Backup)) {
            Write-RestoreInstructions 'the rename back could not be verified.'
            return $false
        }
        Add-Content -LiteralPath (Join-Path $Report 'isolation.txt') -Value 'state=restored' -Encoding UTF8
        Write-Note "Original data directory restored: $Root"
    }
    return $true
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

if (-not $Exe) { $Exe = Join-Path $RepoRoot 'src-tauri\target\release\atlas.exe' }
if (-not $OnWindows) { $Exe = $Exe -replace '\\', '/' -replace '\.exe$', '' }

# Two runs in the same second must not share a report directory.
for ($n = 2; Test-Path -LiteralPath $Report; $n++) { $Report = Join-Path $HOME "atlas-sqlite-check-$Stamp-$n" }
New-Item -ItemType Directory -Path $Report -ErrorAction Stop | Out-Null
Write-Note "Report directory: $Report"
Write-Note "Data directory of ATLAS: $Root"

if ($RestoreOnly) {
    if (@(Get-AtlasProcess).Count -gt 0) {
        throw 'ATLAS is running. Close it and start the script again. Nothing was changed.'
    }
    $leftovers = @(Get-LeftoverBackup)
    if ($leftovers.Count -gt 1) {
        $names = ($leftovers | ForEach-Object { $_.FullName }) -join '; '
        throw "More than one backup found: $names. Decide by hand which one to put back. Nothing was changed."
    }
    if ($leftovers.Count -eq 1) { $Backup = $leftovers[0].FullName }
    if ($leftovers.Count -eq 0 -and -not ((Test-Path -LiteralPath $Root) -and (Test-IsTestRoot))) {
        Write-Note 'Nothing to restore: no backup and no test directory.'
        exit 0
    }
    if (Exit-Isolation) { Write-Note 'Restore finished.'; exit 0 }
    exit 3
}

# ---------------------------------------------------------------------------
# Build and environment
# ---------------------------------------------------------------------------

$environment = New-Object System.Collections.ArrayList
[void]$environment.Add("script started: $Stamp")
[void]$environment.Add("PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))")
[void]$environment.Add("OS: $([Environment]::OSVersion.VersionString)")
foreach ($tool in @(@('rustc', '--version'), @('cargo', '--version'), @('node', '--version'), @('git', '-C', $RepoRoot, 'rev-parse', 'HEAD'))) {
    try {
        $rest = @($tool[1..($tool.Count - 1)])
        $output = & $tool[0] @rest 2>$null
        [void]$environment.Add(('{0}: {1}' -f ($tool -join ' '), "$output".Trim()))
    } catch { [void]$environment.Add(('{0}: not available' -f $tool[0])) }
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
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    throw "The application was not found: $Exe. Build it (-Build) or pass -Exe. Nothing was changed."
}
$Exe = (Resolve-Path -LiteralPath $Exe).Path
Add-Content -LiteralPath (Join-Path $Report 'environment.txt') -Encoding UTF8 -Value @(
    "exe: $Exe", "exe sha256: $(Get-Sha $Exe)", "exe modified: $((Get-Item -LiteralPath $Exe).LastWriteTime.ToString('s'))")

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

$restored = $false
$failure = $null
try {
    Enter-Isolation
    $stash = Join-Path $Report 'stash'
    New-Item -ItemType Directory -Path $stash | Out-Null

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
} catch {
    $failure = $_.Exception.Message
    Write-Note "STOPPED: $failure"
} finally {
    if ($script:TestRootMade -or $script:BackupMade) {
        $restored = Exit-Isolation
    } else {
        # Nothing was renamed or created: there is nothing to put back.
        $restored = $true
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$summary = New-Object System.Collections.ArrayList
[void]$summary.Add('ATLAS SQLite foundation check (issue #26)')
[void]$summary.Add("report:        $Report")
[void]$summary.Add("data dir:      $Root")
[void]$summary.Add("SQLite in log: $($script:SqliteVersion)")
[void]$summary.Add("normal exit:   $(@($script:ExitTimesMs) -join ', ') ms")
if ($script:BackupMade) { [void]$summary.Add("original data: renamed to a backup and put back = $restored") }
else { [void]$summary.Add('original data: no data directory existed before the run') }
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
Write-Host ''
Write-Host "Send the whole report directory: $Report"

if (-not $restored) { exit 3 }
if ($failure -or $failed -gt 0) { exit 1 }
exit 0
