<#
.SYNOPSIS
    Temperature watchdog: kill the load when any watched drive reaches
    (that drive's own spec maximum - Margin).

.DESCRIPTION
    The spec maximum is READ FROM EACH DRIVE, not hardcoded - it differs per model
    (55 / 60 / 65 C in our samples). Source: devstat "Specified Maximum Operating
    Temperature" (note: in devstat the VALUE comes before the label).

    On trip:
        1) create a STOP flag file, so a cooperating loader can exit cleanly
        2) kill every process named in -Kill (default: diskpart)

    WHY THE MARGIN MATTERS - A MEASURED LESSON
        With margin=2 we stopped the load when a drive reported 53 C (limit 55 C).
        It then kept climbing to 57 C and stayed there.
        A drive's reported temperature LAGS its actual thermal state, so the real
        peak overshoots the trip threshold by roughly 4 C.
        To guarantee you never exceed the spec maximum, use margin 6..8, not 2.

.NOTES
    ASCII-ONLY ON PURPOSE (see Monitor-Temps.ps1).

.PARAMETER Serials
    Serial numbers to watch.

.PARAMETER Margin
    Degrees below each drive's spec max at which to trip. Default 6.

.PARAMETER MaxHours
    Give up after this long. Default 3.

.PARAMETER Kill
    Process names to terminate on trip. Default @('diskpart').

.EXAMPLE
    .\Temperature-Watchdog.ps1 -Serials SN1 -Margin 6 -MaxHours 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Serials,
    [int]$Margin = 6,
    [double]$MaxHours = 3,
    [string[]]$Kill = @('diskpart'),
    [string]$OutDir = (Join-Path $PWD 'temp-monitor'),
    [string]$Smartctl = 'C:\Program Files\smartmontools\bin\smartctl.exe'
)

$log  = Join-Path $OutDir 'load.log'
$flag = Join-Path $OutDir 'STOP.flag'
$sum  = Join-Path $OutDir 'load-summary.txt'

function Resolve-Targets {
    param($Smartctl, $Serials)
    $found = @{}
    & $Smartctl --scan 2>&1 | ForEach-Object {
        if ($_ -match '^(\S+)\s+-d\s+(\S+)') {
            $dev = $Matches[1]; $dt = $Matches[2]
            $info = (& $Smartctl -i -d $dt $dev 2>&1 | Out-String)
            $sn = [regex]::Match($info, 'Serial Number:\s+(.+)').Groups[1].Value.Trim()
            if ($Serials -contains $sn) {
                $model = [regex]::Match($info, 'Device Model:\s+(.+)').Groups[1].Value.Trim()
                $found[$sn] = [pscustomobject]@{
                    Dev    = $dev
                    Driver = $dt
                    Model  = $model
                    Short  = ($model -split '\s+')[-1]
                    Limit  = $null
                }
            }
        }
    }
    $found
}

function Get-Devstat {
    param($Smartctl, $Dev, $Driver)
    (& $Smartctl -l devstat -d $Driver $Dev 2>&1 | Out-String)
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Remove-Item $flag -Force -ErrorAction SilentlyContinue

$targets = Resolve-Targets -Smartctl $Smartctl -Serials $Serials
if ($targets.Count -eq 0) { throw 'none of the requested serials were found' }

# read each drive's own spec maximum
foreach ($sn in $targets.Keys) {
    $v = Get-Devstat -Smartctl $Smartctl -Dev $targets[$sn].Dev -Driver $targets[$sn].Driver
    $lim = [regex]::Match($v, '(\d+)\s+\S+\s+Specified Maximum Operating Temperature').Groups[1].Value
    if ($lim) { $targets[$sn].Limit = [int]$lim }
}
$missing = @($targets.Keys | Where-Object { -not $targets[$_].Limit })
if ($missing.Count) { throw ("no spec maximum reported for: " + ($missing -join ', ')) }

$startAt  = Get-Date
$deadline = $startAt.AddHours($MaxHours)
$tripped  = $null
$peak     = @{}
foreach ($sn in $targets.Keys) { $peak[$sn] = 0 }

("##### watchdog  start={0}  margin={1}C  max={2}h  kill={3}" -f
    $startAt.ToString('yyyy-MM-dd HH:mm:ss'), $Margin, $MaxHours, ($Kill -join ',')) |
    Set-Content -Path $log -Encoding utf8
foreach ($sn in $targets.Keys) {
    "   $($targets[$sn].Short)  $($targets[$sn].Dev)  spec max $($targets[$sn].Limit)C  -> trip at $($targets[$sn].Limit - $Margin)C" |
        Add-Content -Path $log -Encoding utf8
}

while ((Get-Date) -lt $deadline) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $parts = @()
    foreach ($sn in $targets.Keys) {
        $t = $targets[$sn]
        $a = (& $Smartctl -A -d $t.Driver $t.Dev 2>&1 | Out-String)
        $v = [regex]::Match($a, 'Temperature_Celsius.*?-\s+(\d+)').Groups[1].Value
        if (-not $v) { continue }
        $tp = [int]$v
        if ($tp -gt $peak[$sn]) { $peak[$sn] = $tp }
        $parts += ("{0}={1}C(margin {2})" -f $t.Short, $tp, ($t.Limit - $tp))
        if ($tp -ge ($t.Limit - $Margin)) { $tripped = $t }
    }
    "[$stamp] " + ($parts -join '  ') | Add-Content -Path $log -Encoding utf8
    if ($tripped) { break }
    Start-Sleep -Seconds 15
}

if ($tripped) {
    "[$(Get-Date -Format 'HH:mm:ss')] TRIP: $($tripped.Short) reached spec max - $Margin C. Stopping load." |
        Add-Content -Path $log -Encoding utf8
} else {
    "[$(Get-Date -Format 'HH:mm:ss')] time limit (${MaxHours}h) reached, stopping normally" |
        Add-Content -Path $log -Encoding utf8
}

New-Item -ItemType File -Path $flag -Force | Out-Null
foreach ($name in $Kill) {
    Get-Process $name -ErrorAction SilentlyContinue | ForEach-Object {
        "   killing $name PID $($_.Id)" | Add-Content -Path $log -Encoding utf8
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

$lines  = @('==== load test summary ====')
$lines += "  start $($startAt.ToString('yyyy-MM-dd HH:mm:ss'))   end $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
$lines += "  reason: " + $(if ($tripped) { "TRIPPED ($($tripped.Short))" } else { "time limit ${MaxHours}h" })
$lines += ''
foreach ($sn in $targets.Keys) {
    $t = $targets[$sn]
    $lines += ("  {0,-24} spec max {1,3}C   trip {2,3}C   peak {3,3}C" -f
        $t.Model, $t.Limit, ($t.Limit - $Margin), $peak[$sn])
}
$lines | Set-Content -Path $sum -Encoding utf8
'' | Add-Content -Path $log -Encoding utf8
$lines | Add-Content -Path $log -Encoding utf8
