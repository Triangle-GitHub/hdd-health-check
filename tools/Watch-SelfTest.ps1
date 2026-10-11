<#
.SYNOPSIS
    SMART 自检观察器：定期记录进度，自检结束时落盘完整结果并退出。

.DESCRIPTION
    双重作用：

    1) 观察 —— 每 N 秒记录 起停次数 / 加载次数 / 温度 / 自检状态 到日志文件。
       自检结束时自动 dump 自检日志（smartctl -a）然后退出。

    2) 保活 —— 这不是可选项。

       某些 USB-SATA 桥接器按「USB 上有没有流量」判定空闲，
       闲若干分钟后给硬盘发停转命令，而 ATA 自检会被停转中止。
       自检在【盘内】跑、【主机侧零流量】，所以裸跑必死。

       本脚本的定期查询本身就提供了持续流量，顺手解决了这个问题。

    实测（详见 docs/03-bridge-idle-spindown.md）：
        不挂观察器空闲时   数小时内起停十几次
        挂本脚本自检全程   起停 +0 次  →  跑完一整轮整盘读，Completed without error

    而且定期查询【不会】中止自检 —— 这一点已被对照实验排除。

.PARAMETER Serial
    目标盘的序列号（用 Find-SmartctlDevices.ps1 拿）。

.PARAMETER LogPath
    日志文件路径。默认先清空；用 -Append 则保留原内容。

.PARAMETER IntervalSeconds
    查询间隔，默认 45 秒。

.EXAMPLE
    .\Watch-SelfTest.ps1 -Serial <序列号> -LogPath .\logs\mydisk.log

.NOTES
    完成后日志里会出现 `!!!!! SELF-TEST ENDED`，紧接着是完整自检日志。
    另外记得配合 Keep-Awake.ps1 防止机器睡掉。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory)][string]$LogPath,
    [int]$IntervalSeconds = 45,
    [string]$Smartctl = 'C:\Program Files\smartmontools\bin\smartctl.exe',
    [switch]$Append
)

function Resolve-Target {
    param([string]$Smartctl, [string]$Serial)
    & $Smartctl --scan 2>&1 | ForEach-Object {
        if ($_ -match '^(\S+)\s+-d\s+(\S+)') {
            $dev = $Matches[1]; $dt = $Matches[2]
            $info = (& $Smartctl -i -d $dt $dev 2>&1 | Out-String)
            if ([regex]::Match($info, 'Serial Number:\s+(.+)').Groups[1].Value.Trim() -eq $Serial) {
                [pscustomobject]@{
                    Dev    = $dev
                    Driver = $dt
                    Model  = [regex]::Match($info, 'Device Model:\s+(.+)').Groups[1].Value.Trim()
                }
            }
        }
    }
}

$dir = Split-Path -Parent $LogPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (-not $Append) { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue }

Add-Content -Path $LogPath -Value ("##### Watch-SelfTest start " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  serial=$Serial  interval=${IntervalSeconds}s #####")

$target = Resolve-Target -Smartctl $Smartctl -Serial $Serial
if (-not $target) {
    Add-Content -Path $LogPath -Value "找不到序列号 $Serial 对应的设备，退出"
    throw "设备未找到: $Serial"
}
Add-Content -Path $LogPath -Value ("target = " + $target.Dev + "  " + $target.Model + "  (driver=" + $target.Driver + ")")
Write-Host ("观察中: " + $target.Dev + "  " + $target.Model + "  ->  " + $LogPath) -ForegroundColor Green

while ($true) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $a = (& $Smartctl -A -d $target.Driver $target.Dev 2>&1 |
          Select-String 'Start_Stop_Count|Load_Cycle_Count|Temperature_Celsius' | Out-String)
    $c = (& $Smartctl -c -d $target.Driver $target.Dev 2>&1 |
          Select-String 'Self-test execution status' -Context 0,1 | Out-String)

    Add-Content -Path $LogPath -Value ("===== $stamp =====")
    Add-Content -Path $LogPath -Value ($a.Trim())
    Add-Content -Path $LogPath -Value ($c.Trim())

    if ($c -and ($c -notmatch 'in progress')) {
        Add-Content -Path $LogPath -Value ("!!!!! SELF-TEST ENDED at $stamp !!!!!")
        Add-Content -Path $LogPath -Value ((& $Smartctl -a -d $target.Driver $target.Dev 2>&1 |
            Select-String '^Num\s+Test|^#\s*\d|Power_On_Hours|Start_Stop_Count|Load_Cycle_Count' |
            Out-String).Trim())
        Write-Host ("自检已结束（$stamp），结果已写入 " + $LogPath) -ForegroundColor Cyan
        break
    }
    Start-Sleep -Seconds $IntervalSeconds
}
