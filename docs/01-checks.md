# 01 · 检查清单与命令配方

## 分层模型

```
层 1  固件计数器      smartctl -a                  ← 磨损 / 累计错误 / 历史极值
层 2  盘内自检        smartctl -t long             ← 盘自己读一遍全表面
层 3  主机侧延迟扫描  HD Tune / DG（只读）          ← 弱扇区（读得慢但没读错）
层 4  写入验证        diskpart clean all           ← 写路径（仅空盘）
```

**层 1 + 层 2 做完就是「硬盘体检」的天花板。** 层 3 收益低，层 4 只在盘是空的时候值得做。

---

## HDD 清单

### 必做：层 1（固件计数器）

```powershell
$sc = 'C:\Program Files\smartmontools\bin\smartctl.exe'
& $sc -a -d sat /dev/sdX
```

看这几项，**其他都是次要的**：

| ID | 名称 | 合格线 |
|---|---|---|
| 05 | 重映射扇区数 | **0** |
| 196 | 重映射事件数 | **0** |
| 197 | 待映射扇区数 | **0** |
| 198 | 离线不可修正 | **0** |
| 10 | 起转重试 | **0** |
| 199 | UDMA CRC 错误 | 少量可接受（属**线缆/接口**，不是盘片） |

再看**磨损与历史**：

```powershell
# 设备统计：写入总量、读恢复尝试、机械启动失败、温度上下限、规格上限
& $sc -l devstat -d sat /dev/sdX
```

需要重点关注的字段：

- `Logical Sectors Written / Read` — 累计工作量（× 512 = 字节）
- `Number of Reported Uncorrectable Errors` — **唯一非零就该留意**
- `Number of Mechanical Start Failures` — 必须 0
- `Read Recovery Attempts` — 越低越好
- `Specified Maximum Operating Temperature` — **该盘的规格上限**（各盘不同，别猜）
- `Time in Over-Temperature` — 必须 0
- `Number of Interface CRC Errors` — 属接口层

以及 SMART 里的终身温度极值：

```
194 Temperature_Celsius   ...   40 (Min/Max 6/51)
                                 ↑当前     ↑终身最低/最高
```

两件事注意：

1. **`(Min/Max ...)` 是固件记的终身极值**，复位不掉。
2. **Windows 的 `Get-StorageReliabilityCounter.TemperatureMax` 报的是阈值，不是实测峰值** —— 别读错。

### 必做：层 2（扩展自检）

```powershell
& $sc -t long -d sat /dev/sdX          # 发起，立刻返回
& $sc -c -d sat /dev/sdX               # 看进度（状态码解码见 02）
& $sc -l selftest -d sat /dev/sdX      # 收结果
& $sc -X -d sat /dev/sdX               # 中止
```

时间 ≈ 全盘按原生速度读一遍（厂家给出的 `Extended self-test routine recommended polling time` 就是它）。**务必挂观察器**（见 [03](03-bridge-idle-spindown.md)），并且让它当保活。

### 可选：层 3（主机侧只读扫描）

只挖一类东西：**ECC 还能救回来、但耗时异常的弱扇区**。盘内自检看不到它们（盘会默默纠错然后判「通过」）。

- 工具：HD Tune Pro / DiskGenius
- **必须选「只读 / 仅检测」**，绝不开 Write 测试或「尝试修复」
- 块大小决定耗时：64 KB 扫一块大容量盘要十几小时；1 MB 快得多但分辨率粗
- 扫出一个慢块，你能做的也只是**保持备份** —— 所以收益低

### 仅空盘：层 4（写入验证）

```cmd
diskpart
  select disk N
  detail disk        :: 核对容量，认错就没救
  clean all          :: 逐扇区写零
  exit
```

- 微软文档定义：`clean all` = **zeroes each and every sector**
- 唯一能**强迫硬盘重新评估每个扇区、该重映射就重映射**的方法
- **验证真的写满了**：`smartctl -l devstat` 看 `Logical Sectors Written`，前后差值应等于盘容量 ÷ 512
- 之后**必须重建分区表**（`convert gpt`）才能用

Linux 等价物：

```bash
sudo badblocks -wsv -b 4096 /dev/sdX                  # 4 组图案 = 8 遍，大容量盘按天算
sudo badblocks -wsv -b 4096 -t 0x55 /dev/sdX          # 单图案 = 2 遍，快 4 倍
```

> `-w` 不加 `-t` 是 4 组图案（0xaa/0x55/0xff/0x00），每组各写一遍读一遍。先想清楚要几遍。

---

## SSD 清单

### 只有一层：固件计数器（几秒钟）

```powershell
$sc = 'C:\Program Files\smartmontools\bin\smartctl.exe'
foreach ($d in 'sda','sdb','sdc') {
  & $sc -a -d nvme "/dev/$d" | Select-String `
    'Model Number|Firmware Version|Critical Warning|Temperature:|Available Spare:|Percentage Used|Data Units Written|Media and Data Integrity Errors|Unsafe Shutdowns'
}
```

| 字段 | 合格线 |
|---|---|
| `Critical Warning` | **0x00** |
| `Available Spare` | 100%（或 ≥ 阈值） |
| `Percentage Used` | 越低越好（80%+ 才开始考虑更换） |
| `Media and Data Integrity Errors` | **0** |
| `Warning / Critical Comp. Temperature Time` | **0** |

### SSD 上不要做的事

| ❌ | 原因 |
|---|---|
| HD Tune / DG 表面扫描 | **没有盘片**。扫的是 FTL 后面的逻辑地址，看不出任何物理信息 |
| 写验证 | 会**实打实消耗 P/E 寿命** —— 和 HDD 完全相反，是负收益 |
| NVMe self-test | 大多数消费级盘不支持（回 `Invalid Field in Command`）；而且语义和 ATA 扩展自检完全不同。**NVMe 规范明确说自检内容由厂商自定义**，可能触碰介质 |

### 关于 `Error Information Log Entries` 偏高

这一项和「介质错误」不是一个东西。**主机侧工具发出盘不认的命令，本身就会让这个计数 +1**（包括 smartctl 自己读不支持的日志页时）。

所以「计数很高 + 介质错误 0 + 可读错误日志为空」通常是**主机的锅，不是盘的**。判断方法：看这个数**涨不涨**（以及别的盘是不是 0，作为对照）。

---

## 二手盘特有的检查项

| 项目 | 怎么看 |
|---|---|
| **通电小时 vs 盘的生产年份** | `09 Power_On_Hours`、`devstat` |
| **是否被洗过 SMART** | 交叉验证：写入字节数 / 通电次数 / 加载次数 / 错误日志的时间轴必须互相吻合。**被归零的盘通常露馅在这些数不匹配上** |
| **是否被快速格式化过** | 可见文件系统为空 ≠ 数据没了。判据是 `$MFT` / `$LogFile` 时间戳 vs 通电小时 |
| **SMR 还是 CMR** | `smartctl -i` 里 `Zoned Device: Device managed zones` = SMR。SMR 接近写满时写入性能会明显崩 |
| **ERC（SCT Error Recovery Control）** | `smartctl -l scterc -d sat /dev/sdX`。`Disabled` 的盘**不适合上 RAID**（一个慢扇区就可能被踢出阵列）|

### 想扫旧数据时，正确顺序

1. **先只读整盘镜像**（`ddrescue` 到另一块盘）
2. **在镜像上**跑恢复工具（R-Studio / DMDE / TestDisk / PhotoRec）
3. **确认真的不要了，才允许写第一个字节**

顺序颠倒 = 不可逆。
