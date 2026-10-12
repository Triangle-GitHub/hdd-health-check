<#
.SYNOPSIS
    Move <root>:\<FolderName> from several roots into one destination, as fast as
    possible. Dry run by default.

.DESCRIPTION
    WHY robocopy /MOVE (and not Move-Item)
        - handles long paths (>260 chars) natively
        - /MOVE = copy first, delete the source only after that file copied OK
          => an interruption leaves a SPLIT state, never lost data
        - re-running skips files already moved (same name + same size)
        - gives a per-run summary you can actually read

    WHY NOT /MT (multi-threaded)
        When the destination is ONE spinning HDD, concurrent write streams make the
        head seek back and forth and REDUCE total throughput. Sources are processed
        one at a time for the same reason. Sequential single-stream is fastest for
        hdd -> hdd and ssd -> hdd.

    MERGE MODE = DEFAULT  (-PerSource switches it off)
        All sources merge into <Dest> directly (contents only, no per-source
        subfolder).
        ===> A NAME COLLISION SILENTLY OVERWRITES. <===
        The dry run therefore reports every relative path that exists in more than
        one source, so you can see it BEFORE anything moves. Read that list.

    SKIPPED: desktop.ini / *.ico **IN THE ROOT OF FolderName ONLY**
        That pair is "this folder has a custom icon" - not data. Those files are
        LEFT IN PLACE at the source (not copied, not deleted), so the source
        <root>:\<FolderName> folder has to be removed by hand afterwards.

        A recursive robocopy /XF would also drop .ico files INSIDE the tree, and
        those are real assets in game/app folders. So this script does NOT use /XF.
        Instead it enumerates the root and moves each child itself, one robocopy
        call per top-level directory.

    SAFETY
        - Dry run by DEFAULT. Nothing is touched without -Go.
        - Refuses to start if destination free space is not enough.
        - /XJ excludes junctions/symlinks (they can cause infinite recursion).
        - /R:2 /W:2 so it never hangs forever on one bad file.
        - Per-source log written to -LogDir.
        - NO end-to-end read-back verify by default (robocopy compares sizes only).
          Pass -Verify for /V, which roughly halves the throughput.

    ASCII-ONLY ON PURPOSE. Windows PowerShell 5.1 reads BOM-less .ps1 files using
    the system ANSI code page, so non-ASCII text in a script becomes mojibake or
    breaks parsing. Keeping this ASCII makes it safe in any shell/codepage.

.PARAMETER Sources
    The roots to look for <FolderName> in. Each entry is either a drive letter
    ("A") or a path ("X:\data"). Mandatory.

.PARAMETER Dest
    Destination folder that all sources merge into. Mandatory.
    NOTE: it must be on a different volume than every source.

.PARAMETER FolderName
    Folder name to look for inside each source root. Default "_transfer".

.PARAMETER Go
    Actually perform the move. Without it: report scope + collisions + free space + ETA.

.PARAMETER PerSource
    Keep one subfolder per source under Dest (no merge, so no collisions possible).

.PARAMETER KeepRootIcons
    Also move the root-level desktop.ini / *.ico.

.PARAMETER SlowSources
    Source labels whose READ speed is the bottleneck (e.g. a 2.5" SMR drive, or a
    drive over ~90% full). Their ETA uses -HDDReadMBps instead of the (faster)
    destination write speed. Example: -SlowSources E,F

.PARAMETER HDDWriteMBps
    Sustained sequential WRITE speed of the destination HDD, MB/s. Default 205.
    Measure it, do not guess: write a large file and time it, or read
    "Logical Sectors Written" from "smartctl -l devstat" before and after.

.PARAMETER HDDReadMBps
    Sustained sequential READ speed of a -SlowSources drive, MB/s. Default 120.

.PARAMETER Verify
    Add robocopy /V (read-back verification). ~2x slower.

.EXAMPLE
    .\Move-Tree.ps1                                  # dry run only
    .\Move-Tree.ps1 -Sources A,B,C -Dest Z:\temp -Go
    .\Move-Tree.ps1 -Sources A,B -Dest Z:\temp -FolderName archive -Go -Verify
    .\Move-Tree.ps1 -Sources A,B -Dest Z:\temp -SlowSources B -Go
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Sources,
    [Parameter(Mandatory)][string]$Dest,
    [string]$FolderName = '_transfer',
    [switch]$Go,
    [switch]$PerSource,
    [switch]$KeepRootIcons,
    [switch]$SlowSources = @(),
    [double]$HDDWriteMBps = 205.0,
    [double]$HDDReadMBps  = 120.0,
    [switch]$Verify,
    [int]$Retries = 2,
    [int]$WaitSeconds = 2,
    [string]$LogDir
)

# $PSScriptRoot can be empty when the script is started as `-File` from cmd, or when
# it is dot-invoked; fall back to the current directory so Join-Path never gets "".
if (-not $LogDir) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $LogDir = Join-Path $root 'move-logs'
}

function Resolve-Root {
    param([string]$Entry)
    if ($Entry -match '^[A-Za-z]$') { return ($Entry.ToUpper() + ':') }
    return $Entry.TrimEnd('\')
}
function Get-RootLabel {
    param([string]$ResolvedRoot)
    return (Split-Path -Path $ResolvedRoot -Leaf)
}

function Test-RootIcon {
    param([string]$Name, [string]$Extension, [string]$RelPath)
    # only the ROOT of FolderName: no path separator inside the relative path
    if ($RelPath -match '\\') { return $false }
    return ($Name -ieq 'desktop.ini' -or $Extension -ieq '.ico')
}

function Get-TreeInfo {
    param([string]$Path, [string]$Label, [hashtable]$Map, [switch]$SkipRootIcons)
    $base = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $n = 0; $b = [int64]0; $xn = 0; $xb = [int64]0
    $skipped = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\')
        if ($SkipRootIcons -and (Test-RootIcon -Name $f.Name -Extension $f.Extension -RelPath $rel)) {
            $xn++; $xb += $f.Length; [void]$skipped.Add($rel); continue
        }
        $n++; $b += $f.Length
        if ($Map.ContainsKey($rel)) { $Map[$rel] = $Map[$rel] + ',' + $Label }
        else                        { $Map[$rel] = $Label }
    }
    [pscustomobject]@{ Files = $n; Bytes = $b; ExFiles = $xn; ExBytes = $xb; Skipped = $skipped }
}

# ---------- 1) read-only scan ----------
$destVol = (Split-Path $Dest -Qualifier)
if (-not $destVol) { throw "Dest must be an absolute path with a drive, e.g. Z:\temp" }
$destVol  = $destVol.TrimEnd(':')
$destFree = (Get-PSDrive $destVol -ErrorAction Stop).Free
$map      = @{}
$slow     = @($SlowSources | ForEach-Object { "$_".ToUpper() })

$plan = @()
foreach ($entry in $Sources) {
    $r     = Resolve-Root -Entry $entry
    $label = Get-RootLabel -ResolvedRoot $r
    $src   = Join-Path $r $FolderName
    $dst   = $(if ($PerSource) { Join-Path $Dest $label } else { $Dest })

    if ($notFound = -not (Test-Path -LiteralPath $src)) {
        $plan += [pscustomobject]@{ Label = $label; Src = $src; Exists = $false
                                    Files = 0; Bytes = 0; ExFiles = 0; ExBytes = 0
                                    Skipped = @(); Dst = $dst }
        continue
    }
    $i = Get-TreeInfo -Path $src -Label $label -Map $map -SkipRootIcons:(!$KeepRootIcons)
    $plan += [pscustomobject]@{
        Label = $label; Src = $src; Exists = $true
        Files = $i.Files; Bytes = $i.Bytes; ExFiles = $i.ExFiles; ExBytes = $i.ExBytes
        Skipped = $i.Skipped; Dst = $dst
    }
}

$totalBytes = [int64](($plan | Measure-Object -Property Bytes   -Sum).Sum)
$totalFiles = [int](($plan | Measure-Object -Property Files   -Sum).Sum)
$totalEx    = [int](($plan | Measure-Object -Property ExFiles -Sum).Sum)
$totalExB   = [int64](($plan | Measure-Object -Property ExBytes -Sum).Sum)

""
"==== scope ===="
"{0,-16} {1,-24} {2,>10} {3,>13}  {4}" -f 'source', 'path', 'files', 'GB', 'destination'
foreach ($p in $plan) {
    if (-not $p.Exists) { "{0,-16} {1,-24} {2,>10} {3,>13}  (not found)" -f $p.Label, $p.Src, '-', '-'; continue }
    "{0,-16} {1,-24} {2,10:N0} {3,13:N2}  {4}" -f $p.Label, $p.Src, $p.Files, ($p.Bytes / 1GB), $p.Dst
}
"{0,-16} {1,-24} {2,10:N0} {3,13:N2}" -f 'TOTAL', '', $totalFiles, ($totalBytes / 1GB)
""
"mode: " + $(if ($PerSource) { 'one subfolder per source (no merge)' } else { 'MERGE into one folder' })
"left in place (ROOT of FolderName only): {0} file(s), {1:N2} MB  (-KeepRootIcons to include)" -f $totalEx, ($totalExB / 1MB)
foreach ($p in $plan) {
    if ($p.Skipped.Count) { "   $($p.Label): " + ($p.Skipped -join ', ') }
}
""
"dest $Dest : free {0:N1} GB   needed {1:N1} GB   left after {2:N1} GB   ({3})" -f
    ($destFree / 1GB), ($totalBytes / 1GB), (($destFree - $totalBytes) / 1GB),
    $(if ($destFree -gt $totalBytes * 1.05) { 'OK' } else { 'NOT ENOUGH' })

if (-not $PerSource) {
    $dup = @($map.GetEnumerator() | Where-Object { $_.Value -match ',' })
    ""
    "==== name collisions across sources (merge mode) ===="
    if ($dup.Count -eq 0) {
        "  none - the relative paths of the sources do not intersect. Merge is safe."
    } else {
        "  !! $($dup.Count) relative path(s) exist in MORE THAN ONE source."
        "  !! robocopy /MOVE will OVERWRITE, so the earlier source's copy is LOST."
        "  !! Use -PerSource to keep them apart, or handle these first:"
        $dup | Select-Object -First 40 | ForEach-Object { "     [{0}]  {1}" -f $_.Value, $_.Key }
        if ($dup.Count -gt 40) { "     ... and $($dup.Count - 40) more" }
    }
}

""
"==== ETA (sequential; the slowest link decides) ===="
$eta = 0.0
foreach ($p in $plan) {
    if (-not $p.Exists -or $p.Bytes -eq 0) { continue }
    $rate = if ($slow -contains $p.Label.ToUpper()) {
                [Math]::Min($HDDReadMBps, $HDDWriteMBps)
            } else {
                $HDDWriteMBps
            }
    $h = ($p.Bytes / 1MB) / $rate / 3600.0
    $eta += $h
    "  {0}: {1,8:N2} GB  @ {2,5:N0} MB/s  ->  {3,5:N2} h" -f $p.Label, ($p.Bytes / 1GB), $rate, $h
}
"  --------------------------------------------------"
"  TOTAL {0:N1} GB  ->  about {1:N1} h   ({2:N1} h .. {3:N1} h)" -f
    ($totalBytes / 1GB), $eta, ($eta * 0.85), ($eta * 1.2)
""
"(!) estimates only. A 2.5 inch SMR drive, or any drive over ~90% full, can read"
"    far below its nominal rate - one measured case came in at 82 MB/s where 120"
"    was assumed. Add it to -SlowSources and lower -HDDReadMBps if unsure."
""

if (-not $Go) {
    ""
    "DRY RUN - nothing was moved. Re-run with -Go to actually move."
    return
}

if ($destFree -le $totalBytes * 1.05) { throw "destination free space is not enough - aborting before touching anything" }

# ---------- 2) move ----------
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$allOk = $true

foreach ($p in $plan) {
    if (-not $p.Exists) { continue }

    $children = @(Get-ChildItem -LiteralPath $p.Src -Force -ErrorAction SilentlyContinue)
    $dirs  = @($children | Where-Object { $_.PSIsContainer })
    $files = @($children | Where-Object { -not $_.PSIsContainer })
    $skipF = @($files | Where-Object { Test-RootIcon -Name $_.Name -Extension $_.Extension -RelPath $_.Name })
    $keepF = @($files | Where-Object { -not (Test-RootIcon -Name $_.Name -Extension $_.Extension -RelPath $_.Name) })
    if ($KeepRootIcons) { $keepF = $files; $skipF = @() }

    $log = Join-Path $LogDir ("move-$($p.Label)-$stamp.log")
    ""
    "==== $($p.Src)  ->  $($p.Dst)"
    "     $($dirs.Count) top-level dir(s), $($keepF.Count) root file(s)   (log: $log)"
    if ($skipF.Count) { "     leaving in place: " + (($skipF | ForEach-Object { $_.Name }) -join ', ') }

    $common = @('/XJ', ('/R:' + $Retries), ('/W:' + $WaitSeconds), '/NFL', '/NDL', ('/LOG+:' + $log))
    if ($Verify) { $common += '/V' }

    # one move per top-level directory
    foreach ($d in $dirs) {
        & robocopy $d.FullName (Join-Path $p.Dst $d.Name) /E /MOVE @common | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -ge 8) { "     !! $($d.Name): robocopy exit $rc"; $allOk = $false }
    }
    # then the loose root files (icons excluded)
    if ($keepF.Count) {
        & robocopy $p.Src $p.Dst ($keepF | ForEach-Object { $_.Name }) /MOV @common | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -ge 8) { "     !! root files: robocopy exit $rc"; $allOk = $false }
    }
    "     done"
}

""
if ($allOk) { "DONE - all sources moved. Logs in $LogDir" }
else        { "DONE WITH ERRORS - see $LogDir ; re-running resumes and skips what is already moved" }
"(source FolderName folders may remain, holding only the skipped root icons)"
