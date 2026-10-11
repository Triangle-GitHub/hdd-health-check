<#
.SYNOPSIS
    列出所有 smartctl 能识别的设备：设备名 / 型号 / 序列号 / 容量 / 转速。

.DESCRIPTION
    排查多块盘的第一步。用【序列号】而不是 /dev/sdX 作为稳定标识 ——
    插拔之后设备名会变，序列号不会。

.NOTES
    在 Windows 上，smartctl 的 /dev/sdN 与 PhysicalDriveN 按顺序一一对应。

    交叉验证方法：本脚本列出的条数应等于 (Get-PhysicalDisk).Count，
    然后逐条按 型号 / 容量 / 序列号 对上，再去 Get-Disk -Number N 拿盘号。

    这个假设必须验证 —— 一旦错位，你可能会对错误的盘发起破坏性操作。

.EXAMPLE
    .\Find-SmartctlDevices.ps1
#>
[CmdletBinding()]
param(
    [string]$Smartctl = 'C:\Program Files\smartmontools\bin\smartctl.exe'
)

if (-not (Test-Path $Smartctl)) { throw "找不到 smartctl: $Smartctl" }

& $Smartctl --scan 2>&1 | ForEach-Object {
    if ($_ -match '^(\S+)\s+-d\s+(\S+)') {
        $dev = $Matches[1]
        $dt  = $Matches[2]
        $info = (& $Smartctl -i -d $dt $dev 2>&1 | Out-String)
        $model = [regex]::Match($info, 'Device Model:\s+(.+)').Groups[1].Value.Trim()
        if (-not $model) { return }   # 拿不到型号的（U 盘之类）跳过
        [pscustomobject]@{
            Dev      = $dev
            Driver   = $dt
            Model    = $model
            Serial   = [regex]::Match($info, 'Serial Number:\s+(.+)').Groups[1].Value.Trim()
            Capacity = [regex]::Match($info, 'User Capacity:\s+(.+)').Groups[1].Value.Trim()
            Rpm      = [regex]::Match($info, 'Rotation Rate:\s+(.+)').Groups[1].Value.Trim()
        }
    }
} | Format-Table -AutoSize

Write-Host ''
Write-Host 'Windows 侧对应关系（用于交叉验证 /dev/sdN 与 PhysicalDriveN）：' -ForegroundColor Yellow
Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, BusType, Size | Format-Table -AutoSize
