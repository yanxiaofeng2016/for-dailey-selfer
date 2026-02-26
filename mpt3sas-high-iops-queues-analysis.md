# mpt3sas 驱动 HBA 中断分配不均衡根因分析

## 1. 问题描述

| 对比项 | Intel 4313 | 海光 S435 |
|--------|-----------|-----------|
| CPU | 16 core | 32 core |
| 服务器 | 单路 (32 CPU) | 双路 (128 CPU) |
| HBA 卡 | 9500-16i | 9500-8i |
| 驱动 | mpt3sas v43.100.00.00 | mpt3sas v43.100.00.00 |
| 中断分配 | 32+8 (每CPU一个) | 120+8 (不均衡) |
| FIO 带宽 | **均衡** | **不均衡** |

海光平台上通过 `modprobe mpt3sas max_msix_vectors=128` 可修复不均衡问题。

## 2. 根因定位

**核心结论：这不是 CPU 厂商判断问题，而是驱动的 `high_iops_queues` 特性在 CPU 数等于 HBA 最大 MSI-X 向量数时产生的算术溢出问题。**

### 2.1 关键数据结构和宏定义

```c
// mpt3sas_base.h
#define MPT3SAS_HIGH_IOPS_REPLY_QUEUES    8    // high iops 队列数
#define MPT3SAS_GEN35_MAX_MSIX_QUEUES     128  // SAS3.5 最大 MSI-X 向量数
#define MPT3SAS_DEVICE_HIGH_IOPS_DEPTH    8    // 设备队列深度阈值
#define MPT3SAS_HIGH_IOPS_BATCH_COUNT     16   // 批量计数
```

### 2.2 中断分配完整调用链

```
_base_enable_msix()
  ├── _base_check_enable_msix()          // 从 PCI config 读取 msix_vector_count
  ├── reply_queue_count = min(cpu_count, msix_vector_count)
  ├── _base_check_and_enable_high_iops_queues()  // 决定 high_iops_queues
  ├── reply_queue_count = min(reply_queue_count + high_iops_queues, msix_vector_count)
  ├── _base_alloc_irq_vectors()          // 实际分配 MSI-X 向量
  │     └── pci_alloc_irq_vectors_affinity(pdev, high_iops_queues, nr_msix, flags, descp)
  │           descp->pre_vectors = high_iops_queues  ← 关键！
  └── _base_assign_reply_queues()        // 建立 cpu_msix_table 映射
```

### 2.3 `high_iops_queues` 启用条件

```c
// mpt3sas_base.c:3340-3346
if (!reset_devices && ioc->is_aero_ioc &&
    hba_msix_vector_count == MPT3SAS_GEN35_MAX_MSIX_QUEUES &&  // == 128
    num_online_cpus() >= MPT3SAS_HIGH_IOPS_REPLY_QUEUES &&     // >= 8
    max_msix_vectors == -1)                                      // 默认值
        ioc->high_iops_queues = MPT3SAS_HIGH_IOPS_REPLY_QUEUES; // = 8
    else
        ioc->high_iops_queues = 0;
```

9500 系列 HBA（SAS3816/SAS3916）的 `is_aero_ioc = 1`，两个平台上此条件**都满足**，所以 `high_iops_queues = 8`。

### 2.4 `pre_vectors` 的影响

```c
// mpt3sas_base.c:3373
struct irq_affinity desc = { .pre_vectors = ioc->high_iops_queues };
```

`pre_vectors` 传给内核的 `pci_alloc_irq_vectors_affinity()`，含义是：

- **前 N 个 MSI-X 向量不参与内核的 CPU 亲和性自动分配**
- 这 N 个向量由驱动自行管理亲和性（设置到 NUMA 本地节点）
- 剩余的向量由内核自动均匀分配到各 CPU

## 3. 两个平台的详细推导

### 3.1 Intel 4313 平台（32 CPU）

```
Step 1: msix_vector_count = 128  (PCI config 读取)
Step 2: reply_queue_count = min(32, 128) = 32
Step 3: high_iops_queues = 8  (条件全部满足)
Step 4: reply_queue_count = min(32 + 8, 128) = 40
Step 5: pci_alloc_irq_vectors_affinity(pdev, min=8, max=40, pre_vectors=8)
         ├── 向量 0~7:  high_iops 队列 (不参与CPU亲和性分配, 绑到NUMA本地节点)
         └── 向量 8~39: 普通 reply 队列 (内核自动分配CPU亲和性)
                         40 - 8 = 32 个向量 → 32 个 CPU
                         ✅ 完美 1:1 映射，每个 CPU 一个中断
```

### 3.2 海光 S435 平台（128 CPU）

```
Step 1: msix_vector_count = 128  (PCI config 读取)
Step 2: reply_queue_count = min(128, 128) = 128
Step 3: high_iops_queues = 8  (条件全部满足)
Step 4: reply_queue_count = min(128 + 8, 128) = 128  ← 被 msix_vector_count 截断！
Step 5: pci_alloc_irq_vectors_affinity(pdev, min=8, max=128, pre_vectors=8)
         ├── 向量 0~7:   high_iops 队列 (不参与CPU亲和性分配)
         └── 向量 8~127: 普通 reply 队列 (内核自动分配CPU亲和性)
                          128 - 8 = 120 个向量 → 128 个 CPU
                          ❌ 120 < 128, 有 8 个 CPU 必须与其他 CPU 共享中断向量！
```

**问题的本质：** 当 `num_online_cpus() + high_iops_queues > msix_vector_count` 时，high_iops 队列"挤占"了普通回复队列的名额，导致部分 CPU 无法获得专属中断向量。

### 3.3 设置 `max_msix_vectors=128` 为何能修复

```
Step 3: _base_check_and_enable_high_iops_queues() 检查条件:
         max_msix_vectors == -1  →  FALSE (此时为 128)
         → high_iops_queues = 0  ← high_iops 特性被禁用！

Step 4: reply_queue_count = min(128 + 0, 128) = 128
Step 5: pci_alloc_irq_vectors_affinity(pdev, min=0, max=128, pre_vectors=0)
         └── 全部 128 个向量都参与 CPU 亲和性分配
             128 个向量 → 128 个 CPU
             ✅ 完美 1:1 映射
```

设置 `max_msix_vectors=128` 实际上是**间接禁用了 high_iops_queues 特性**，因为驱动代码中启用 high_iops 的条件之一是 `max_msix_vectors == -1`（默认值）。

## 4. IO 不均衡的传导机制

### 4.1 CPU → 中断向量映射

```c
// _base_assign_reply_queues() 中的 cpu_msix_table 建立过程:
// 当 smp_affinity_enable 时，通过 pci_irq_get_affinity() 获取每个向量的亲和CPU
for_each_cpu_and(cpu, mask, cpu_online_mask) {
    ioc->cpu_msix_table[cpu] = reply_q->msix_index;
}
```

120 个向量分配给 128 个 CPU 时，有 8 个 CPU 必须和其他 CPU 共享同一个 `msix_index`。

### 4.2 IO 提交路径

```c
// _base_get_msix_index(): IO 提交时选择回复队列
return ioc->cpu_msix_table[raw_smp_processor_id()];
```

共享中断向量的 CPU 对将 IO 提交到同一个硬件回复队列，导致：
1. **回复队列争用**：两个 CPU 的完成中断路由到同一个目标 CPU
2. **IO 合并行为改变**：来自不同 CPU 的 IO 进入同一队列后，block layer 可能进行合并
3. **中断处理不均匀**：部分 CPU 处理 2 倍的中断负载，部分 CPU 空闲

### 4.3 与 IO 合并的关联

用户观察到"不合并就低"——这是因为：
- 共享队列的 CPU 发出的 IO 在同一 reply queue 上排队
- block layer 的 IO 调度器在合并时考虑队列亲和性
- 共享队列改变了 IO 的逻辑归属，影响了合并决策
- 当所有 CPU 1:1 映射后，IO 合并路径一致，带宽均衡

## 5. high_iops 队列的设计意图

```c
// _base_get_high_iops_msix_index():
if (scsi_device_busy(scmd->device) > MPT3SAS_DEVICE_HIGH_IOPS_DEPTH)  // > 8
    return base_mod64((
        atomic64_add_return(1, &ioc->high_iops_outstanding) /
        MPT3SAS_HIGH_IOPS_BATCH_COUNT),   // 每 16 个 IO 轮转
        MPT3SAS_HIGH_IOPS_REPLY_QUEUES);  // 在 8 个队列间轮转
```

high_iops 队列是为高 IOPS 场景设计的优化：
- 当某设备的 queue depth > 8 时，IO 被路由到 8 个专用的 high_iops 队列
- 这些队列绑定到 NUMA 本地节点的 CPU，减少跨 NUMA 访问延迟
- 以每 16 个 IO 为一批在 8 个队列间轮转，减少中断聚合延迟

但这个设计**没有考虑到 `cpu_count >= msix_vector_count` 的场景**。

## 6. 修复方案

### 方案 A：临时 workaround（不改代码）

```bash
# 方法 1：设置 max_msix_vectors 等于 CPU 数（间接禁用 high_iops）
modprobe mpt3sas max_msix_vectors=128

# 方法 2：显式设置性能模式为 IOPS 或 LATENCY（直接禁用 high_iops）
modprobe mpt3sas perf_mode=1   # MPT_PERF_MODE_IOPS
# 或
modprobe mpt3sas perf_mode=2   # MPT_PERF_MODE_LATENCY
```

### 方案 B：内核补丁（根本修复）

在 `_base_check_and_enable_high_iops_queues()` 中增加检查：当 CPU 数 + high_iops_queues 超过 HBA 最大向量数时，不启用 high_iops 特性。

```c
// 修改 _base_check_and_enable_high_iops_queues() 函数
static void
_base_check_and_enable_high_iops_queues(struct MPT3SAS_ADAPTER *ioc,
        int hba_msix_vector_count)
{
    u16 lnksta, speed;

    if (perf_mode == MPT_PERF_MODE_IOPS ||
        perf_mode == MPT_PERF_MODE_LATENCY ||
        ioc->io_uring_poll_queues) {
        ioc->high_iops_queues = 0;
        return;
    }

    if (perf_mode == MPT_PERF_MODE_DEFAULT) {
        pcie_capability_read_word(ioc->pdev, PCI_EXP_LNKSTA, &lnksta);
        speed = lnksta & PCI_EXP_LNKSTA_CLS;
        if (speed < 0x4) {
            ioc->high_iops_queues = 0;
            return;
        }
    }

    if (!reset_devices && ioc->is_aero_ioc &&
        hba_msix_vector_count == MPT3SAS_GEN35_MAX_MSIX_QUEUES &&
        num_online_cpus() >= MPT3SAS_HIGH_IOPS_REPLY_QUEUES &&
        max_msix_vectors == -1) {
        /*
         * 新增检查：如果 CPU 数 + high_iops 队列数超过 HBA 支持的
         * 最大 MSI-X 向量数，则不启用 high_iops 特性，
         * 否则会导致部分 CPU 无法获得专属中断向量。
         */
        if (num_online_cpus() + MPT3SAS_HIGH_IOPS_REPLY_QUEUES
            > hba_msix_vector_count) {
            ioc->high_iops_queues = 0;
            ioc_info(ioc,
                "Disabling high_iops_queues: online CPUs(%d) + "
                "high_iops_queues(%d) > max MSI-X vectors(%d)\n",
                num_online_cpus(),
                MPT3SAS_HIGH_IOPS_REPLY_QUEUES,
                hba_msix_vector_count);
            return;
        }
        ioc->high_iops_queues = MPT3SAS_HIGH_IOPS_REPLY_QUEUES;
    } else
        ioc->high_iops_queues = 0;
}
```

### 方案 C：更优雅的内核补丁

不是简单禁用 high_iops，而是动态调整 high_iops 队列数量，使其适应实际 CPU 数：

```c
if (!reset_devices && ioc->is_aero_ioc &&
    hba_msix_vector_count == MPT3SAS_GEN35_MAX_MSIX_QUEUES &&
    num_online_cpus() >= MPT3SAS_HIGH_IOPS_REPLY_QUEUES &&
    max_msix_vectors == -1) {
    int available = hba_msix_vector_count - num_online_cpus();
    if (available >= MPT3SAS_HIGH_IOPS_REPLY_QUEUES)
        ioc->high_iops_queues = MPT3SAS_HIGH_IOPS_REPLY_QUEUES;
    else if (available > 0)
        ioc->high_iops_queues = available;
    else
        ioc->high_iops_queues = 0;
} else
    ioc->high_iops_queues = 0;
```

## 7. 结论

| 问题 | 答案 |
|------|------|
| 驱动是否有 CPU 厂商判断？ | **没有**。mpt3sas 驱动不区分 Intel/AMD/海光 |
| 为什么 Intel 正常、海光不正常？ | Intel 32 CPU < 120 可用向量，1:1 映射。海光 128 CPU > 120 可用向量，不足 |
| 120 从哪来的？ | 128 (HBA 最大) - 8 (high_iops pre_vectors) = 120 |
| max_msix_vectors=128 为何修复？ | 因为禁用了 high_iops_queues，全部 128 向量都用于 CPU 亲和性分配 |
| 根本原因？ | high_iops 特性没有检查 `cpu_count + high_iops_queues > msix_vector_count` |
