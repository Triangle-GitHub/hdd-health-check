# 04 · 坑清单

全是实测踩出来的，每条都附现象和正确做法。

## smartctl

### 一次只吃一个设备名

```powershell
smartctl -c -d sat /dev/sdc /dev/sdg
```
```
ERROR: smartctl takes ONE device name as the final command-line argument.
You have provided 2 device names:
```
退出码 1。**要查多块盘就写循环。**

### 用 `Select-String` 过滤输出会连报错一起滤掉

这是本项目里犯得最多、代价最大的一个错。

```powershell
& $sc -c -d sat /dev/sda /dev/sdb 2>&1 | Select-String 'Self-test execution status' -Context 0,1
# 屏幕上一片空白 —— 看起来像"命令成功了但没输出"
```

真相：`2>&1` 把 stderr 合并进管道，然后 `Select-String` 把那条 `ERROR: ...` 滤掉了。**你以为的空结果，其实是失败。**

**规则**：调试阶段**不要加管道**，让报错直接打在屏幕上。确认没问题了再套过滤器。

同一个坑踩了两次，第二次是 `powercfg /query ... | Select-String '索引'` —— 把 `Invalid Parameters` 滤掉了，于是误判「这个设置在这台机器上不存在」。

### `/dev/sdN` ↔ `PhysicalDriveN`

Windows 上 smartctl 的 `/dev/sda`…`/dev/sdz` 与 `PhysicalDrive0`…**按顺序一一对应**。

验证方法：`smartctl --scan` 的条数应等于 `Get-PhysicalDisk` 的条数，然后逐个按型号/容量/序列号对上。**这是一个可靠但必须验证的假设** —— 一旦错位，你可能会对错误的盘发起破坏性操作。

### `-d` 参数不能省

USB 桥接后面经常需要显式 `-d sat`。裸跑 `smartctl -a \\.\PhysicalDriveN` 可能直接 `Invalid argument`。

## Windows / PowerShell

### `powercfg /query` 会隐藏设置

合盖动作、电源按钮动作这些设置**存在于注册表里，但 `powercfg /query` 不显示**。查不到不等于不存在。

正确的查法（读注册表实际值）：

```powershell
$base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\<方案GUID>\<子组GUID>'
Get-ItemProperty "$base\<设置GUID>" | Select-Object ACSettingIndex, DCSettingIndex
```

而且 `powercfg -attributes` **必须带子组参数**：

```powershell
powercfg -attributes <子组GUID> <设置GUID> -ATTRIB_HIDE     # 取消隐藏
```

少了子组 = 直接报错、无任何效果。

常用 GUID：

| 名称 | GUID |
|---|---|
| `SUB_BUTTONS` | `4f971e89-eebd-4455-a8de-9e59040e7347` |
| 合盖动作 | `5ca83367-6e45-459f-a27b-476b1d01c936` |
| 电源按钮动作 | `7648efa3-dd9c-4e3e-b566-50f929386280` |
| `SUB_SLEEP` | `238c9fa8-0aad-41ed-83f4-97be242c8f20` |
| 休眠超时 | `9d7815a6-7ee4-497e-8888-515a05f02363` |
| USB 选择性暂停 | 子组 `2a737441-1930-4402-8d77-b2bebba308a3` / 设置 `48e6b7a6-50f5-4782-a5d4-53bb8f07e226` |

值：`0` = 不采取任何操作，`1` = 睡眠，`2` = 休眠，`3` = 关机。

### 中文系统上的本地化输出会打败你的过滤

```powershell
powercfg /query ... | Select-String 'Setting Index'      # 中文系统上是 '当前交流电源设置索引' → 永远匹配不到
```

**先用 `Select-String` 抓一个中性的符号**，或者干脆别过滤。

### `SetThreadExecutionState` 的请求不出现在 `powercfg /requests` 里

用 `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` 保活是有效的，但 `powercfg /requests` **只报 PowerRequest API 的请求**（例如远程桌面软件、磁盘工具会出现在那里），不报线程执行状态。**看不到 ≠ 没生效。**

另外：这个 API 只挡**空闲**睡眠。合盖、按电源键、开始菜单→睡眠 是**显式动作**，必须用 `powercfg` 设置去挡。

### 后台脚本要用 `Start-Process`，不能靠 job

```powershell
Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath -WindowStyle Hidden
```

`Start-Job` 会随宿主进程一起死。`Start-Process` 是独立进程，能扛过后续的工具调用。

### 写脚本时别忘了退出条件

本项目的第一个观察器是纯记录器（`while($true)` + `Add-Content`，**没有 break**），自检跑完后它还在以每 45 秒一次的频率查询硬盘，直到手动停掉。

## CrystalDiskInfo

### 热插拔后可能把两块盘的数据拼在一起

实测遇到：界面表头显示盘 A 的型号/序列号/固件，属性表却是盘 B 的（属性 ID 集合都是 B 特有的），**并且把 B 的属性值拿去比 A 的阈值**，于是显示出一个假的「不良」。

真实例子：

```
表头：盘 A 的 型号 / 序列号 / 固件           ← 是盘 A 的
属性表：ID 02/08/BF/C0/DC/DE/DF/E0/E2/F0   ← 全是另一块盘（盘 B）才有的
通电小时数 / 通电次数                       ← 也是盘 B 的
「04 启停次数」的临界值 140                 ← 140 实为盘 A 的 05 阈值；盘 B 的 04 阈值是 000
```

**交叉验证方法**：拿同一块盘的 `smartctl -a` 对一遍。判定「不良」的那一项，其**当前值是否真的低于阈值**，smartctl 会明确标 `FAILING_NOW`。**没有 `FAILING_NOW` 就是假警报。**

热插拔之后**重启 CDI** 再信它的结论。

## 数据与介质

### `diskpart clean all` 是逐扇区写零

微软文档：`clean all` — *"Specifies that each and every sector on the disk is zeroed"*。它是**破坏性且不可逆**的。前置动作不是「打开盘看看有没有文件」—— 那只检查了当前的 `$Bitmap`。见 [05](05-sanitization.md)。

### 二手盘「看着是空的」不等于没数据

快速格式化 / 重建分区后，文件系统显示全空，但**旧数据的簇原封不动躺在盘片上**，用 R-Studio / DMDE / TestDisk / PhotoRec 能扫出来。

判据是「是否被快速格式化过」，不是「盘里有没有文件」。
