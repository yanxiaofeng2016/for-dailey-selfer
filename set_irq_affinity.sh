#!/bin/bash
#
# 网卡多队列 IRQ 亲和性绑定脚本
# 可用 CPU: 0-31, 64-95
# eth0 队列绑定到 NUMA node 0 (CPU 0-31)
# eth1 队列绑定到 NUMA node 1 (CPU 64-95)

set -euo pipefail

AVAILABLE_CPUS_NODE0=($(seq 0 31))
AVAILABLE_CPUS_NODE1=($(seq 64 95))

cpu_to_mask() {
    local cpu=$1
    if [ "$cpu" -lt 64 ]; then
        printf "%08x,%08x,%08x" 0 0 $((1 << cpu))
    else
        local shifted=$((cpu - 64))
        printf "%08x,%08x,%08x" $((1 << shifted)) 0 0
    fi
}

get_irqs_for_dev() {
    local dev=$1
    local irqs=()
    for irqdir in /proc/irq/*/; do
        local irq=$(basename "$irqdir")
        [[ "$irq" =~ ^[0-9]+$ ]] || continue
        if [ -f "/proc/irq/${irq}/smp_affinity_list" ]; then
            local actions
            actions=$(cat "/proc/irq/${irq}/actions" 2>/dev/null || echo "")
            if echo "$actions" | grep -q "${dev}" 2>/dev/null; then
                irqs+=("$irq")
            fi
        fi
    done
    echo "${irqs[@]}"
}

bind_irqs() {
    local dev=$1
    shift
    local -n cpu_pool=$1
    shift
    local irqs=("$@")
    local pool_size=${#cpu_pool[@]}
    local idx=0

    echo "=============================="
    echo "配置 ${dev} IRQ 亲和性"
    echo "队列数: ${#irqs[@]}, 可用 CPU 池: ${cpu_pool[0]}-${cpu_pool[$((pool_size-1))]}"
    echo "=============================="

    for irq in "${irqs[@]}"; do
        local cpu=${cpu_pool[$((idx % pool_size))]}
        local mask
        mask=$(cpu_to_mask "$cpu")

        echo "  IRQ ${irq} (${dev}) -> CPU ${cpu}"
        echo "$mask" > "/proc/irq/${irq}/smp_affinity" 2>/dev/null || \
            echo "    [警告] 设置 IRQ ${irq} 失败，请确认是否有 root 权限"

        ((idx++))
    done
    echo ""
}

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 权限运行此脚本"
    exit 1
fi

echo "停用 irqbalance 服务（避免系统自动重分配）..."
systemctl stop irqbalance 2>/dev/null || true
systemctl disable irqbalance 2>/dev/null || true

ETH0_IRQS_STR=$(get_irqs_for_dev "eth0")
ETH1_IRQS_STR=$(get_irqs_for_dev "eth1")

read -ra ETH0_IRQS <<< "$ETH0_IRQS_STR"
read -ra ETH1_IRQS <<< "$ETH1_IRQS_STR"

if [ ${#ETH0_IRQS[@]} -eq 0 ]; then
    echo "[信息] 未自动检测到 eth0 的 IRQ，使用预设值 250-268,292-294"
    ETH0_IRQS=($(seq 250 268) $(seq 292 294))
fi

if [ ${#ETH1_IRQS[@]} -eq 0 ]; then
    echo "[信息] 未自动检测到 eth1 的 IRQ，使用预设值 271-289"
    ETH1_IRQS=($(seq 271 289))
fi

echo ""
echo "eth0 IRQ 列表 (${#ETH0_IRQS[@]} 个): ${ETH0_IRQS[*]}"
echo "eth1 IRQ 列表 (${#ETH1_IRQS[@]} 个): ${ETH1_IRQS[*]}"
echo ""

bind_irqs "eth0" AVAILABLE_CPUS_NODE0 "${ETH0_IRQS[@]}"
bind_irqs "eth1" AVAILABLE_CPUS_NODE1 "${ETH1_IRQS[@]}"

echo "=============================="
echo "验证绑定结果"
echo "=============================="
for irq in "${ETH0_IRQS[@]}" "${ETH1_IRQS[@]}"; do
    if [ -f "/proc/irq/${irq}/smp_affinity_list" ]; then
        local_cpu=$(cat "/proc/irq/${irq}/smp_affinity_list")
        echo "  IRQ ${irq} -> CPU ${local_cpu}"
    fi
done

echo ""
echo "完成! eth0 绑定到 NUMA node 0 (CPU 0-31), eth1 绑定到 NUMA node 1 (CPU 64-95)"
