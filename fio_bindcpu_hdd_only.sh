#!/bin/bash
#
# FIO 绑核测试脚本 —— 仅对机械盘 (HDD) 执行
# 自动识别机械盘，自动检测 HBA NUMA 节点，只绑定本地 CPU
#

IOENGINE="${IOENGINE:-libaio}"
RW_MODE="${RW_MODE:-read}"
BS="${BS:-64K}"
IODEPTH="${IODEPTH:-128}"
RUNTIME="${RUNTIME:-60}"

# ========== 第一步: 找到 HDD 所在的 SCSI Host 和 NUMA 节点 ==========

find_hba_numa() {
    local target_host=""
    local max_disks=0

    for host_dir in /sys/class/scsi_host/host*; do
        local h=$(basename "$host_dir")
        local count=0
        for dev in /sys/block/sd*; do
            local rot=$(cat "$dev/queue/rotational" 2>/dev/null)
            [ "$rot" != "1" ] && continue
            local link=$(readlink -f "$dev/device" 2>/dev/null)
            if echo "$link" | grep -q "$h"; then
                count=$((count + 1))
            fi
        done
        if [ "$count" -gt "$max_disks" ]; then
            max_disks=$count
            target_host=$h
        fi
    done

    if [ -z "$target_host" ]; then
        echo "-1"
        return
    fi

    local host_dir="/sys/class/scsi_host/$target_host"
    local numa_node=-1

    for path in "$host_dir/device/numa_node" "$host_dir/device/../numa_node"; do
        if [ -f "$path" ]; then
            numa_node=$(cat "$path" 2>/dev/null)
            [ "$numa_node" != "-1" ] && break
        fi
    done

    if [ "$numa_node" = "-1" ]; then
        local pci_addr=$(readlink -f "$host_dir/device" | grep -oP '\d+:\d+:\d+\.\d+' | head -1)
        if [ -n "$pci_addr" ] && [ -f "/sys/bus/pci/devices/$pci_addr/numa_node" ]; then
            numa_node=$(cat "/sys/bus/pci/devices/$pci_addr/numa_node" 2>/dev/null)
        fi
    fi

    echo "$target_host $numa_node"
}

# ========== 第二步: 获取指定 NUMA 节点的 CPU 列表 ==========

get_numa_cpus() {
    local node=$1

    if [ "$node" = "-1" ] || [ -z "$node" ]; then
        # NUMA 未知，返回所有 CPU
        nproc_val=$(nproc)
        seq 0 $((nproc_val - 1))
        return
    fi

    local cpulist_file="/sys/devices/system/node/node${node}/cpulist"
    if [ -f "$cpulist_file" ]; then
        local raw=$(cat "$cpulist_file")
        # 展开 "0-3,8-11" 格式为逐行数字
        echo "$raw" | tr ',' '\n' | while read range; do
            if echo "$range" | grep -q '-'; then
                local start=$(echo "$range" | cut -d'-' -f1)
                local end=$(echo "$range" | cut -d'-' -f2)
                seq $start $end
            else
                echo "$range"
            fi
        done
        return
    fi

    nproc_val=$(nproc)
    seq 0 $((nproc_val - 1))
}

# ========== 主流程 ==========

echo "========================================"
echo " FIO 绑核测试 (仅机械盘)"
echo "========================================"
echo ""

# 探测 HBA NUMA
read target_host hba_numa <<< $(find_hba_numa)
echo "HBA SCSI Host: $target_host"
echo "HBA NUMA 节点: $hba_numa"

if [ "$hba_numa" != "-1" ] && [ -n "$hba_numa" ]; then
    cpulist_file="/sys/devices/system/node/node${hba_numa}/cpulist"
    echo "本地 CPU 列表: $(cat $cpulist_file 2>/dev/null)"
fi

# 获取本地 NUMA 的 CPU 数组
mapfile -t LOCAL_CPUS < <(get_numa_cpus "$hba_numa")
echo "可用 CPU 数量: ${#LOCAL_CPUS[@]}"
echo ""

# NUMA 拓扑概览
echo "--- NUMA 拓扑 ---"
if command -v numactl &>/dev/null; then
    numactl -H 2>/dev/null | head -20
else
    for node_dir in /sys/devices/system/node/node*; do
        n=$(basename "$node_dir")
        cpus=$(cat "$node_dir/cpulist" 2>/dev/null)
        echo "  $n: CPUs $cpus"
    done
fi
echo ""

# 测试参数
echo "--- 测试参数 ---"
echo "  ioengine=$IOENGINE  rw=$RW_MODE  bs=$BS  iodepth=$IODEPTH  runtime=${RUNTIME}s"
echo ""

echo "--- 启动测试 ---"
cpu_idx=0
hdd_count=0
skipped=""

for dev in /sys/block/sd*; do
    name=$(basename "$dev")
    devpath="/dev/$name"

    [ -b "$devpath" ] || continue

    rotational=$(cat "$dev/queue/rotational" 2>/dev/null)
    if [ "$rotational" != "1" ]; then
        model=$(cat "$dev/device/model" 2>/dev/null | xargs)
        skipped="$skipped  $name ($model) - SSD/非机械盘, 跳过\n"
        continue
    fi

    if [ $cpu_idx -ge ${#LOCAL_CPUS[@]} ]; then
        echo "[WARN] 本地 NUMA CPU 不够用, $name 将复用 CPU (从头轮转)"
        cpu_idx=0
    fi

    target_cpu=${LOCAL_CPUS[$cpu_idx]}
    model=$(cat "$dev/device/model" 2>/dev/null | xargs)
    echo "  $devpath ($model) → CPU $target_cpu (NUMA $hba_numa)"

    taskset -c $target_cpu fio --ioengine=$IOENGINE \
        --randrepeat=0 --norandommap --thread --direct=1 \
        --group_reporting --name="test_$name" \
        --runtime=$RUNTIME --time_based \
        --numjobs=1 --iodepth=$IODEPTH \
        --filename=$devpath --rw=$RW_MODE --bs=$BS &

    cpu_idx=$((cpu_idx + 1))
    hdd_count=$((hdd_count + 1))
done

if [ -n "$skipped" ]; then
    echo ""
    echo "跳过的设备:"
    echo -e "$skipped"
fi

echo ""
echo "共启动 $hdd_count 块机械盘测试 (绑定 NUMA $hba_numa 本地 CPU), 等待完成..."
echo ""
wait
echo "全部测试完成"
