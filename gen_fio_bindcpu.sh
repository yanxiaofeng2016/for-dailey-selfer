#!/bin/bash
#
# 生成 36 盘绑核 fio 配置文件
# 每块盘绑定一个独立 CPU，确保请求不跨 HW Queue，合并正常
#

IOENGINE="${IOENGINE:-libaio}"
RW_MODE="${RW_MODE:-read}"
BS="${BS:-64K}"
IODEPTH="${IODEPTH:-128}"
RUNTIME="${RUNTIME:-3600}"
CONFIG="${1:-/tmp/fio_36disks_bindcpu.fio}"

cat > "$CONFIG" << EOF
[global]
ioengine=$IOENGINE
randrepeat=0
norandommap
thread
direct=1
runtime=$RUNTIME
time_based
numjobs=1
iodepth=$IODEPTH
rw=$RW_MODE
bs=$BS
EOF

cpu=0
for dev in /dev/sd{b..z} /dev/sda{a..k}; do
    [ -b "$dev" ] || continue
    name=$(basename "$dev")
    cat >> "$CONFIG" << EOF

[$name]
filename=$dev
cpus_allowed=$cpu
EOF
    cpu=$((cpu + 1))
done

echo "已生成 fio 配置文件: $CONFIG"
echo "共配置 $cpu 块盘，每盘绑定独立 CPU 核心"
echo ""
echo "运行命令:"
echo "  fio $CONFIG"
echo ""
echo "如需修改参数，可通过环境变量控制:"
echo "  RW_MODE=randread BS=4K IODEPTH=32 bash $0 $CONFIG"
