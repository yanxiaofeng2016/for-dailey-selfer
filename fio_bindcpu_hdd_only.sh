#!/bin/bash
#
# FIO 绑核测试脚本 —— 仅对机械盘 (HDD) 执行
# 通过 rotational 标志自动识别机械盘，跳过 SSD/NVMe
#

IOENGINE="${IOENGINE:-libaio}"
RW_MODE="${RW_MODE:-read}"
BS="${BS:-64K}"
IODEPTH="${IODEPTH:-128}"
RUNTIME="${RUNTIME:-60}"

cpu=0
hdd_count=0
skipped=""

for dev in /sys/block/sd*; do
    name=$(basename "$dev")
    devpath="/dev/$name"

    [ -b "$devpath" ] || continue

    rotational=$(cat "$dev/queue/rotational" 2>/dev/null)
    if [ "$rotational" != "1" ]; then
        model=$(cat "$dev/device/model" 2>/dev/null | xargs)
        skipped="$skipped  $name ($model) - 非机械盘, 跳过\n"
        continue
    fi

    model=$(cat "$dev/device/model" 2>/dev/null | xargs)
    echo "[CPU $cpu] $devpath ($model)"

    taskset -c $cpu fio --ioengine=$IOENGINE \
        --randrepeat=0 --norandommap --thread --direct=1 \
        --group_reporting --name="test_$name" \
        --runtime=$RUNTIME --time_based \
        --numjobs=1 --iodepth=$IODEPTH \
        --filename=$devpath --rw=$RW_MODE --bs=$BS &

    cpu=$((cpu + 1))
    hdd_count=$((hdd_count + 1))
done

if [ -n "$skipped" ]; then
    echo ""
    echo "跳过的非机械盘:"
    echo -e "$skipped"
fi

echo "共启动 $hdd_count 块机械盘测试, 等待完成..."
echo ""
wait
echo "全部测试完成"
