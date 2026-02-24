# FIO 测试 36 块机械盘 iodepth=32 带宽不均衡分析

## 一、问题描述

- **测试环境**：Linux 6.6 (mt2203sp4)，海光 CPU，36 块 SAS 机械硬盘
- **现象**：
  - `iodepth=32` 时，各盘带宽严重不均衡，盘间差异可达 **~100 MB/s**
  - `iodepth=1024` 时，各盘带宽趋于均衡

---

## 二、硬件拓扑（实测数据）

```
海光 CPU (多核)
  │
  ├── host0 (ahci, 板载 SATA)
  │     └── sda: Intel SSDSC2KB96 (系统盘)
  │
  └── host1 (mpt3sas, Broadcom SAS38xx)
        │  can_queue     = 6632   ← HBA 总队列深度
        │  cmd_per_lun   = 128    ← 每盘最大并发命令数
        │  nr_hw_queues  = 120    ← blk-mq 硬件队列数
        │  sg_tablesize  = 128
        │
        └── SAS Expander (enclosure [1:0:36:0])
              ├── sdb  (WUH722020BLE604, queue_depth=128)
              ├── sdc  (WUH722020BLE604, queue_depth=128)
              │ ... (共 36 块 WD Ultrastar HC560 20TB SAS HDD)
              └── sdak (WUH722020BLE604, queue_depth=128)

I/O 调度器: mq-deadline (当前激活)
nr_requests: 256 (每盘)
```

### 关键数值

| 参数 | 值 | 说明 |
|------|-----|------|
| HBA can_queue | 6632 | HBA 总共能处理的并发命令数 |
| cmd_per_lun | 128 | 每块盘最多 128 个并发命令到达 HBA |
| nr_hw_queues | **120** | blk-mq 硬件队列数，映射到 CPU 核心 |
| 盘端 queue_depth | 128 | 每块盘 SAS TCQ 队列深度 |
| nr_requests | 256 | 块层每盘请求队列上限 |

### iodepth=32 时的流量

```
每盘 in-flight: 32         ← 远低于 cmd_per_lun(128) 和 queue_depth(128)
HBA 总 in-flight: 36×32 = 1152  ← 远低于 can_queue(6632)
盘端 TCQ 填充率: 32/128 = 25%
```

### iodepth=1024 时的流量

```
每盘提交: 1024，但被 cmd_per_lun 限制为 128 到达盘端
块层排队: 1024-128 = 896 个请求在 mq-deadline 中排队
HBA 总 in-flight: 36×128 = 4608  ← 仍在 can_queue(6632) 范围内
盘端 TCQ 填充率: 128/128 = 100%
```

---

## 三、根本原因分析

> **结论：HBA 队列不是瓶颈。根本原因是 iodepth=32 时盘端 TCQ 填充不足 + blk-mq 120 个硬件队列的 CPU 亲和性不均 + mq-deadline 调度器在低队列深度下的批处理抖动，三者叠加导致带宽分配不均。**

### 3.1 核心原因：盘端 TCQ 填充率过低（25%），机械盘寻道方差被放大

这是**最关键的因素**。

WUH722020BLE604 是 SAS 盘，TCQ 深度 128。iodepth=32 时每块盘只有 32 个 in-flight 请求：

- **TCQ 调度优化效果打折**：TCQ/NCQ 的核心优势是在多个待处理请求中选择"最优寻道路径"（类似电梯算法）。队列中只有 32 个请求时，优化空间远不如 128 个请求时充分。
- **寻道时间的随机方差被暴露**：机械盘单次寻道时间在 0.5ms~15ms 之间波动。32 个请求的平均寻道时间方差较大——某些盘如果恰好碰上一串长寻道，吞吐量会骤降。
- **正反馈循环**：吞吐量高的盘更快消耗完 32 个请求 → 更快提交新请求 → 继续保持高吞吐；吞吐量低的盘还在处理长寻道 → 新请求迟迟不到 → 继续低吞吐。

**iodepth=1024 时**：盘端被 `cmd_per_lun=128` 限制，TCQ 满载运行。128 个请求给了 TCQ 充分的优化空间，寻道路径最优化程度高，各盘的吞吐量趋于该盘的理论峰值，差异自然缩小。同时块层有 896 个排队请求，一旦某个请求完成，调度器立刻补上新请求，消除了"空窗期"。

### 3.2 blk-mq 120 个硬件队列的 CPU 亲和性不均

这是一个**隐蔽但重要**的因素。

`nr_hw_queues=120` 意味着 mpt3sas 驱动为 HBA 创建了 120 个硬件提交队列，通常 1:1 映射到 CPU 核心：

```
CPU Core 0  → HW Queue 0  → HBA
CPU Core 1  → HW Queue 1  → HBA
...
CPU Core 119 → HW Queue 119 → HBA
```

fio 为每块盘创建一个 job 线程，OS 调度器将这些线程分配到不同 CPU 核心。问题在于：

- **线程迁移**：fio job 线程没有绑定 CPU 时，OS 可能在运行过程中迁移线程到其他核心，导致 I/O 从一个 HW Queue 切换到另一个。
- **HW Queue 负载不均**：如果多个盘的 fio 线程恰好调度到同一个 CPU 核心，它们共享同一个 HW Queue，造成该队列拥挤，而其他 HW Queue 空闲。
- **NUMA 效应**：海光 CPU 是多 NUMA 节点架构。如果 fio 线程在远端 NUMA 节点的 CPU 上运行，访问 HBA 的延迟更高，该盘带宽更低。

**iodepth=32 时**：每个 HW Queue 上只有少量请求（32/120 ≈ 不到 1 个请求/队列的平均值），CPU 调度的随机性直接反映为各盘带宽差异。

**iodepth=1024 时**：块层排队深（256 nr_requests），无论线程在哪个 CPU 上，请求的蓄水池足够深，HW Queue 的负载不均被排队缓冲吸收。

### 3.3 mq-deadline 调度器的批处理行为

mq-deadline 的工作方式：

1. 将请求按 LBA 排序（用于顺序优化）
2. 同时维护 deadline 保证（防饥饿）
3. **以批次（batch）方式派发请求**

在 iodepth=32 时：
- 每块盘只有 32 个请求供调度器排序和批处理
- 批处理粒度粗糙，某些盘可能一次被派发大批请求（burst），其他盘等待
- **不同盘的 deadline 到期时间有微小差异**，但低 iodepth 下这些差异被放大为可感知的带宽波动

在 iodepth=1024 时：
- 调度器有 256 个排队请求（nr_requests 上限），批处理更平滑
- 各盘的请求交替派发更均匀

### 3.4 SAS Expander 连接仲裁

36 块盘通过同一个 SAS Expander 连接。SAS 协议使用连接仲裁来决定哪个盘的数据帧优先通过 Expander 的背板链路：

- 低 iodepth 时，Expander 链路利用率低，先完成 I/O 的盘先重新仲裁到链路
- 高 iodepth 时，链路接近饱和，仲裁轮转更公平

---

## 四、各因素贡献度评估

| 因素 | 贡献度 | 理由 |
|------|--------|------|
| **盘端 TCQ 填充不足 (25%)** | ★★★★★ | 直接决定机械盘的寻道优化效果和吞吐方差 |
| **blk-mq 120 HW Queue CPU 亲和** | ★★★★☆ | 120 个队列 + 线程未绑核 = 负载分布随机 |
| **mq-deadline 批处理抖动** | ★★★☆☆ | 低 iodepth 下批处理粒度粗，各盘派发不均 |
| **SAS Expander 仲裁** | ★★☆☆☆ | 有影响但非主因，SAS 12G 带宽充裕 |
| **HBA 队列争抢** | ☆☆☆☆☆ | **已排除**：can_queue=6632 远大于需求 |

---

## 五、验证与优化建议

### 5.1 立竿见影：增大 iodepth 或调整 cmd_per_lun

如果测试目标允许，直接使用 iodepth=128（填满盘端 TCQ）：

```bash
fio --iodepth=128 ...
```

### 5.2 绑定 CPU 消除 blk-mq 分布不均

fio 中使用 `cpus_allowed` 为每个 job 绑定不同的 CPU 核心，避免线程迁移和 HW Queue 共享：

```ini
[disk1]
filename=/dev/sdb
cpus_allowed=0

[disk2]
filename=/dev/sdc
cpus_allowed=1

; ... 每块盘绑定不同核心
```

或用 `cpus_allowed_policy=split` 自动分配：

```bash
fio --cpus_allowed_policy=split ...
```

### 5.3 尝试切换调度器为 none

由于 HBA 和盘端都有足够的队列深度，可以绕过 mq-deadline 的批处理逻辑：

```bash
for dev in sd{b..z} sda{a..k}; do
    echo none > /sys/block/$dev/queue/scheduler
done
```

这让请求直接从 blk-mq 软件队列派发到 HBA HW Queue，减少调度器引入的批处理不均。

### 5.4 NUMA 亲和性检查

```bash
# 查看 HBA 所在的 NUMA 节点
cat /sys/class/scsi_host/host1/device/../numa_node
# 或
lspci -s 41:00.0 -vv | grep "NUMA node"

# 将 fio 绑定到 HBA 所在的 NUMA 节点
numactl --cpunodebind=<node> --membind=<node> fio ...
```

### 5.5 查看 mpt3sas 驱动参数

```bash
# 查看 mpt3sas 的可调参数
ls /sys/module/mpt3sas/parameters/
cat /sys/module/mpt3sas/parameters/*
```

关注 `max_queue_depth` 和 `command_retry_count` 等参数。

### 5.6 不同 iodepth 梯度测试验证

```bash
for depth in 1 4 16 32 64 128 256 512 1024; do
    echo "=== iodepth=$depth ==="
    fio --name=bw_test --ioengine=libaio --direct=1 --rw=read \
        --bs=1M --iodepth=$depth --numjobs=1 --runtime=30 --time_based \
        --filename=/dev/sdb:/dev/sdc:...:/dev/sdak \
        --group_reporting=0
done
```

预期：iodepth 从 32 增大到 128 时（填满盘端 TCQ），带宽离散度应显著下降。

---

## 六、总结

```
                        iodepth=32              iodepth=1024
                        ──────────              ────────────
盘端 TCQ 填充          32/128 = 25% ←关键!      128/128 = 100%
TCQ 寻道优化效果        差，方差大               充分优化，方差小
HBA 总 in-flight       1152/6632 = 17%          4608/6632 = 69%
blk-mq 排队缓冲       几乎没有                  每盘 ~896 排队
调度器批处理质量        粗糙，各盘不均            平滑，交替均匀
带宽均衡性              差，差异 ~100 MB/s       好，基本一致
```

**根本原因**：iodepth=32 时盘端 TCQ 只填充了 25%，机械盘无法充分优化寻道路径，各盘因初始磁头位置和数据分布的差异产生不同的寻道效率，且低队列深度下没有足够的请求来"稀释"这种随机波动。叠加 blk-mq 120 个硬件队列的 CPU 亲和性不均和 mq-deadline 批处理抖动，最终表现为 ~100 MB/s 的盘间带宽差异。

**最直接的解法**：将 iodepth 设为 ≥128（填满盘端 TCQ），或同时绑定 CPU + 使用 none 调度器。
