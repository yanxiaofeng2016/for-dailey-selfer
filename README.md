# PCI Hardware Error Handling

## 问题分析

### 内核日志中的问题

```
[  768.841232] enyx_hfp_pci 0000:ca:00.0: Retrying bus destruction
[  768.841232] enyx_hfp_pci 0000:ca:00.0: Retrying bus destruction
... (重复数百次，在约 0.3 秒内)
[  770.282979] {3}[Hardware Error]: Hardware error from APEI Generic Hardware Error Source: 5
[  770.282980] {3}[Hardware Error]: event severity: fatal
[  770.282981] {3}[Hardware Error]:   section_type: PCIe error
[  770.282983] {3}[Hardware Error]:   device_id: 0000:c9:02.0
[  770.282986] {3}[Hardware Error]:   aer_uncor_status: 0x00044000, aer_uncor_mask: 0x01310000
[  770.282987] Kernel panic - not syncing: Fatal hardware error!
```

### 根本原因

1. **无限重试循环**：驱动程序在 `bus destruction` 操作失败时无限重试，没有退出条件
2. **无延迟重试**：重试之间没有任何延迟，导致在极短时间内（约 0.3 秒）执行了数百次重试
3. **PCIe 总线过载**：快速的无限重试对 PCIe 总线造成压力，触发了 AER（高级错误报告）检测到的不可纠正错误
4. **致命错误未处理**：没有检测硬件是否已处于不可恢复状态，导致继续无效的重试

### 错误码解析

- `aer_uncor_status: 0x00044000` - 表示检测到以下不可纠正错误：
  - Bit 14: Completion Timeout
  - Bit 18: Malformed TLP
- `status: 0x4010` - PCI 状态寄存器显示：
  - Bit 4: Capabilities List exists
  - Bit 14: Signaled System Error
- `device_id: 0000:c9:02.0` - 错误发生在根端口，是设备 `0000:ca:00.0` 的上游桥接器

## 解决方案

### 1. 重试次数限制

```c
#define PCI_BUS_DESTROY_MAX_RETRIES     10
```

### 2. 指数退避延迟

```c
static inline unsigned int pci_calculate_backoff_delay(unsigned int retry_count)
{
    unsigned int delay = PCI_BUS_DESTROY_RETRY_DELAY_MS << retry_count;
    return min(delay, (unsigned int)PCI_RETRY_MAX_BACKOFF_MS);
}
```

### 3. 超时机制

```c
#define PCI_BUS_DESTROY_TIMEOUT_MS      5000

if (time_after(jiffies, start_time + 
               msecs_to_jiffies(PCI_BUS_DESTROY_TIMEOUT_MS)))
    return true;  // 中止重试
```

### 4. 致命错误检测

```c
if (status & PCI_STATUS_DETECTED_PARITY ||
    status & PCI_STATUS_SIG_SYSTEM_ERROR ||
    status & PCI_STATUS_REC_MASTER_ABORT) {
    dev_err(&pdev->dev, "Fatal PCI status detected: 0x%04x\n", status);
    return -EIO;  // 不再重试
}
```

### 5. PCI AER 错误处理

注册 `pci_error_handlers` 回调来正确处理 PCIe 错误：

```c
static const struct pci_error_handlers enyx_hfp_err_handlers = {
    .error_detected = enyx_hfp_error_detected,
    .slot_reset = enyx_hfp_slot_reset,
    .resume = enyx_hfp_resume,
};
```

## 文件说明

- `pci_error_handling.h` - 头文件，定义常量和数据结构
- `pci_error_handling.c` - 实现文件，包含安全的错误处理函数

## 关键修复对比

### 原始有问题的代码

```c
while (!bus_destroyed) {
    ret = try_destroy_bus(dev);
    if (ret) {
        dev_info(&pdev->dev, "Retrying bus destruction");
        // 问题：无延迟、无重试限制、无超时！
    }
}
```

### 修复后的代码

```c
while (1) {
    ret = try_bus_destruction(dev);
    
    if (ret == 0)
        return 0;  // 成功
    
    // 检查是否应该中止（重试次数或超时）
    if (pci_should_abort_retry(retries, start_time))
        return -ETIMEDOUT;
    
    // 致命错误立即退出
    if (ret == -ENODEV || ret == -EIO)
        return ret;
    
    // 使用指数退避延迟
    msleep(pci_calculate_backoff_delay(retries));
    
    retries++;
}
```

## 最佳实践

1. **永远不要使用无限循环**进行硬件重试
2. **始终添加延迟**在重试之间，给硬件恢复时间
3. **使用 `msleep()` 而不是 `mdelay()`**以允许调度器运行
4. **检测不可恢复的错误**并优雅退出
5. **注册 PCI AER 错误处理程序**以正确响应硬件错误
6. **记录诊断信息**以便调试

## 构建

```bash
# 创建 Makefile（如果需要）
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
```

## 许可证

GPL-2.0
