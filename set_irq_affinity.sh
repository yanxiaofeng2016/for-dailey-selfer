#!/bin/bash
#
# 网卡多队列 IRQ 亲和性一对一绑定脚本
# 将 eth0 + eth1 共 38 个队列依次绑定到 CPU 0-31, 64-95
# 每个队列只绑定一个 CPU，每个 CPU 最多绑定一个队列

set -euo pipefail

# 构建 CPU 池: 0-31, 64-95 (共 64 个)
CPU_POOL=($(seq 0 31) $(seq 64 95))

# eth0 IRQ: 250-268, 292-294 (共 22 个)
# eth1 IRQ: 271-289          (共 19 个)
# 合计 41 个，用户声明 38 个，以实际检测为准
get_irqs() {
    local dev=$1
    local irqs=()
    for f in /sys/class/net/"${dev}"/device/msi_irqs/*; do
        [ -e "$f" ] && irqs+=("$(basename "$f")")
    done
    if [ ${#irqs[@]} -gt 0 ]; then
        IFS=$'\n' irqs=($(sort -n <<<"${irqs[*]}")); unset IFS
        echo "${irqs[@]}"
        return
    fi

    for irqdir in /proc/irq/*/; do
        local irq
        irq=$(basename "$irqdir")
        [[ "$irq" =~ ^[0-9]+$ ]] || continue
        local action_file="/proc/irq/${irq}/actions"
        [ -f "$action_file" ] || action_file=$(ls "${irqdir}"*action* 2>/dev/null | head -1)
        if [ -n "$action_file" ] && [ -f "$action_file" ] && grep -q "${dev}" "$action_file" 2>/dev/null; then
            irqs+=("$irq")
        fi
    done
    IFS=$'\n' irqs=($(sort -n <<<"${irqs[*]}")); unset IFS
    echo "${irqs[@]}"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 权限运行"
    exit 1
fi

echo "停用 irqbalance..."
systemctl stop irqbalance 2>/dev/null || true

# 收集 IRQ
read -ra ETH0_IRQS <<< "$(get_irqs eth0)"
read -ra ETH1_IRQS <<< "$(get_irqs eth1)"

[ ${#ETH0_IRQS[@]} -eq 0 ] && ETH0_IRQS=($(seq 250 268) $(seq 292 294))
[ ${#ETH1_IRQS[@]} -eq 0 ] && ETH1_IRQS=($(seq 271 289))

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

# 一对一绑定
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
