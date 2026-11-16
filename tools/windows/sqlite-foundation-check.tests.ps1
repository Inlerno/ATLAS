<#
.SYNOPSIS
    Tests of the backup and restore steps of sqlite-foundation-check.ps1.

.DESCRIPTION
    Every case builds a profile of its own in a temporary directory and runs
    the script against it with -TestBase. With -TestBase the script never
    starts ATLAS and never looks at %LOCALAPPDATA%, so these tests do not
    touch any real data. Faults are injected with -TestFault.

    Runs in Windows PowerShell 5.1 and in PowerShell 7. Exit code 0 when
    every case passed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\windows\sqlite-foundation-check.tests.ps1
#>
[CmdletBinding()]
param(
    # Keep the temporary directories for inspection.
    [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script = Join-Path $PSScriptRoot 'sqlite-foundation-check.ps1'
$Shell = (Get-Process -Id $PID).Path
$OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows
$AppId = 'com.inlerno.atlas'
$SentinelName = '.atlas-sqlite-check-test-root'
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("atlas-sqlite-check-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null

$script:Failures = New-Object System.Collections.ArrayList
$script:Checks = 0
$script:Case = ''
$script:CaseFailed = $false
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
}

function Stop-Case {
    if ($script:Case) {
        $status = 'ok'
        if ($script:CaseFailed) { $status = 'FAILED' }
        [void]$script:Cases.Add("$status  $($script:Case)")
        Write-Host ("{0,-7} {1}" -f $status, $script:Case)
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
    $all += @('-File', $Script, '-TestBase', $Base) + $Arguments
    & $Shell @all *> $log
    $script:LastLog = $log
    return $LASTEXITCODE
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
# By hand: the user decides that the directory is data and closes the run, as the instructions say.
New-Item -ItemType File -Path (Join-Path (Get-StateDir $base) "done-$id.txt") | Out-Null
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
# Guard rails of the test switches
# ---------------------------------------------------------------------------

Start-Case '-TestFault without -TestBase is refused'
$log = Join-Path $Work 'guard.txt'
$all = @('-NoLogo', '-NoProfile')
if ($OnWindows) { $all += @('-ExecutionPolicy', 'Bypass') }
$all += @('-File', $Script, '-TestFault', 'backup-restore')
& $Shell @all *> $log
Check ($LASTEXITCODE -ne 0) 'the script does not run'
Check (([System.IO.File]::ReadAllText($log)) -match 'needs -TestBase') 'the reason is named'

Stop-Case

Write-Host ''
Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)); cases: $($script:Cases.Count); checks: $($script:Checks); failed checks: $($script:Failures.Count)"
if ($Keep) { Write-Host "Kept: $Work" }
else { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
exit 0
