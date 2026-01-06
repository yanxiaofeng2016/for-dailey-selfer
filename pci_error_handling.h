/* SPDX-License-Identifier: GPL-2.0 */
/*
 * PCI Hardware Error Handling - Header
 *
 * 这个头文件定义了 PCI 设备驱动程序中硬件错误处理的常量和数据结构。
 * 用于解决类似 "Retrying bus destruction" 无限循环的问题。
 */

#ifndef _PCI_ERROR_HANDLING_H
#define _PCI_ERROR_HANDLING_H

#include <linux/pci.h>
#include <linux/aer.h>
#include <linux/delay.h>
#include <linux/jiffies.h>

/*
 * 重试策略常量
 * 
 * 问题分析：原始代码在 bus destruction 时使用无限重试，没有：
 * 1. 重试次数限制
 * 2. 重试间延迟
 * 3. 超时机制
 * 
 * 这导致了快速无限循环，最终触发 PCIe AER 致命错误。
 */

/* 最大重试次数 - 避免无限循环 */
#define PCI_BUS_DESTROY_MAX_RETRIES     10

/* 重试间延迟（毫秒）- 给硬件恢复时间 */
#define PCI_BUS_DESTROY_RETRY_DELAY_MS  100

/* 操作超时时间（毫秒） */
#define PCI_BUS_DESTROY_TIMEOUT_MS      5000

/* 指数退避最大延迟（毫秒） */
#define PCI_RETRY_MAX_BACKOFF_MS        1000

/*
 * 错误处理状态
 */
enum pci_error_state {
	PCI_ERR_STATE_NORMAL = 0,
	PCI_ERR_STATE_RECOVERING,
	PCI_ERR_STATE_FAILED,
	PCI_ERR_STATE_FATAL,
};

/*
 * 设备私有数据结构
 */
struct enyx_hfp_device {
	struct pci_dev *pdev;
	void __iomem *bar0;
	
	/* 错误处理状态 */
	enum pci_error_state error_state;
	atomic_t recovery_in_progress;
	
	/* 统计信息 */
	unsigned int bus_destroy_retries;
	unsigned int total_errors;
	unsigned long last_error_jiffies;
};

/*
 * 内联辅助函数
 */

/**
 * pci_should_abort_retry - 检查是否应该中止重试
 * @retries: 当前重试次数
 * @start_time: 操作开始时间（jiffies）
 *
 * 返回: true 如果应该中止，false 继续重试
 */
static inline bool pci_should_abort_retry(unsigned int retries,
					  unsigned long start_time)
{
	/* 检查重试次数限制 */
	if (retries >= PCI_BUS_DESTROY_MAX_RETRIES)
		return true;
	
	/* 检查超时 */
	if (time_after(jiffies, start_time + 
		       msecs_to_jiffies(PCI_BUS_DESTROY_TIMEOUT_MS)))
		return true;
	
	return false;
}

/**
 * pci_calculate_backoff_delay - 计算指数退避延迟
 * @retry_count: 当前重试次数
 *
 * 返回: 延迟时间（毫秒）
 */
static inline unsigned int pci_calculate_backoff_delay(unsigned int retry_count)
{
	unsigned int delay = PCI_BUS_DESTROY_RETRY_DELAY_MS << retry_count;
	
	return min(delay, (unsigned int)PCI_RETRY_MAX_BACKOFF_MS);
}

/* 函数声明 */
int enyx_hfp_bus_destroy_safe(struct enyx_hfp_device *dev);
void enyx_hfp_handle_fatal_error(struct enyx_hfp_device *dev);

#endif /* _PCI_ERROR_HANDLING_H */
