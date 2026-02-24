# FIO 测试 36 块机械盘 iodepth=32 带宽不均衡分析

## 一、问题描述

- **测试环境**：Linux 系统，36 块机械硬盘（HDD）
- **现象**：
  - `iodepth=32` 时，各盘带宽严重不均衡，盘间差异可达 **~100 MB/s**
  - `iodepth=1024` 时，各盘带宽趋于均衡

---

## 二、根本原因分析

### 2.1 核心原因：Linux I/O 调度器的队列竞争与饥饿效应

这是最主要的原因。当 36 块盘共享同一 HBA/控制器，且 iodepth 较低时，**I/O 调度器层面的资源竞争**会导致带宽分配严重不均。

#### 机制详解

Linux 内核的 I/O 路径中存在多个队列层级：

```
应用层 (fio) → Block Layer (blk-mq) → I/O Scheduler → SCSI/驱动层 → HBA → 物理盘
```

- **iodepth=32**：每块盘只有 32 个 in-flight I/O 请求。当 36 块盘通过同一个 HBA 控制器发送请求时，总请求数为 `36 × 32 = 1152`。但 HBA 的硬件队列深度是有限的（常见值为 128~4096），I/O 调度器和 SCSI 层需要在这些盘之间做仲裁。
- 低 iodepth 下，**每块盘的 I/O 请求到达 HBA 队列的时序差异**会被放大：先占满队列的盘持续获得服务，后来者被阻塞，形成"赢者通吃"的马太效应。
- **iodepth=1024**：每块盘有 1024 个 in-flight 请求，HBA 队列始终处于饱和状态，各盘的请求在队列中充分混合和交替，硬件层面实现了更公平的时间片轮转。

### 2.2 HBA/SAS Expander 的仲裁策略

36 块机械盘通常通过 **SAS Expander** 连接到 HBA 控制器（如 LSI/Broadcom MegaRAID 或 HBA 卡）。

```
HBA Controller
  ├── SAS Expander 1 (连接 ~18 块盘)
  └── SAS Expander 2 (连接 ~18 块盘)
```

**SAS 协议的仲裁行为**：
- SAS Expander 内部使用 **连接仲裁（Connection Arbitration）** 来决定哪个盘的请求优先通过。
- 当 iodepth 低时，先完成上一个 I/O 的盘会先发起新请求，形成 **正反馈循环**——响应快的盘持续快，响应慢的盘持续慢。
- 机械盘的寻道时间有随机性（取决于磁头当前位置），某些盘因为数据分布或当前磁头位置恰好处于有利位置，吞吐量会暂时领先，而低 iodepth 无法"稀释"这种差异。

### 2.3 机械盘固有的性能离散性

即使是同型号的机械盘，其 **实际性能也存在离散性**：

| 差异因素 | 影响 |
|---------|------|
| 磁头定位精度 | 寻道时间 ±2ms 波动 |
| 数据在盘片上的物理位置 | 外圈 vs 内圈，线速度差异可达 50% |
| 盘片微小的偏心和振动 | 相邻盘间的共振耦合 |
| 固件差异 | 即使同批次，读写缓存策略可能微调 |
| 温度差异 | 机箱内部温度梯度影响磁头寻道精度 |

在 iodepth=32 时，每块盘只有 32 个待处理的请求，**盘与盘之间的固有性能差异直接暴露为带宽差异**。当 iodepth 足够大（如 1024），每块盘的请求队列足够深，排队论的 **大数定律** 开始生效，平均吞吐量趋于一致。

### 2.4 NCQ/TCQ 队列深度与带宽的统计学关系

机械盘支持 **NCQ（Native Command Queuing）/ TCQ（Tagged Command Queuing）**，典型队列深度上限为 32（SATA）或 128+（SAS）。

- **iodepth=32** 恰好等于 SATA NCQ 的上限。如果这些是 SATA 盘通过 SAS Expander 连接，那么此时：
  - 每块盘的 NCQ 队列刚好被填满
  - NCQ 的 **I/O 调度优化**（电梯算法、最短寻道优先）在不同盘上的优化效果不同
  - 数据分布不均的盘，NCQ 优化后的吞吐量差异会很大

- **iodepth=1024** 时：
  - 盘端仍然只能处理 32/128 个并发请求，但 **Linux I/O 调度器的队列中有大量排队的请求**
  - 这使得调度器可以做 **更好的合并（merge）和排序**，磨平了盘间差异
  - 同时 HBA 侧可以更均匀地分配带宽

### 2.5 blk-mq 多队列映射不均

Linux 的 blk-mq（多队列块层）将 I/O 请求分配到多个硬件队列：

```
CPU Core 0 → Software Queue 0 → Hardware Queue 0
CPU Core 1 → Software Queue 1 → Hardware Queue 1
...
```

- 36 块盘的 fio 进程/线程被 CPU 调度到不同核心
- 不同核心的 **软件队列到硬件队列的映射** 可能不均匀
- iodepth=32 时，某些映射路径上的盘获得更多的 HBA 带宽；iodepth=1024 时，队列充分饱和，映射不均的影响被淹没

---

## 三、为什么 iodepth=1024 就均衡了？

用一个直观的类比：

> **iodepth=32** 相当于每块盘只派了 32 个人去食堂排队。如果某块盘的人排在了靠前的位置，它就吃得多。盘间差异取决于"谁先排到"。
>
> **iodepth=1024** 相当于每块盘派了 1024 个人排队。食堂（HBA）永远是满的，谁先谁后已经不重要了——每块盘在任意时刻都有足够多的人在排队，按比例分配到的食物（带宽）趋于一致。

从排队论角度：
- iodepth 增大 → 每块盘的请求在各级队列中的**驻留时间方差减小** → 吞吐量趋于稳定
- 满足 **Little's Law**：`L = λ × W`（队列长度 = 到达率 × 等待时间），当 L 足够大时，λ（吞吐量）的波动被平均化

---

## 四、验证方法与排查建议

### 4.1 确认 I/O 调度器

```bash
# 查看每块盘的 I/O 调度器
for dev in sd{a..z} sda{a..j}; do
    echo -n "$dev: "
    cat /sys/block/$dev/queue/scheduler 2>/dev/null
done
```

建议：对机械盘使用 `mq-deadline` 或 `bfq`（带宽公平调度器），避免使用 `none`。

### 4.2 检查 HBA 队列深度

```bash
# 查看 HBA 驱动的队列深度
cat /sys/class/scsi_host/host*/can_queue
# 查看每块盘的队列深度
cat /sys/block/sd*/device/queue_depth
```

### 4.3 使用中间 iodepth 值验证

```bash
# 测试不同 iodepth 下的带宽离散度
for depth in 1 4 16 32 64 128 256 512 1024; do
    echo "=== iodepth=$depth ==="
    fio --name=test --ioengine=libaio --direct=1 --rw=read \
        --bs=128k --iodepth=$depth --numjobs=1 \
        --filename=/dev/sd{a..z} --filename=/dev/sda{a..j} \
        --group_reporting=0 --runtime=30 --time_based
done
```

预期结果：iodepth 从小到大，带宽离散度（标准差/平均值）应逐渐降低。

### 4.4 检查 SAS Expander 拓扑

```bash
# 使用 sas_discover 或 lsscsi 检查拓扑
lsscsi -t
# 或
sas2ircu list
sas2ircu 0 display
```

如果 36 块盘分布在不同 Expander 下，可能同一 Expander 下的盘之间更均衡，跨 Expander 的盘差异更大。

### 4.5 监控实时 I/O 分布

```bash
# 使用 iostat 观察每块盘的实时带宽
iostat -x 1 -p sd{a..z} sda{a..j}

# 或者使用 bcc/bpftrace 观察 blk 层的请求分布
biosnoop -d sda
```

---

## 五、优化建议

| 优化措施 | 方法 | 效果 |
|---------|------|------|
| **调整 I/O 调度器** | 使用 `bfq`：`echo bfq > /sys/block/sdX/queue/scheduler` | BFQ 提供带宽公平保证 |
| **增大 nr_requests** | `echo 256 > /sys/block/sdX/queue/nr_requests` | 增大块层队列深度 |
| **调整盘端队列深度** | `echo 64 > /sys/block/sdX/device/queue_depth`（SAS盘） | 让盘端缓冲更多请求 |
| **CPU 绑定** | fio 使用 `cpus_allowed` 参数，确保每个 job 绑定到特定 CPU | 避免 blk-mq 映射不均 |
| **HBA 参数调优** | 增大 HBA 驱动的 `can_queue` 和 `cmd_per_lun` | 增大控制器端缓冲 |
| **使用适当的 iodepth** | 对于机械盘带宽测试，建议 iodepth >= 128 | 确保统计均匀 |

---

## 六、总结

**iodepth=32 带宽不均衡的本质是：低队列深度下，各级 I/O 队列的竞争仲裁行为 + 机械盘固有的性能离散性，共同导致了"富者越富"的正反馈效应。**

当 iodepth 增大到 1024 时：
1. HBA/Expander 的硬件队列始终饱和，仲裁更加公平
2. Linux 块层有足够的请求做合并和排序优化
3. 排队论的大数定律抹平了盘间的随机性差异
4. 每块盘的 NCQ/TCQ 始终满载运行，磨平了寻道时间的随机波动

这是 **多设备共享链路 + 低队列深度** 场景下的经典问题，与机械盘的随机寻道特性高度相关，在 SSD 上通常不会出现如此显著的差异。
