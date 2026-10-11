# hdd-health-check

硬盘健康检查的实战方法论 + 可复用工具。

内容来自一次真实的排查：若干块 HDD 与 SSD，从「SMART 看着都挺好」一路做到「全盘验证过」。

> 文中涉及具体设备的数值（容量、台阶耗时、通电小时、型号、桥接芯片）一律泛化成量级描述 —— 它们等于设备指纹。可复现的原始证据只留在本地 `logs/`，不入库。

---

## 核心观点：这不是一个问题，是四个

用错工具回答错问题，代价是白跑一整天。

| 层 | 回答什么 | 工具 | HDD | SSD |
|---|---|---|---|---|
| **1. 固件计数器** | 磨损、累计错误、历史极值 | `smartctl -a` | ✅ 必做 | ✅ 必做 |
| **2. 盘内自检** | 盘自己认定「我这块表面行不行」 | `smartctl -t long` | ✅ 必做 | ⚠️ 大多不支持，且语义完全不同 |
| **3. 主机侧延迟扫描** | 「读得慢但还没读错」的弱扇区 | HD Tune / DiskGenius（**只读**） | 可选 | ❌ **完全无意义** |
| **4. 写入验证** | 写路径 + 整盘可覆写性 | `diskpart clean all` / `badblocks -w` | 仅空盘可做 | ❌ **纯消耗 P/E 寿命** |

**SSD 上没有「值得跑的测试」。** 它的健康状态全在固件计数器里，`smartctl -a` 一眼看完；跑表面扫描或写测试是用错工具。详见 [docs/01-checks.md](docs/01-checks.md)。

---

## 最有价值的发现：桥接器空闲停转会让 ATA 自检必死

某款 USB-SATA 桥接盒里的盘，扩展自检**连续 4 次失败**，状态码 `0x29`（host reset）和 `0x19`（aborted by host），**全部停在 90%**，而且 SMART 里看不到任何异常。

**根因**：桥接器按「USB 上有没有流量」判定空闲，闲若干分钟后给盘发停转命令。而 ATA 自检在**盘内**跑，主机侧**零流量** —— 于是必然中招。

**解药**：持续喂 USB 流量。每 45 秒两条 ATA 查询就够，**零写入、零磨损**。

对照组极其干净：

| | 空闲时 | 自检全程 |
|---|---|---|
| 主轴起停次数 | **数小时内十几次** | **+0**（自检全程） |
| 结果 | 自检每二三十分钟被停转打死 | 跑完一次完整的整盘读 |

完整证据链：[docs/03-bridge-idle-spindown.md](docs/03-bridge-idle-spindown.md)

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
```

> 步骤 3 不是可选项。见上面那个发现 —— 某些桥接器上不挂观察器，自检根本跑不完。

---

## 文档

| 文件 | 内容 |
|---|---|
| [docs/01-checks.md](docs/01-checks.md) | HDD / SSD 各自的检查清单与命令配方 |
| [docs/02-selftest-status-codes.md](docs/02-selftest-status-codes.md) | ATA 自检状态字节解码（实测校准） |
| [docs/03-bridge-idle-spindown.md](docs/03-bridge-idle-spindown.md) | 案例研究：桥接器空闲停转杀掉自检 |
| [docs/04-gotchas.md](docs/04-gotchas.md) | smartctl / PowerShell / CrystalDiskInfo 的坑 |
| [docs/05-sanitization.md](docs/05-sanitization.md) | 覆写到底能不能恢复：Clear vs Purge |

---

## 日志

`logs/` 目录被 `.gitignore` 掉，**只存在于本地克隆里**。里面是完整原始日志（含设备序列号），作为可复现的证据保留。

```powershell
Get-Content .\logs\*.log -Tail 30
```

---

## License

MIT
