# FIO 测试 36 块机械盘带宽不均衡分析

## 一、问题描述

- **测试环境**：Linux 6.6 (mt2203sp4)，海光 CPU，36 块 SAS 机械硬盘
- **HBA**：Broadcom SAS38xx (mpt3sas)，`nr_hw_queues=120`
- **fio 命令**：

```bash
fio --ioengine=libaio \
    --randrepeat=0 --norandommap --thread --direct=1 \
    --group_reporting --runtime=3600 --time_based \
    --numjobs=1 --iodepth=128 --cpus_allowed_policy=split \
    --filename=/dev/sdX --rw=read --bs=64K
```

- **现象**：即使 iodepth=128 + cpus_allowed_policy=split，各盘带宽仍严重不均，差异 ~150 MB/s

---

## 二、硬件拓扑（实测数据）

```
海光 CPU (多核，多 NUMA 节点)
  │
  ├── host0 (ahci, 板载 SATA)
  │     └── sda: Intel SSDSC2KB96 (系统盘)
  │
  └── host1 (mpt3sas, Broadcom SAS38xx)
        │  can_queue     = 6632
        │  cmd_per_lun   = 128
        │  nr_hw_queues  = 120    ← 关键！120 个硬件提交队列
        │  sg_tablesize  = 128
        │
        └── SAS Expander
              └── 36 × WUH722020BLE604 (queue_depth=128, mq-deadline, nr_requests=256)
```

---

## 三、iostat 数据分析 — 发现决定性证据

iostat 数据清晰地将 36 块盘分为两组：

### 高带宽组（~260-277 MB/s）

```
Device    r/s     rMB/s   rrqm/s   rareq-sz   aqu-sz
sdaa      311     276     4105     ~908 KB     ~9
sdad      336     268     3964     ~819 KB     ~10
sdag      329     263     3975     ~817 KB     ~11
sdai      338     269     3977     ~817 KB     ~11
sdf       272     272     4046     ~1024 KB    ~8
...
```

特征：**rrqm/s ≈ 3000-4100**（大量合并），rareq-sz ≈ 800-1024 KB，r/s 低（~300）

### 低带宽组（~117-130 MB/s）

```
Device    r/s     rMB/s   rrqm/s   rareq-sz   aqu-sz
sdab      1830    121     123      ~68 KB      ~120
sdae      1838    120     90       ~67 KB      ~128
sdaj      1867    117     0        ~64 KB      ~128
sdd       1834    118     44       ~66 KB      ~124
sdh       1861    118     30       ~65 KB      ~125
sdr       1871    116     0        ~64 KB      ~128
...
```

特征：**rrqm/s ≈ 0-123**（几乎不合并），rareq-sz ≈ 64-68 KB，r/s 高（~1800）

### 关键对比

```
                高带宽盘             低带宽盘
                ────────            ────────
rrqm/s          ~4000               ~0-123       ← 根本差异！
rareq-sz        ~900 KB             ~64 KB       ← 合并后 vs 未合并
r/s             ~300                ~1800        ← 少量大请求 vs 大量小请求
rMB/s           ~270                ~120         ← 带宽差 ~150 MB/s
aqu-sz          ~9-12               ~120-128     ← 队列不满 vs 队列塞满
```

---

## 四、根本原因：blk-mq 多硬件队列导致请求合并失效

### 4.1 核心机制

**这不是盘的性能差异，而是 Linux blk-mq 的请求合并（merge）在某些盘上完全失效了。**

原理：

```
fio 线程 (bs=64K, iodepth=128, 顺序读)
  │
  │ 连续提交 64K 请求: LBA 0-63, LBA 64-127, LBA 128-191, ...
  │
  ├─ 如果线程始终在 CPU 5 上运行:
  │    所有请求 → HW Queue 5 → 合并成 ~1MB 大请求 → rareq-sz=900KB → 270 MB/s ✓
  │
  └─ 如果线程在 CPU 5, 17, 83, 42... 之间迁移:
       请求分散到多个 HW Queue → 每个队列只有零散的 64K → 无法合并 → rareq-sz=64KB → 120 MB/s ✗
```

**blk-mq 的请求合并只在同一个硬件队列（HW Queue）内进行。**

当 `nr_hw_queues=120` 时，每个 CPU 核心映射到不同的 HW Queue。如果 fio 线程在运行过程中被 OS 调度器迁移到另一个 CPU 核心，后续的请求就进了另一个 HW Queue，与之前的请求无法合并。

### 4.2 为什么 cpus_allowed_policy=split 没有生效？

你的 fio 命令是**每块盘单独一个 fio 进程**：

```bash
fio ... --numjobs=1 --cpus_allowed_policy=split --filename=/dev/sdX
```

`cpus_allowed_policy=split` 的含义是：**把 cpus_allowed 指定的 CPU 列表在 numjobs 个 job 之间平分**。

但你没有设置 `cpus_allowed`，而且 `numjobs=1`，所以：
- 没有 cpus_allowed → 默认所有 CPU 都可用
- numjobs=1 → 只有一个 job，"split" 1 份 = 全部 CPU 可用
- **结果：线程仍然可以在所有 CPU 上自由迁移，等于没加这个参数**

### 4.3 为什么 iodepth=1024 反而均衡？

iodepth=1024 时：
- `cmd_per_lun=128` 限制了每盘最多 128 个请求到达 HBA
- **剩余 896 个请求在 mq-deadline 调度器的队列中等待**
- 调度器队列是**全局的**（不按 HW Queue 分），在派发时可以做合并
- 请求密度足够高，即使分布在多个 HW Queue 中，每个队列内的请求也有相邻 LBA 可以合并
- 所以所有盘都能获得较好的合并效果

### 4.4 现象的随机性

哪些盘"快"哪些盘"慢"，取决于 fio 进程启动时的 CPU 调度决策和运行时的线程迁移行为——**每次运行结果可能不同**，但总是有部分盘快、部分盘慢。

---

## 五、解决方案

### 方案一（推荐）：为每个 fio 进程绑定固定 CPU

这是最精准的方案。确保每个 fio 线程不会跨 CPU 迁移，所有请求在同一个 HW Queue 中完成合并。

**方法 A：使用 taskset 绑核**

```bash
cpu=0
for dev in /dev/sd{b..z} /dev/sda{a..k}; do
    taskset -c $cpu fio --ioengine=libaio \
        --randrepeat=0 --norandommap --thread --direct=1 \
        --group_reporting --name="test_$(basename $dev)" \
        --runtime=3600 --time_based \
        --numjobs=1 --iodepth=128 \
        --filename=$dev --rw=read --bs=64K &
    cpu=$((cpu + 1))
done
wait
```

**方法 B：使用单个 fio 配置文件 + cpus_allowed**

```ini
; fio_all_disks.fio
[global]
ioengine=libaio
randrepeat=0
norandommap
thread
direct=1
runtime=3600
time_based
numjobs=1
iodepth=128
rw=read
bs=64K

[sdb]
filename=/dev/sdb
cpus_allowed=0

[sdc]
filename=/dev/sdc
cpus_allowed=1

[sdd]
filename=/dev/sdd
cpus_allowed=2

; ... 每块盘分配一个独立 CPU 核心 ...

[sdak]
filename=/dev/sdak
cpus_allowed=35
```

然后运行：

```bash
fio fio_all_disks.fio
```

**方法 C：生成配置文件的脚本**

```bash
#!/bin/bash
CONFIG="/tmp/fio_36disks.fio"

cat > $CONFIG << 'EOF'
[global]
ioengine=libaio
randrepeat=0
norandommap
thread
direct=1
runtime=3600
time_based
numjobs=1
iodepth=128
rw=read
bs=64K
EOF

cpu=0
for dev in /dev/sd{b..z} /dev/sda{a..k}; do
    name=$(basename $dev)
    cat >> $CONFIG << EOF

[$name]
filename=$dev
cpus_allowed=$cpu
EOF
    cpu=$((cpu + 1))
done

echo "生成配置文件: $CONFIG"
echo "运行命令: fio $CONFIG"
```

### 方案二（简单有效）：增大 bs 到 1M

将 `bs=64K` 改为 `bs=1M`，每个请求本身就是 1MB，不依赖合并即可达到高带宽：

```bash
fio ... --bs=1M --iodepth=32
```

bs=1M 时：
- 单个请求已经足够大，无需合并
- 即使请求分散到不同 HW Queue 也不影响
- 降低 iodepth 也能达到满带宽

### 方案三：关闭多硬件队列或减少数量

在 mpt3sas 模块级别限制 HW Queue 数量（需要重新加载驱动）：

```bash
# 查看当前参数
cat /sys/module/mpt3sas/parameters/*

# 卸载重载（危险操作，需确认无业务 I/O）
modprobe -r mpt3sas
modprobe mpt3sas max_msix_vectors=1
```

或在内核启动参数中添加：

```
mpt3sas.max_msix_vectors=1
```

这会将 HW Queue 减少到 1 个，所有请求在同一队列中合并，但会牺牲多核并行能力。

### 方案四：调整块层参数

```bash
for dev in sd{b..z} sda{a..k}; do
    # 增大 max_sectors_kb 允许更大的合并请求
    echo 2048 > /sys/block/$dev/queue/max_sectors_kb 2>/dev/null

    # 增大 nr_requests 给调度器更多合并机会
    echo 1024 > /sys/block/$dev/queue/nr_requests
done
```

---

## 六、方案对比

| 方案 | 效果 | 侵入性 | 适用场景 |
|------|------|--------|---------|
| **绑核 (taskset/cpus_allowed)** | ★★★★★ | 低 | 最推荐，精准解决 |
| **增大 bs=1M** | ★★★★★ | 低 | 如果测试场景允许改 bs |
| **减少 nr_hw_queues** | ★★★★☆ | 高（需重载驱动） | 不方便改 fio 参数时 |
| **增大 nr_requests** | ★★★☆☆ | 低 | 辅助优化 |

---

## 七、总结

```
问题本质:
  fio 线程在 120 个 CPU 核心间迁移
    → 64K 请求分散到不同的 blk-mq 硬件队列
    → 队列间无法合并请求
    → 某些盘的请求恰好集中在一个队列 (合并 → 270 MB/s)
    → 某些盘的请求分散在多个队列 (不合并 → 120 MB/s)

证据:
  高带宽盘: rrqm/s=4000, rareq-sz=900KB  ← 合并生效
  低带宽盘: rrqm/s=0,    rareq-sz=64KB   ← 合并失效

解法:
  为每个 fio 绑定固定 CPU 核心 (taskset -c N fio ...)
  或 增大 bs 至 1M 以消除对合并的依赖
```
