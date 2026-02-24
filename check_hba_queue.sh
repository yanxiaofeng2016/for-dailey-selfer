#!/bin/bash
#
# HBA 队列信息采集脚本
# 用于排查 FIO 测试多盘带宽不均衡问题
#

set -e

echo "========================================"
echo " HBA 队列信息采集"
echo " 采集时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo " 主机名:   $(hostname)"
echo " 内核版本: $(uname -r)"
echo "========================================"

echo ""
echo "========== 第一步: 所有 SCSI Host 队列信息 =========="
echo ""

for host in /sys/class/scsi_host/host*; do
    h=$(basename "$host")
    driver=$(cat "$host/proc_name" 2>/dev/null || echo "N/A")
    can_queue=$(cat "$host/can_queue" 2>/dev/null || echo "N/A")
    cmd_per_lun=$(cat "$host/cmd_per_lun" 2>/dev/null || echo "N/A")
    nr_hw_queues=$(cat "$host/nr_hw_queues" 2>/dev/null || echo "N/A")
    sg_tablesize=$(cat "$host/sg_tablesize" 2>/dev/null || echo "N/A")
    active_mode=$(cat "$host/active_mode" 2>/dev/null || echo "N/A")

    printf "%-8s  driver=%-16s  can_queue=%-6s  cmd_per_lun=%-4s  nr_hw_queues=%-4s  sg_tablesize=%-4s\n" \
        "$h" "$driver" "$can_queue" "$cmd_per_lun" "$nr_hw_queues" "$sg_tablesize"
done

echo ""
echo "========== 第二步: 磁盘与 SCSI Host 映射关系 (lsscsi -t) =========="
echo ""

if command -v lsscsi &>/dev/null; then
    lsscsi -t
else
    echo "[WARN] lsscsi 未安装，尝试使用 sysfs 获取映射关系..."
    echo ""
    for dev in /sys/block/sd*; do
        name=$(basename "$dev")
        link=$(readlink -f "$dev/device" 2>/dev/null)
        host=$(echo "$link" | grep -oP 'host\d+' | head -1)
        target=$(echo "$link" | grep -oP '\d+:\d+:\d+:\d+' | head -1)
        model=$(cat "$dev/device/model" 2>/dev/null | xargs)
        printf "%-6s  %-8s  target=%-14s  model=%s\n" "$name" "$host" "$target" "$model"
    done
fi

echo ""
echo "========== 第三步: 每块盘的队列深度与调度器 =========="
echo ""

printf "%-6s  %-8s  %-12s  %-14s  %-10s  %s\n" \
    "DEV" "HOST" "QUEUE_DEPTH" "NR_REQUESTS" "SCHEDULER" "MODEL"
echo "---------------------------------------------------------------------------------"

for dev in /sys/block/sd*; do
    name=$(basename "$dev")
    qdepth=$(cat "$dev/device/queue_depth" 2>/dev/null || echo "N/A")
    nr_req=$(cat "$dev/queue/nr_requests" 2>/dev/null || echo "N/A")
    sched=$(cat "$dev/queue/scheduler" 2>/dev/null || echo "N/A")
    model=$(cat "$dev/device/model" 2>/dev/null | xargs)
    link=$(readlink -f "$dev/device" 2>/dev/null)
    host=$(echo "$link" | grep -oP 'host\d+' | head -1)

    printf "%-6s  %-8s  %-12s  %-14s  %-10s  %s\n" \
        "$name" "$host" "$qdepth" "$nr_req" "$sched" "$model"
done

echo ""
echo "========== 第四步: HBA 控制器 PCI 信息 =========="
echo ""

lspci | grep -i -E "SAS|RAID|HBA|SCSI|storage|mass storage" || echo "[INFO] 未匹配到 SAS/RAID/HBA/SCSI 相关 PCI 设备"

echo ""
echo "========== 补充信息: HBA 驱动模块参数 =========="
echo ""

for host in /sys/class/scsi_host/host*; do
    driver=$(cat "$host/proc_name" 2>/dev/null)
    [ -z "$driver" ] && continue

    mod_dir="/sys/module/$driver/parameters"
    if [ -d "$mod_dir" ]; then
        echo "--- $driver 模块参数 ---"
        for param in "$mod_dir"/*; do
            pname=$(basename "$param")
            pval=$(cat "$param" 2>/dev/null || echo "N/A")
            printf "  %-30s = %s\n" "$pname" "$pval"
        done
        echo ""
        break
    fi
done

echo ""
echo "========== 补充信息: 磁盘数量统计 =========="
echo ""

total_sd=$(ls -d /sys/block/sd* 2>/dev/null | wc -l)
echo "总共检测到 sd 设备: $total_sd 块"
echo ""

for host in /sys/class/scsi_host/host*; do
    h=$(basename "$host")
    count=0
    for dev in /sys/block/sd*; do
        link=$(readlink -f "$dev/device" 2>/dev/null)
        if echo "$link" | grep -q "$h"; then
            count=$((count + 1))
        fi
    done
    if [ "$count" -gt 0 ]; then
        can_queue=$(cat "$host/can_queue" 2>/dev/null || echo "?")
        echo "  $h: $count 块盘  (can_queue=$can_queue, 每盘平均可用队列槽位=$(echo "scale=2; $can_queue / $count" | bc 2>/dev/null || echo '?'))"
    fi
done

echo ""
echo "========================================"
echo " 采集完成"
echo "========================================"
