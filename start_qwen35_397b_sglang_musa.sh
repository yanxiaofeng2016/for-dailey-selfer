#!/usr/bin/env bash
# 摩尔线程 MTT S5000 上启动 Qwen3.5-397B，服务参数与海光 BW1100 脚本对齐，便于对比。
#
# 在容器里执行:
#   bash start_qwen35_397b_sglang_musa.sh
#
# Docker 启动容器（在宿主机执行，按本机目录改挂载）:
# 不要使用海光的 --device=/dev/kfd、/dev/dri、/dev/mkfd，也不要挂载 /opt/hyhal。
# 摩尔线程用 --privileged 暴露 /dev/musa*。
#
# docker run -it --shm-size 64g --network=host \
#   --name musa-sglang \
#   --privileged \
#   --cap-add=SYS_PTRACE \
#   --security-opt seccomp=unconfined \
#   -u root \
#   -v /data/models:/models:ro \
#   -v /home/lujq:/lujq \
#   -w /lujq \
#   registry.mthreads.com/mcconline/inference/sglang:v0.5.12.post1-ph1-4.3.5-torch2.9.0-20260805 \
#   bash
#
# 与海光脚本相同的服务参数:
#   --tp-size 4 --pp-size 1 --trust-remote-code --dtype bfloat16
#   --port 31216 --attention-backend fa3 --page-size 64
#   --watchdog-timeout 36000 --kv-cache-dtype fp8_e4m3
#   --enable-piecewise-cuda-graph
#   --speculative-algorithm EAGLE --speculative-num-steps 3
#   --speculative-eagle-topk 1 --speculative-num-draft-tokens 4
#   --host 0.0.0.0 --mem-fraction-static 0.85
#   --mamba-scheduler-strategy extra_buffer
#   --tool-call-parser qwen3_coder --reasoning-parser qwen3
#   --chunked-prefill-size -1 --skip-server-warmup
#   --cuda-graph-max-bs 64 --max-running-requests 64
#
# 不能照搬、脚本里已改掉的部分:
#   1. --quantization slimquant_marlin
#      这是海光镜像的量化后端。摩尔线程镜像没有这个选项，传上去会直接退出。
#      海光权重是 Channel-FP8-w8a8；本机已加载成功的是 block FP8
#      （2026-10-14 日志: Detected fp8 checkpoint, quant=fp8）。
#   2. --numa-node 4 5 5 7
#      这是 BW1100 的 NUMA 拓扑。填错会绑到错误的 CPU。默认不传，按本机 numactl -H 填。
#   3. HIP_*、HSA_*、ROC_*、USE_DCU_*、SGLANG_USE_LIGHTOP、SGLANG_USE_AITER_LINEAR_ATTN、
#      SGLANG_KV_LAYOUT_DCU_FA、SGLANG_USE_FP8_W8A8_MOE、NCCL_MIN/MAX_NCHANNELS
#      这些只作用于海光 DCU 或那台机器的通信调优，不带进摩尔线程进程。
#   4. --linear-attn-backend flashinfer
#      对应海光的 SGLANG_USE_AITER_LINEAR_ATTN=1。Qwen3.5 有 GDN 线性注意力，
#      摩尔线程上要用 FlashInfer，否则混合注意力起不来。这是后端替换，不是额外加速开关。
#
# 显存（对比前先看）:
#   海光 BW1100 单卡 144 GiB，TP=4 时每卡权重大约 95 GiB，放得下。
#   MTT S5000 单卡 80 GiB，PyTorch 可见约 76 GiB。本机 2026-10-14 TP=8 实测每卡权重 47.26 GiB，
#   8 卡合计约 378 GiB。TP=4 时每卡约 95 GiB，超过 76 GiB，加载权重就会 OOM。
#   要让这组参数在摩尔线程上真能跑，并且和海光仍是同一组服务参数:
#   两边都改成 TP=8（本机 MTHREADS_VISIBLE_DEVICES=0,1,2,3,4,5,6,7）。
#   只改摩尔线程、海光仍用 4 卡时，吞吐不能直接比。
#   确认仍要用当前 TP 启动（例如以后换成更大显存的卡）: ALLOW_OVERSIZE=1 bash 本脚本。

set -u
set -o pipefail

# 按实际使用的 GPU 编号修改。个数必须等于 TP_SIZE。
export MTHREADS_VISIBLE_DEVICES="${MTHREADS_VISIBLE_DEVICES:-4,5,6,7}"
TP_SIZE="${TP_SIZE:-4}"

# 单机不要用 bond0。容器若继承了多机环境变量，Gloo 会报 Unable to find address for: bond0。
if [[ -z "${GLOO_SOCKET_IFNAME:-}" || "${GLOO_SOCKET_IFNAME}" == "bond0" ]]; then
  export GLOO_SOCKET_IFNAME=lo
fi
if [[ -z "${TP_SOCKET_IFNAME:-}" || "${TP_SOCKET_IFNAME}" == "bond0" ]]; then
  export TP_SOCKET_IFNAME=lo
fi

# 与海光脚本相同的 SGLang 行为开关。
export SGLANG_ENABLE_SPEC_V2="${SGLANG_ENABLE_SPEC_V2:-1}"
export SGL_CHUNKED_PREFIX_CACHE_THRESHOLD="${SGL_CHUNKED_PREFIX_CACHE_THRESHOLD:-0}"
export GLIBC_TUNABLES="${GLIBC_TUNABLES:-glibc.rtld.optional_static_tls=0x40000}"

# 清掉海光脚本里的 DCU 变量，避免同一个 shell 里残留后影响本次进程。
unset HIP_VISIBLE_DEVICES HSA_ENABLE_COREDUMP USE_DCU_CUSTOM_ALLREDUCE \
  ALLREDUCE_STREAM_WITH_COMPUTE HIP_KERNEL_EVENT_SYSTENFENCE HIP_KERNEL_BATCH_CEILING \
  GPU_FORCE_BLIT_COPY_SIZE HSA_KERNARG_POOL_SIZE ROC_AQL_QUEUE_SIZE \
  SGLANG_USE_LIGHTOP SGLANG_USE_FUSED_TOPK_SOFTMAX SGLANG_USE_CAUSAL_CONV1D \
  SGLANG_KV_LAYOUT_DCU_FA SGLANG_USE_AITER_LINEAR_ATTN SGLANG_USE_FP8_W8A8_MOE \
  NCCL_MIN_NCHANNELS NCCL_MAX_NCHANNELS || true

# 按本机目录修改。容器内路径，对应上面 docker -v 的挂载。
MODEL_PATH="${MODEL_PATH:-/models/Qwen3.5-397B-A17B-FP8}"
PORT="${PORT:-31216}"
WORK_DIR="${WORK_DIR:-/lujq}"
LOG_DIR="${LOG_DIR:-$WORK_DIR/log/Qwen3.5-397B-A17B-FP8-musa}"
export SGLANG_TORCH_PROFILER_DIR="${SGLANG_TORCH_PROFILER_DIR:-$WORK_DIR/profile}"

# 海光是 --numa-node 4 5 5 7。这里默认留空。
# 查看本机: numactl -H
# 个数必须等于 TP_SIZE。例: NUMA_NODES="0 0 1 1"
NUMA_NODES="${NUMA_NODES:-}"

# 本机 TP=8 实测权重合计，用来判断当前 TP 放不放得下。
WEIGHT_TOTAL_GIB="${WEIGHT_TOTAL_GIB:-378.08}"
ALLOW_OVERSIZE="${ALLOW_OVERSIZE:-0}"

mkdir -p "$LOG_DIR" "$SGLANG_TORCH_PROFILER_DIR"
SERVER_LOG="$LOG_DIR/server_$(date +%Y%m%d_%H%M%S).log"

gpu_count=$(awk -F',' '{print NF}' <<<"$MTHREADS_VISIBLE_DEVICES")
if [[ "$gpu_count" -ne "$TP_SIZE" ]]; then
  echo "MTHREADS_VISIBLE_DEVICES=$MTHREADS_VISIBLE_DEVICES 共 ${gpu_count} 张卡，TP_SIZE=$TP_SIZE。两者必须相同。" | tee -a "$SERVER_LOG"
  exit 1
fi

if [[ ! -d "$MODEL_PATH" ]]; then
  echo "模型目录不存在: $MODEL_PATH" | tee -a "$SERVER_LOG"
  echo "宿主机 /data/models 挂到容器 /models 后，目录应是 /models/Qwen3.5-397B-A17B-FP8。" | tee -a "$SERVER_LOG"
  exit 1
fi

# 优先读 mthreads-gmi 的总显存；读不到时用本机实测的 76 GiB。
usable_gib="76.13"
if command -v mthreads-gmi >/dev/null 2>&1; then
  total_mib=$(mthreads-gmi 2>/dev/null | grep -oE '[0-9]+MiB / [0-9]+MiB' | awk -F'/' '{gsub(/[^0-9]/,"",$2); print $2}' | sort -n | head -1 || true)
  if [[ -n "${total_mib:-}" ]]; then
    usable_gib=$(awk -v mib="$total_mib" 'BEGIN { printf "%.2f", mib / 1024 * 0.9516 }')
  fi
fi
need_gib=$(awk -v total="$WEIGHT_TOTAL_GIB" -v tp="$TP_SIZE" 'BEGIN { printf "%.2f", total / tp }')
oversize=$(awk -v need="$need_gib" -v usable="$usable_gib" 'BEGIN { print (need > usable) ? 1 : 0 }')

{
  echo "========================================"
  echo "SERVER_START: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "SGLANG_VERSION: $(python3 -c 'import sglang; print(sglang.__version__)' 2>/dev/null || echo unknown)"
  echo "MTHREADS_VISIBLE_DEVICES=$MTHREADS_VISIBLE_DEVICES"
  echo "TP_SIZE=$TP_SIZE"
  echo "MODEL_PATH=$MODEL_PATH"
  echo "估计每卡权重=${need_gib} GiB，单卡可用约=${usable_gib} GiB"
  echo "GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-} TP_SOCKET_IFNAME=${TP_SOCKET_IFNAME:-}"
  echo "SGLANG_ENABLE_SPEC_V2=${SGLANG_ENABLE_SPEC_V2:-}"
  echo "未使用 --quantization slimquant_marlin（摩尔线程镜像没有该后端）"
  echo "========================================"
  if command -v mthreads-gmi >/dev/null 2>&1; then
    mthreads-gmi || true
  else
    echo "未找到 mthreads-gmi"
  fi
  echo "========================================"
} | tee -a "$SERVER_LOG"

if [[ "$oversize" == "1" && "$ALLOW_OVERSIZE" != "1" ]]; then
  {
    echo "已停止。TP=$TP_SIZE 时每卡权重大约 ${need_gib} GiB，单卡可用大约 ${usable_gib} GiB，权重装不下。"
    echo "海光 BW1100 单卡 144 GiB，所以同一组 TP=4 在海光上可以启动。"
    echo "摩尔线程这台 8 卡要跑同一组其余参数，请两边都改为:"
    echo "  TP_SIZE=8 MTHREADS_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 bash $0"
    echo "海光侧同时把 --tp-size 改成 8，并把 HIP_VISIBLE_DEVICES 改成 8 张卡。"
    echo "只在摩尔线程改成 8 卡、海光仍是 4 卡时，不要把两边的吞吐直接比较。"
  } | tee -a "$SERVER_LOG"
  exit 1
fi

cmd=(
  sglang serve
  --tp-size "$TP_SIZE"
  --pp-size 1
  --trust-remote-code
  --dtype bfloat16
  --port "$PORT"
  --attention-backend fa3
  --page-size 64
  --watchdog-timeout 36000
  --kv-cache-dtype fp8_e4m3
  --enable-piecewise-cuda-graph
  --speculative-algorithm EAGLE
  --speculative-num-steps 3
  --speculative-eagle-topk 1
  --speculative-num-draft-tokens 4
  --model-path "$MODEL_PATH"
  --host 0.0.0.0
  --mem-fraction-static 0.85
  --mamba-scheduler-strategy extra_buffer
  --tool-call-parser qwen3_coder
  --reasoning-parser qwen3
  --chunked-prefill-size -1
  --skip-server-warmup
  --cuda-graph-max-bs 64
  --max-running-requests 64
  --linear-attn-backend flashinfer
)

if [[ -n "$NUMA_NODES" ]]; then
  # shellcheck disable=SC2206
  numa_args=(--numa-node $NUMA_NODES)
  numa_count=$((${#numa_args[@]} - 1))
  if [[ "$numa_count" -ne "$TP_SIZE" ]]; then
    echo "NUMA_NODES 有 ${numa_count} 个节点，TP_SIZE=$TP_SIZE。个数必须相同。" | tee -a "$SERVER_LOG"
    exit 1
  fi
  cmd+=("${numa_args[@]}")
fi

{
  echo "COMMAND:"
  printf ' %q' "${cmd[@]}"
  echo
  echo "若 EAGLE 报缺少 draft model: Qwen3.5 自带 MTP，把 --speculative-algorithm EAGLE 改成 NEXTN，3/1/4 三个数字不要改。改名后两边不再是同一条投机路径，对比时要注明。"
  echo "piecewise CUDA graph 若捕获失败，是当前 SGLang-MUSA 对这种分段图的支持问题，服务日志里会有报错。对比时记录是否去掉了 --enable-piecewise-cuda-graph。"
  echo "dmesg 里的 submission response INVALID 是 mtgpu 驱动拒绝了已提交的 GPU 命令。上次出现在 3.3.5 驱动回放 CUDA Graph 时，换到 5.2.0-server 后普通 CUDA Graph 已能用。当前这台机器若再出现，把 dmesg 里的 cmd 和 Command Graph 行保留下来。"
  echo "若 --kv-cache-dtype fp8_e4m3 报不支持: 去掉该参数会退回 bf16 KV，和海光不再同配，对比时要注明。"
  echo "========================================"
} | tee -a "$SERVER_LOG"

"${cmd[@]}" 2>&1 | tee -a "$SERVER_LOG"
SGLANG_EXIT_CODE=${PIPESTATUS[0]}

{
  echo "========================================"
  echo "SERVER_END: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "SGLANG_EXIT_CODE: $SGLANG_EXIT_CODE"
  echo "========================================"
} | tee -a "$SERVER_LOG"

exit "$SGLANG_EXIT_CODE"
