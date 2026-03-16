# 海光 S435 平台 HBA 9500-8i FIO 带宽不均衡问题汇总

## 一、问题描述

| 项目 | 内容 |
|------|------|
| 现象 | 36块机械盘 FIO 测试，各盘带宽不均衡 |
| 平台 | 海光 S435，双路 128 CPU |
| HBA 卡 | 博通 9500-8i (SAS3808 IOC) |
| 驱动 | mpt3sas v43.100.00.00 |
| 临时规避 | `modprobe mpt3sas max_msix_vectors=128` 后均衡 |

## 二、根因分析

| 项目 | 内容 |
|------|------|
| 根因 | mpt3sas 驱动的 `high_iops_queues` 特性占用 8 个 MSI-X 向量作为 `pre_vectors`，不参与内核 CPU 亲和性分配 |
| 直接影响 | 128（HBA 最大）- 8（high_iops 占用）= 120 个亲和性向量 < 128 个 CPU，8 个 CPU 无专属中断 |
| 触发条件 | `is_aero_ioc=1` 且 `msix_vector_count==128` 且 `num_online_cpus()>=8` 且 `max_msix_vectors==-1`（默认） |
| 是否 CPU 厂商相关 | **否**。驱动无 CPU 厂商判断，纯粹是 CPU 数 + 8 > MSI-X 上限 128 的算术溢出 |
| 社区最新代码 | Linux 7.0-rc1 仍存在此问题，无人修复 |

## 三、平台对比

| 对比项 | Intel 4313 + 9500-16i | 海光 S435 + 9500-8i | 海光 S435 + 9560-16i |
|--------|----------------------|---------------------|---------------------|
| CPU 数 | 32 | 128 | 128 |
| 驱动 | mpt3sas | mpt3sas | **megaraid_sas** |
| high_iops | 启用(8) | 启用(8) | **无此特性** |
| 中断分配 | 32+8=40 | 120+8=128 | 128 |
| 亲和性向量 | 32（=CPU 数） | 120（< 128 CPU） | 128（=CPU 数） |
| FIO 带宽 | **均衡** ✅ | **不均衡** ❌ | **均衡** ✅ |
| 均衡原因 | 32 向量 1:1 映射 32 CPU | 120 < 128，8 CPU 共享 | 驱动无 pre_vectors 占用 |

## 四、修复方案

| 方案 | 方法 | 是否改代码 | 影响 |
|------|------|-----------|------|
| A. 模块参数 | `modprobe mpt3sas max_msix_vectors=128` | 否 | 间接禁用 high_iops 特性 |
| B. 性能模式 | `modprobe mpt3sas perf_mode=1` | 否 | 显式禁用 high_iops 特性 |
| C. 内核补丁 | 在 `_base_check_and_enable_high_iops_queues()` 增加边界检查 | 是 | 仅当 CPU 数不足时禁用，其余场景不影响 |

## 五、补丁摘要（方案 C）

| 项目 | 内容 |
|------|------|
| 修改文件 | `drivers/scsi/mpt3sas/mpt3sas_base.c` |
| 修改函数 | `_base_check_and_enable_high_iops_queues()` |
| 修改内容 | 新增判断：`num_online_cpus() + 8 > msix_vector_count` 时禁用 high_iops |
| 影响范围 | 仅影响 CPU ≥ 121 且使用 9500 系列 HBA 的平台 |
| 补丁文件 | `0001-scsi-mpt3sas-disable-high_iops_queues-when-cpu-count-exceeds-available-msix-vectors.patch` |
