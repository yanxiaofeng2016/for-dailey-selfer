// SPDX-License-Identifier: GPL-2.0
/*
 * PCI Hardware Error Handling - Implementation
 *
 * 这个文件实现了 PCI 设备驱动程序中的正确错误处理机制。
 * 
 * 问题背景：
 * 原始的 enyx_hfp_pci 驱动在执行 bus destruction 时陷入无限循环：
 *   [768.841232] enyx_hfp_pci 0000:ca:00.0: Retrying bus destruction
 *   ... (重复数百次，无延迟)
 *   [770.282979] {3}[Hardware Error]: Hardware error from APEI Generic Hardware Error Source: 5
 *   [770.282987] Kernel panic - not syncing: Fatal hardware error!
 *
 * 根本原因：
 * 1. 无限重试循环没有退出条件
 * 2. 重试之间没有延迟，导致 PCIe 总线被过度压力
 * 3. 没有检测硬件是否处于不可恢复状态
 *
 * 解决方案：
 * 1. 限制最大重试次数
 * 2. 使用指数退避延迟
 * 3. 实现超时机制
 * 4. 检测致命错误状态并优雅退出
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/pci-ats.h>
#include <linux/aer.h>
#include <linux/delay.h>
#include <linux/sched.h>

#include "pci_error_handling.h"

#define DRIVER_NAME "enyx_hfp_pci"
#define DRIVER_VERSION "2.0.0"

/*
 * 错误修复：安全的总线销毁实现
 *
 * 原始有问题的代码（简化版）：
 *
 *   while (!bus_destroyed) {
 *       ret = try_destroy_bus(dev);
 *       if (ret) {
 *           dev_info(&pdev->dev, "Retrying bus destruction");
 *           // 问题：没有延迟，没有重试限制！
 *       }
 *   }
 *
 * 这会导致：
 * - CPU 100% 占用
 * - PCIe 总线被持续轰炸请求
 * - 最终触发 AER 致命错误
 */

/**
 * try_bus_destruction - 尝试执行总线销毁操作
 * @dev: 设备结构体
 *
 * 返回: 0 成功, 负数错误码失败
 */
static int try_bus_destruction(struct enyx_hfp_device *dev)
{
	struct pci_dev *pdev = dev->pdev;
	u16 status;
	int ret;
	
	/* 首先检查设备是否仍然可达 */
	ret = pci_read_config_word(pdev, PCI_STATUS, &status);
	if (ret != PCIBIOS_SUCCESSFUL) {
		dev_err(&pdev->dev, "Device not accessible, config read failed\n");
		return -EIO;
	}
	
	/* 检查是否有致命错误（如日志中的 status: 0x4010） */
	if (status & PCI_STATUS_DETECTED_PARITY ||
	    status & PCI_STATUS_SIG_SYSTEM_ERROR ||
	    status & PCI_STATUS_REC_MASTER_ABORT) {
		dev_err(&pdev->dev, "Fatal PCI status detected: 0x%04x\n", status);
		return -EIO;
	}
	
	/*
	 * 实际的总线销毁逻辑（根据具体硬件实现）
	 * 这里是占位符，实际实现取决于硬件
	 */
	
	/* 模拟操作可能失败 */
	if (dev->error_state == PCI_ERR_STATE_FATAL)
		return -ENODEV;
	
	return 0;
}

/**
 * enyx_hfp_bus_destroy_safe - 安全的总线销毁，带重试限制和超时
 * @dev: 设备结构体
 *
 * 这个函数替代了原来的无限重试循环。
 *
 * 返回: 0 成功, 负数错误码失败
 */
int enyx_hfp_bus_destroy_safe(struct enyx_hfp_device *dev)
{
	struct pci_dev *pdev = dev->pdev;
	unsigned long start_time = jiffies;
	unsigned int retries = 0;
	unsigned int delay_ms;
	int ret;
	
	dev_info(&pdev->dev, "Starting bus destruction with timeout %d ms, max retries %d\n",
		 PCI_BUS_DESTROY_TIMEOUT_MS, PCI_BUS_DESTROY_MAX_RETRIES);
	
	while (1) {
		ret = try_bus_destruction(dev);
		
		if (ret == 0) {
			dev_info(&pdev->dev, "Bus destruction succeeded after %u retries\n",
				 retries);
			return 0;
		}
		
		/* 检查是否应该中止 */
		if (pci_should_abort_retry(retries, start_time)) {
			dev_err(&pdev->dev, 
				"Bus destruction failed after %u retries, "
				"elapsed time %lu ms\n",
				retries,
				jiffies_to_msecs(jiffies - start_time));
			
			/* 记录失败状态 */
			dev->error_state = PCI_ERR_STATE_FAILED;
			dev->bus_destroy_retries = retries;
			
			return -ETIMEDOUT;
		}
		
		/* 不可恢复的错误，立即退出 */
		if (ret == -ENODEV || ret == -EIO) {
			dev_err(&pdev->dev, 
				"Unrecoverable error during bus destruction: %d\n", ret);
			dev->error_state = PCI_ERR_STATE_FATAL;
			return ret;
		}
		
		/* 使用指数退避延迟 */
		delay_ms = pci_calculate_backoff_delay(retries);
		
		dev_dbg(&pdev->dev, "Retry %u: sleeping %u ms before next attempt\n",
			retries + 1, delay_ms);
		
		/*
		 * 使用 msleep 而不是 udelay/mdelay
		 * - 允许调度器运行其他任务
		 * - 不会占用 CPU
		 * - 给硬件足够的恢复时间
		 */
		msleep(delay_ms);
		
		retries++;
		
		/* 检查是否有挂起的信号（允许用户中断） */
		if (signal_pending(current)) {
			dev_warn(&pdev->dev, "Bus destruction interrupted by signal\n");
			return -EINTR;
		}
	}
}
EXPORT_SYMBOL_GPL(enyx_hfp_bus_destroy_safe);

/*
 * PCI AER (Advanced Error Reporting) 错误处理回调
 *
 * 日志中的错误信息：
 *   aer_uncor_status: 0x00044000  -> 表示不可纠正的错误
 *   aer_uncor_severity: 0x044ef030 -> 表示这些错误是致命的
 */

/**
 * enyx_hfp_error_detected - PCI 错误检测回调
 * @pdev: PCI 设备
 * @state: 错误状态
 *
 * 当 PCIe AER 检测到错误时调用此函数
 */
static pci_ers_result_t enyx_hfp_error_detected(struct pci_dev *pdev,
						pci_channel_state_t state)
{
	struct enyx_hfp_device *dev = pci_get_drvdata(pdev);
	
	dev_err(&pdev->dev, "PCI error detected, state=%d\n", state);
	dev->total_errors++;
	dev->last_error_jiffies = jiffies;
	
	switch (state) {
	case pci_channel_io_normal:
		/* 错误已被纠正，可以继续 */
		dev_info(&pdev->dev, "Correctable error, continuing\n");
		return PCI_ERS_RESULT_CAN_RECOVER;
		
	case pci_channel_io_frozen:
		/*
		 * I/O 被冻结，需要重置
		 * 这对应日志中的情况
		 */
		dev_warn(&pdev->dev, "I/O frozen, requesting slot reset\n");
		dev->error_state = PCI_ERR_STATE_RECOVERING;
		atomic_set(&dev->recovery_in_progress, 1);
		
		/* 停止所有 I/O 操作 */
		/* TODO: 停止 DMA，禁用中断等 */
		
		return PCI_ERS_RESULT_NEED_RESET;
		
	case pci_channel_io_perm_failure:
		/*
		 * 永久性故障，无法恢复
		 * 这对应日志中的 "fatal" 错误和 kernel panic
		 */
		dev_err(&pdev->dev, "Permanent failure, device will be removed\n");
		dev->error_state = PCI_ERR_STATE_FATAL;
		return PCI_ERS_RESULT_DISCONNECT;
		
	default:
		return PCI_ERS_RESULT_NONE;
	}
}

/**
 * enyx_hfp_slot_reset - 插槽重置后的回调
 * @pdev: PCI 设备
 *
 * 在 PCIe 插槽重置后调用
 */
static pci_ers_result_t enyx_hfp_slot_reset(struct pci_dev *pdev)
{
	struct enyx_hfp_device *dev = pci_get_drvdata(pdev);
	int err;
	
	dev_info(&pdev->dev, "Slot reset initiated\n");
	
	/* 重新启用设备 */
	err = pci_enable_device(pdev);
	if (err) {
		dev_err(&pdev->dev, "Cannot re-enable device after reset: %d\n", err);
		dev->error_state = PCI_ERR_STATE_FATAL;
		return PCI_ERS_RESULT_DISCONNECT;
	}
	
	pci_set_master(pdev);
	pci_restore_state(pdev);
	
	/* 重新初始化设备（根据具体硬件实现） */
	/* TODO: 重新初始化 BAR、DMA、中断等 */
	
	dev_info(&pdev->dev, "Slot reset completed successfully\n");
	dev->error_state = PCI_ERR_STATE_NORMAL;
	
	return PCI_ERS_RESULT_RECOVERED;
}

/**
 * enyx_hfp_resume - 错误恢复后的回调
 * @pdev: PCI 设备
 *
 * 在成功恢复后调用，可以恢复正常操作
 */
static void enyx_hfp_resume(struct pci_dev *pdev)
{
	struct enyx_hfp_device *dev = pci_get_drvdata(pdev);
	
	dev_info(&pdev->dev, "Resuming normal operations\n");
	
	atomic_set(&dev->recovery_in_progress, 0);
	dev->error_state = PCI_ERR_STATE_NORMAL;
	
	/* 恢复正常操作（根据具体硬件实现） */
	/* TODO: 重新启动 DMA、启用中断等 */
}

/**
 * enyx_hfp_handle_fatal_error - 处理致命错误
 * @dev: 设备结构体
 *
 * 当检测到不可恢复的错误时调用
 */
void enyx_hfp_handle_fatal_error(struct enyx_hfp_device *dev)
{
	struct pci_dev *pdev = dev->pdev;
	
	dev_crit(&pdev->dev, "Fatal error handler invoked\n");
	dev_crit(&pdev->dev, "Total retries: %u, Total errors: %u\n",
		 dev->bus_destroy_retries, dev->total_errors);
	
	/* 将设备标记为不可用 */
	dev->error_state = PCI_ERR_STATE_FATAL;
	
	/*
	 * 不要尝试进一步的操作！
	 * 原始代码的问题就是在错误状态下继续重试
	 */
	
	/* 记录诊断信息 */
	dev_crit(&pdev->dev, "Device state: vendor=0x%04x device=0x%04x\n",
		 pdev->vendor, pdev->device);
	
	/* 禁用设备 */
	pci_disable_device(pdev);
}
EXPORT_SYMBOL_GPL(enyx_hfp_handle_fatal_error);

/* PCI 错误恢复处理程序结构体 */
static const struct pci_error_handlers enyx_hfp_err_handlers = {
	.error_detected = enyx_hfp_error_detected,
	.slot_reset = enyx_hfp_slot_reset,
	.resume = enyx_hfp_resume,
};

/*
 * 以下是驱动程序的 probe/remove 函数示例
 * 展示如何正确集成错误处理
 */

static int enyx_hfp_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct enyx_hfp_device *dev;
	int err;
	
	dev = kzalloc(sizeof(*dev), GFP_KERNEL);
	if (!dev)
		return -ENOMEM;
	
	dev->pdev = pdev;
	dev->error_state = PCI_ERR_STATE_NORMAL;
	atomic_set(&dev->recovery_in_progress, 0);
	
	pci_set_drvdata(pdev, dev);
	
	err = pci_enable_device(pdev);
	if (err) {
		dev_err(&pdev->dev, "Failed to enable device: %d\n", err);
		goto err_free;
	}
	
	/* 启用 AER（高级错误报告） */
	pci_enable_pcie_error_reporting(pdev);
	
	pci_set_master(pdev);
	
	dev_info(&pdev->dev, "Device probed successfully with error handling v%s\n",
		 DRIVER_VERSION);
	
	return 0;

err_free:
	kfree(dev);
	return err;
}

static void enyx_hfp_remove(struct pci_dev *pdev)
{
	struct enyx_hfp_device *dev = pci_get_drvdata(pdev);
	int ret;
	
	dev_info(&pdev->dev, "Removing device\n");
	
	/*
	 * 使用安全的总线销毁函数
	 * 这是修复的关键！
	 */
	ret = enyx_hfp_bus_destroy_safe(dev);
	if (ret) {
		dev_warn(&pdev->dev, 
			 "Bus destruction failed with %d, proceeding with cleanup\n",
			 ret);
		/*
		 * 即使失败，也要继续清理
		 * 不要陷入无限循环！
		 */
	}
	
	pci_disable_pcie_error_reporting(pdev);
	pci_disable_device(pdev);
	
	kfree(dev);
	
	dev_info(&pdev->dev, "Device removed\n");
}

/* PCI 设备 ID 表 */
static const struct pci_device_id enyx_hfp_ids[] = {
	/* Enyx HFP 设备 */
	{ PCI_DEVICE(0x1234, 0x5678) },  /* 示例 ID，替换为实际值 */
	{ 0 }
};
MODULE_DEVICE_TABLE(pci, enyx_hfp_ids);

/* PCI 驱动程序结构体 */
static struct pci_driver enyx_hfp_driver = {
	.name = DRIVER_NAME,
	.id_table = enyx_hfp_ids,
	.probe = enyx_hfp_probe,
	.remove = enyx_hfp_remove,
	.err_handler = &enyx_hfp_err_handlers,  /* 关键：注册错误处理程序 */
};

module_pci_driver(enyx_hfp_driver);

MODULE_AUTHOR("Enyx");
MODULE_DESCRIPTION("Enyx HFP PCI Driver with Proper Error Handling");
MODULE_LICENSE("GPL");
MODULE_VERSION(DRIVER_VERSION);
