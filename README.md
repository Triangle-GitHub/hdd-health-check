# hdd-health-check

硬盘健康检查的实战方法论 + 可复用工具。

内容来自两次真实排查：三块二手 HDD、三块 SSD、一个 USB 扩展 SSD，从「SMART 看着都挺好」一路做到「全盘验证过」和「找出散热不合格的那一块」。

---

## 核心观点：这不是一个问题，是四个

用错工具回答错问题，代价是白跑十个小时。

| 层 | 回答什么 | 工具 | HDD | SSD |
|---|---|---|---|---|
| **1. 固件计数器** | 磨损、累计错误、历史极值 | `smartctl -a` | ✅ 必做 | ✅ 必做 |
| **2. 盘内自检** | 盘自己认定「我这块表面行不行」 | `smartctl -t long` | ✅ 必做 | ⚠️ 大多不支持，且语义完全不同 |
| **3. 主机侧延迟扫描** | 「读得慢但还没读错」的弱扇区 | HD Tune / DiskGenius（**只读**） | 可选 | ❌ **完全无意义** |
| **4. 写入验证** | 写路径 + 整盘可覆写性 | `diskpart clean all` / `badblocks -w` | 仅空盘可做 | ❌ **纯消耗 P/E 寿命** |

**SSD 上没有「值得跑的测试」。** 它的健康状态全在固件计数器里，`smartctl -a` 一眼看完；跑表面扫描或写测试是用错工具。详见 [docs/01-checks.md](docs/01-checks.md)。

**温度是第五个问题** —— 它不在 SMART 健康位里，得单独测。见 [docs/06-thermal.md](docs/06-thermal.md)。

---

## 三个最有价值的发现

### 1. USB 桥接器的空闲停转会杀掉 ATA 自检

一块 2.5" 盘装在 VIA VL715 桥接的盒子里，扩展自检**连续 4 次失败**（状态码 `0x29` / `0x19`，全部停在 90%），而 SMART 里看不到任何异常。

**根因**：桥接器按「USB 上有没有流量」判定空闲，闲约 20 分钟后给盘发停转命令。而 ATA 自检在**盘内**跑，主机侧**零流量** —— 必然中招。

**解药**：持续喂 USB 流量。每 45 秒两条 ATA 查询就够，**零写入、零磨损**。

| | 空闲时 | 自检 10 小时中 |
|---|---|---|
| 主轴起停次数 | **+14 / 5.8 小时** | **+0 / 10 小时** |
| 结果 | 自检每 20 分钟被停转打死 | 跑完 668 分钟的整盘读 |

完整证据链：[docs/03-bridge-idle-spindown.md](docs/03-bridge-idle-spindown.md)

### 2. 无风扇 + 叠放 + 贴木桌 = 稳态在线外（实测）

**只有一块 7200 转的盘被烤了，而且它 73.6% 的时间在规格之外。**

| 盘 | 平均 | 最高 | 上限 | 超限时间占比 |
|---|---|---|---|---|
| 7200 转，夹在中间 | **57.2 °C** | **61 °C** | 55 °C | **73.6 %** |
| 2.5"，最上 | 43.9 °C | 48 °C | 60 °C | 0 % |
| 5400 转，最下 | 46.6 °C | 52 °C | 65 °C | 0 % |

**铝壳救不了它 —— 因为没风。** 空气导热系数比铝差 9000 倍，而盘体通常还用橡胶减震垫固定（绝热体）。叠放时铝的高导热率反而变成**热量共享总线**。

详见 [docs/06-thermal.md](docs/06-thermal.md)

### 3. 测热余量的阈值要留 −6 ~ −8 ℃，不是 −2

我们设「到上限 −2 ℃ 就停」，结果：在读数 53 ℃ 停手，实际冲到 **57 ℃** 并卡住。

**驱动器的温度读数滞后于它的实际热状态。** 热惯性会让实际峰值比停手读数高约 4 ℃。

---

## 快速开始

```powershell
# 1) 按序列号列出所有设备
#    在 Windows 上 smartctl 的 /dev/sdN 与 PhysicalDriveN 一一对应
.\tools\Find-SmartctlDevices.ps1

# 2) 发起扩展自检（立刻返回，自检在盘内跑）
& 'C:\Program Files\smartmontools\bin\smartctl.exe' -t long -d sat /dev/sdX

# 3) 挂观察器 —— 同时是保活手段，并在自检完成时自动落盘结果后退出
.\tools\Watch-SelfTest.ps1 -Serial <序列号> -LogPath .\logs\mydisk.log

# 4) 长时间测试期间别让机器睡
.\tools\Keep-Awake.ps1

# 5) 测温度（独立的一件事）
.\tools\Monitor-Temps.ps1 -Serials <序列号1>,<序列号2> -Hours 8

# 6) 加负载时用看门狗兜底（到「上限 − Margin」自动杀负载）
.\tools\Temperature-Watchdog.ps1 -Serials <序列号1> -Margin 6
```

> 步骤 3 不是可选项 —— 某些桥接器上不挂观察器，自检根本跑不完。

---

## 工具

| 脚本 | 用途 |
|---|---|
| `tools/Find-SmartctlDevices.ps1` | 按型号/序列号枚举设备，并列出 Windows 侧对应关系 |
| `tools/Watch-SelfTest.ps1` | 自检观察器（兼保活；完成时自动落盘结果并退出） |
| `tools/Keep-Awake.ps1` | 持有系统电源请求，防空闲睡眠 |
| `tools/Monitor-Temps.ps1` | 定时记录多块盘温度 → CSV + 可读日志 + 结束统计 |
| `tools/Temperature-Watchdog.ps1` | 温度看门狗：到「该盘规格上限 − Margin」自动杀负载 |

**所有脚本只用 ASCII** —— Windows PowerShell 5.1 读无 BOM 的 `.ps1` 时按系统 ANSI 代码页解析，非 ASCII 会变乱码甚至破坏语法。保持 ASCII 就与代码页无关。

---

## 文档

| 文件 | 内容 |
|---|---|
| [docs/01-checks.md](docs/01-checks.md) | HDD / SSD 各自的检查清单与命令配方 |
| [docs/02-selftest-status-codes.md](docs/02-selftest-status-codes.md) | ATA 自检状态字节解码（实测校准） |
| [docs/03-bridge-idle-spindown.md](docs/03-bridge-idle-spindown.md) | 案例研究：桥接器空闲停转杀掉自检 |
| [docs/04-gotchas.md](docs/04-gotchas.md) | smartctl / PowerShell 5.1 / CrystalDiskInfo 的坑 |
| [docs/05-sanitization.md](docs/05-sanitization.md) | 覆写到底能不能恢复：Clear vs Purge |
| [docs/06-thermal.md](docs/06-thermal.md) | 温度与盒子散热：实测案例、铝壳分析、免费改造、冷媒的冷凝水风险 |

---

## 日志

`logs/` 目录被 `.gitignore` 掉，**只存在于本地克隆里**。里面是完整原始数据（含设备序列号、温度 CSV、负载日志、截图），作为可复现的证据保留。

---

## License

MIT
