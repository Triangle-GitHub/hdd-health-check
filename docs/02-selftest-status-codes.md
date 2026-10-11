# 02 · ATA 自检状态字节解码

`smartctl -c` 打印的 `Self-test execution status: ( NNN )` 里那个数字是本项目里最容易被误读的东西。

## 实测校准出来的解码方式

```
状态字节 = 高 4 位(状态码) | 低 4 位(剩余百分比 / 10)
```

| 状态码（高 4 位）| 含义 | smartctl 的原文 |
|---|---|---|
| `0x0` | 完成，无错误 | `The previous self-test routine completed without error` |
| `0x1` | **被主机中止** | `The self-test routine was aborted by the host` |
| `0x2` | **被主机复位打断** | `The self-test routine was interrupted by a host reset` |
| `0x3` | 致命错误 / 未知 | — |
| `0x4` | 完成，但某测试项失败 | — |
| `0x5` | 完成，电气项失败 | — |
| `0x6` | 完成，伺服/寻道项失败 | — |
| `0x7` | 完成，**读**项失败 | — |
| `0x8` | 完成，**处理损伤**项失败 | — |
| `0x9` | 完成，**介质**项失败 | — |
| `0xF` | **正在执行中** | `Self-test routine in progress...` |

低 4 位是**剩余**百分比除以 10。所以在执行中：

| 字节 | 剩余 |
|---|---|
| `0xF9` (249) | 90% |
| `0xF8` (248) | 80% |
| `0xF7` (247) | 70% |
| … | … |
| `0xF1` (241) | 10% |

## 怎么验证这套解码是对的

拿**自检日志里的文字**去对。日志明确写出了状态和剩余百分比：

```
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Extended offline    Interrupted (host reset)      90%      12345        -
```

`status = ( 41 )` = `0x29` → 高 4 位 `2` = **interrupted by host reset** ✓，低 4 位 `9` = **90% 剩余** ✓。

再对几个数据点：

| 观测到的字节 | 日志/文字 | 解码结果 |
|---|---|---|
| `249` = `0xF9` | in progress... 90% remaining | 执行中，剩余 90% ✓ |
| `248` = `0xF8` | in progress... 80% remaining | 执行中，剩余 80% ✓ |
| `41` = `0x29` | Interrupted (host reset), 90% | 状态 2，剩余 90% ✓ |
| `25` = `0x19` | Aborted by host, 90% | 状态 1，剩余 90% ✓ |
| `0` | completed without error | 状态 0 ✓ |

**常见的反向误解**：把高/低 4 位搞反。如果按「低 4 位是状态码」去读，`0x29` 会解成「状态 9 = 介质项失败」——一个足以让你误判硬盘报废的错误。**用日志文字交叉验证就不会错。**

## 百分比不是线性的

**这是最重要的一条。** 实测同一块盘各个 10% 台阶的耗时：

某块 HDD（型号与容量从略）：

```
90% → 80%     约 t
80% → 70%     约 t
70% → 60%     约 t
60% → 50%     约 t
50% → 40%     约 t
40% → 30%     约 t
30% → 20%     约 t
20% → 10%     约 t
10% → 完成    约 2t     ← 前面每格的近 2 倍
```

另一块盘也呈同样的形状：最后一格同样约等于前面每格的两倍。

> 真实的分钟数已从本仓库移除（只保留相对关系）—— 绝对的分钟数等于全盘容量 ÷ 顺序读速度，
> 是一枚能反推具体盘型号的指纹。

所以在中途你看到的不是剩余时间的线性外推，只是固件的一个粗估。要估总时长：

- **用台阶平均**：跑了 N 格用了 T 分钟 → 预计总时长 ≈ T ÷ N × 9（因为起始状态是 90%，实际只有 9 次跳变）
- **别用厂家给的 `recommended polling time`**：它按 10 格算，通常偏悲观 10%

## 自检日志里要看的字段

```
Num  Test_Description    Status                     Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Extended offline    Completed without error          00%      12345        -
```

| 字段 | 意义 |
|---|---|
| `Status` | `Completed without error` = 通过；`Completed: read failure` = 有坏扇区 |
| `LBA_of_first_error` | **第一个坏扇区的 LBA**（通过时是 `-`）。这就是你唯一需要的定位信息 |
| `LifeTime(hours)` | 自检结束时的通电小时。**对比日志条目之间的差值，能反推出每次中止发生在什么时候** |
| `Remaining` | 中止时的剩余百分比 |

日志是**保留的、滚动的**。多次尝试会在同一张表里全部留档 —— 这正是复盘排查过程的证据。
