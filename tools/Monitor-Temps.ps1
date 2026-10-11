<#
.SYNOPSIS
    Log HDD temperatures on a fixed interval. Writes CSV + readable log + end summary.

.DESCRIPTION
    Resolves drives by SERIAL NUMBER (stable across replugging; /dev/sdX is not),
    then samples each drive's temperature every -IntervalSeconds.

    Output (into -OutDir):
        temps.csv     one row per sample, wide table: timestamp, drive1, drive2, ...
        temps.log     one line every 10 samples, with the max-so-far
        summary.txt   written when the run finishes

    HOW TO READ THE RESULT
      1) Polling every 30s keeps a USB bridge busy, so drives never idle-spin-down.
         You are measuring "always spinning" - arguably the relevant case for 24/7 use.
         To measure true idle temperature, use an interval of many minutes and make
         sure nothing else (SMART tools, backup jobs) polls the drive.
      2) This is IDLE temperature. Sustained read/write adds roughly 5-10 C.
      3) Get each drive's own spec maximum from its own devstat - do not guess:
             smartctl -l devstat -d sat /dev/sdX | Select-String 'Specified Maximum'
         (note: in devstat the VALUE comes before the label)

.NOTES
    ASCII-ONLY ON PURPOSE. Windows PowerShell 5.1 reads BOM-less .ps1 files using the
    system ANSI code page, so non-ASCII text in a script becomes mojibake or breaks
    parsing. Keeping these scripts ASCII makes them safe in any shell/codepage.

.PARAMETER Serials
    One or more drive serial numbers. Use Find-SmartctlDevices.ps1 to list them.

.PARAMETER IntervalSeconds
    Sample interval. Default 30.

.PARAMETER Hours
    Total run time. Default 8.

.EXAMPLE
    .\Monitor-Temps.ps1 -Serials SN1,SN2 -Hours 8

.EXAMPLE
    .\Monitor-Temps.ps1 -Serials SN1 -IntervalSeconds 600 -Hours 24
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Serials,
    [int]$IntervalSeconds = 30,
    [double]$Hours = 8,
    [string]$OutDir = (Join-Path $PWD 'temp-monitor'),
    [string]$Smartctl = 'C:\Program Files\smartmontools\bin\smartctl.exe'
)

$csv  = Join-Path $OutDir 'temps.csv'
$read = Join-Path $OutDir 'temps.log'
$sum  = Join-Path $OutDir 'summary.txt'

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
                }
            }
        }
    }
    $found
}

function Get-Temp {
    param($Smartctl, $Dev, $Driver)
    $a = (& $Smartctl -A -d $Driver $Dev 2>&1 | Out-String)
    $v = [regex]::Match($a, 'Temperature_Celsius.*?-\s+(\d+)').Groups[1].Value
    if ($v) { [int]$v } else { $null }
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$targets = Resolve-Targets -Smartctl $Smartctl -Serials $Serials
if ($targets.Count -eq 0) { throw 'none of the requested serials were found' }

$cols    = @($Serials | Where-Object { $targets.ContainsKey($_) })
$startAt = Get-Date
$stopAt  = $startAt.AddHours($Hours)

(@('timestamp') + ($cols | ForEach-Object { $targets[$_].Model })) -join ',' |
    Set-Content -Path $csv -Encoding utf8
("##### temperature monitor  start={0}  interval={1}s  hours={2}  expected end={3}" -f
    $startAt.ToString('yyyy-MM-dd HH:mm:ss'), $IntervalSeconds, $Hours, $stopAt.ToString('HH:mm:ss')) |
    Set-Content -Path $read -Encoding utf8
$cols | ForEach-Object { "target: $_ = $($targets[$_].Dev)  $($targets[$_].Model)" } |
    Add-Content -Path $read -Encoding utf8

$n   = 0
$acc = @{}
$cols | ForEach-Object { $acc[$_] = New-Object System.Collections.ArrayList }

while ((Get-Date) -lt $stopAt) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $vals  = @{}
    foreach ($sn in $cols) {
        $t = Get-Temp -Smartctl $Smartctl -Dev $targets[$sn].Dev -Driver $targets[$sn].Driver
        $vals[$sn] = $t
        if ($null -ne $t) { [void]$acc[$sn].Add($t) }
    }
    (@($stamp) + ($cols | ForEach-Object { if ($null -ne $vals[$_]) { $vals[$_] } else { '' } })) -join ',' |
        Add-Content -Path $csv -Encoding utf8

    $n++
    if ($n % 10 -eq 0) {
        $parts = $cols | ForEach-Object {
            $sn = $_
            $mx = if ($acc[$sn].Count) { ($acc[$sn] | Measure-Object -Maximum).Maximum } else { '?' }
            "$($targets[$sn].Short)=$($vals[$sn])C(max $mx)"
        }
        "[$stamp] " + ($parts -join '  ') | Add-Content -Path $read -Encoding utf8
    }
    Start-Sleep -Seconds $IntervalSeconds
}

$lines  = @('==== temperature summary ====')
$lines += "  start $($startAt.ToString('yyyy-MM-dd HH:mm:ss'))   end $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
$lines += "  $n samples / ${IntervalSeconds}s interval / ${Hours}h"
$lines += ''
foreach ($sn in $cols) {
    $a = @($acc[$sn])
    if ($a.Count -lt 2) { $lines += "  $sn : not enough samples"; continue }
    $lines += ("  {0,-24} min {1,3} C   avg {2,5:N1} C   max {3,3} C" -f
        $targets[$sn].Model,
        ($a | Measure-Object -Minimum).Minimum,
        ($a | Measure-Object -Average).Average,
        ($a | Measure-Object -Maximum).Maximum)
}
$lines | Set-Content -Path $sum -Encoding utf8
'' | Add-Content -Path $read -Encoding utf8
$lines | Add-Content -Path $read -Encoding utf8
