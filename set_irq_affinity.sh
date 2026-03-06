#!/bin/bash
#
# 网卡多队列 IRQ 亲和性一对一绑定脚本
# 将 eth0 + eth1 所有队列依次绑定到 CPU 0-31, 64-95
# 每个队列只绑定一个 CPU，每个 CPU 最多绑定一个队列

set -euo pipefail

CPU_POOL=($(seq 0 31) $(seq 64 95))

# 从 /proc/interrupts 提取指定网卡的 IRQ 号（最可靠的方式）
get_irqs() {
    local dev=$1
    awk -v dev="$dev" '$0 ~ dev"-" {gsub(/:/, "", $1); print $1}' /proc/interrupts | sort -n
}

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 权限运行"
    exit 1
fi

echo "停用 irqbalance..."
systemctl stop irqbalance 2>/dev/null || true

mapfile -t ETH0_IRQS < <(get_irqs eth0)
mapfile -t ETH1_IRQS < <(get_irqs eth1)

ALL_IRQS=("${ETH0_IRQS[@]}" "${ETH1_IRQS[@]}")
TOTAL=${#ALL_IRQS[@]}

echo "eth0 队列数: ${#ETH0_IRQS[@]}  IRQ: ${ETH0_IRQS[*]}"
echo "eth1 队列数: ${#ETH1_IRQS[@]}  IRQ: ${ETH1_IRQS[*]}"
echo "总队列数:    ${TOTAL}"
echo "CPU 池:      0-31, 64-95 (共 ${#CPU_POOL[@]} 个)"
echo ""

if [ "$TOTAL" -gt ${#CPU_POOL[@]} ]; then
    echo "错误: 队列数 (${TOTAL}) 超过可用 CPU 数 (${#CPU_POOL[@]})"
    exit 1
fi

if [ "$TOTAL" -eq 0 ]; then
    echo "错误: 未检测到任何网卡队列 IRQ"
    exit 1
fi

IDX=0
for irq in "${ALL_IRQS[@]}"; do
    cpu=${CPU_POOL[$IDX]}
    echo "$cpu" > "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null && \
        printf "IRQ %3d -> CPU %2d\n" "$irq" "$cpu" || \
        printf "IRQ %3d -> CPU %2d  [失败]\n" "$irq" "$cpu"
    IDX=$((IDX + 1))
done

echo ""
echo "完成: ${TOTAL} 个队列已一对一绑定到 ${TOTAL} 个 CPU"
