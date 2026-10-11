<#
.SYNOPSIS
    阻止 Windows 进入【空闲】睡眠 / 休眠，直到本进程退出。

.DESCRIPTION
    通过 SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) 持有系统电源请求。
    长时间的自检 / 写校验期间挂着它，防止机器睡掉导致任务中断
    （USB 供电中断会直接中止 ATA 自检）。

    两个必须知道的限制：

      * 只挡【空闲】睡眠。合盖 / 按电源键 / 开始菜单→睡眠 是【显式动作】，
        必须用 powercfg 设置去挡：

            powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0   # 合盖 = 不操作
            powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 0   # 电源按钮 = 不操作
            powercfg /setactive SCHEME_CURRENT

        注意这两项在 `powercfg /query` 里【不显示】（被隐藏），要从注册表读实际值。

      * 本脚本的请求【不会】出现在 `powercfg /requests` 里 —— 那个命令只报
        PowerRequest API 的请求。看不到不等于没生效。

.EXAMPLE
    .\Keep-Awake.ps1
#>
[CmdletBinding()]
param()

if (-not ('Util.Power' -as [type])) {
    Add-Type -Namespace Util -Name Power -MemberDefinition '[DllImport("kernel32.dll", SetLastError = true)] public static extern uint SetThreadExecutionState(uint esFlags);'
}

$ES_CONTINUOUS      = 0x80000000
$ES_SYSTEM_REQUIRED = 0x00000001
$flags = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED

Write-Host '已开始持有系统电源请求（屏幕仍允许关闭）。Ctrl+C 退出。' -ForegroundColor Green
Write-Host ('  标志位 = 0x{0:X8}' -f $flags)

while ($true) {
    [Util.Power]::SetThreadExecutionState($flags) | Out-Null
    Start-Sleep -Seconds 30
}
