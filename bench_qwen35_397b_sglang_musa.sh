#!/usr/bin/env bash
# 摩尔线程容器内，对 start_qwen35_397b_sglang_musa.sh 拉起的服务做压测。
# 输入长度、并发、输出长度、重复次数与海光脚本一致。
#
# 在已经启动服务的同一个容器里另开一个终端执行。模型参数与启动脚本相同，日志写到同一目录。
#   bash bench_qwen35_397b_sglang_musa.sh Qwen3.5-397B-A17B-Channel-FP8-w8a8
#   bash bench_qwen35_397b_sglang_musa.sh /data/models/Qwen3.5-397B-A17B-FP8
#
# 服务地址是启动脚本的 --host 0.0.0.0 --port 31216。
# --backend sglang 走原生 /generate，不使用海光权重名。
# dataset-name=random 读取 /data/models/ShareGPT_V3_unfiltered_cleaned_split.json。
# 这份文件已在容器内。路径无效时不再访问 Hugging Face，改用 random-ids。

set -u
set -o pipefail

MODELS_DIR="${MODELS_DIR:-/data/models}"

usage() {
  cat <<EOF
用法: bash $0 <模型目录或模型名>

模型名不含路径时，在 ${MODELS_DIR} 下查找。
日志默认写到 \$WORK_DIR/log/<模型名>-musa/bench_*.log，与启动脚本相同。
--backend sglang 走 /generate，模型名写入日志，不发给服务。

示例:
  bash $0 Qwen3.5-397B-A17B-Channel-FP8-w8a8
  bash $0 /data/models/Qwen3.5-397B-A17B-FP8
EOF
}

MODEL_ARG=""
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --model)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        usage >&2
        exit 1
      fi
      MODEL_ARG="$2"
      shift 2
      ;;
    --model=*)
      MODEL_ARG="${1#--model=}"
      shift
      ;;
    -*)
      echo "未知参数: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      MODEL_ARG="$1"
      shift
      ;;
  esac
fi
if [[ $# -gt 0 ]]; then
  echo "多余参数: $*" >&2
  usage >&2
  exit 1
fi

if [[ -n "$MODEL_ARG" ]]; then
  if [[ "$MODEL_ARG" == /* || "$MODEL_ARG" == */* || -d "$MODEL_ARG" ]]; then
    MODEL_PATH="$MODEL_ARG"
  else
    MODEL_PATH="${MODELS_DIR%/}/$MODEL_ARG"
  fi
elif [[ -n "${MODEL_PATH:-}" ]]; then
  :
elif [[ -n "${MODEL_NAME:-}" ]]; then
  MODEL_PATH="${MODELS_DIR%/}/$MODEL_NAME"
else
  usage >&2
  exit 1
fi

MODEL_NAME="$(basename "${MODEL_PATH%/}")"
if [[ ! -d "$MODEL_PATH" ]]; then
  echo "模型目录不存在: $MODEL_PATH" >&2
  echo "传入 ${MODELS_DIR} 下的目录名，或完整路径。参数与启动脚本相同。" >&2
  exit 1
fi

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-31216}"

INPUT_LENGTHS=(1024 4096 32768 131072)
CONCURRENCIES=(1 2 4 8 16 32 64 128)
OUTPUT_LEN=512
REQUEST_MULTIPLIER=4
REPEAT_COUNT=3
WARMUP_REQUESTS=1

DATASET_PATH="${DATASET_PATH:-/data/models/ShareGPT_V3_unfiltered_cleaned_split.json}"
# 有本地 ShareGPT 时与海光的 random 相同。没有则不要下载，改用 random-ids。
if [[ -z "${DATASET_NAME:-}" ]]; then
  if [[ -s "$DATASET_PATH" ]]; then
    DATASET_NAME=random
  else
    DATASET_NAME=random-ids
  fi
fi
if [[ "$DATASET_NAME" == "random" && ! -s "$DATASET_PATH" ]]; then
  echo "DATASET_NAME=random 需要本地文件: $DATASET_PATH"
  exit 1
fi

if [[ -z "${WORK_DIR:-}" ]]; then
  if [[ -d /lujq ]]; then
    WORK_DIR=/lujq
  else
    WORK_DIR=/sgl-workspace/sglang
  fi
fi
LOG_DIR="${LOG_DIR:-$WORK_DIR/log/${MODEL_NAME}-musa}"
mkdir -p "$LOG_DIR"
BENCH_LOG="$LOG_DIR/bench_$(date +%Y%m%d_%H%M%S).log"

if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  echo "未找到 python3 或 python，无法运行 sglang.bench_serving。" | tee -a "$BENCH_LOG"
  exit 1
fi

FAIL_COUNT=0

{
  echo "========================================"
  echo "BENCH_START: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "SGLANG_VERSION: $("$PYTHON" -c 'import sglang; print(sglang.__version__)' 2>/dev/null || echo unknown)"
  echo "MODEL_NAME: $MODEL_NAME"
  echo "MODEL_PATH: $MODEL_PATH"
  echo "LOG_DIR: $LOG_DIR"
  echo "HOST: $HOST"
  echo "PORT: $PORT"
  echo "DATASET_NAME: $DATASET_NAME"
  echo "DATASET_PATH: $DATASET_PATH"
  if [[ "$DATASET_NAME" == "random-ids" ]]; then
    echo "本地没有 ShareGPT json，使用 random-ids，不访问外网。输入来自词表随机 token，和海光 random 使用的 ShareGPT 文本不同。"
  fi
  echo "INPUT_LENGTHS: ${INPUT_LENGTHS[*]}"
  echo "CONCURRENCIES: ${CONCURRENCIES[*]}"
  echo "OUTPUT_LEN: $OUTPUT_LEN"
  echo "REQUEST_MULTIPLIER: $REQUEST_MULTIPLIER"
  echo "REPEAT_COUNT: $REPEAT_COUNT"
  echo "WARMUP_REQUESTS: $WARMUP_REQUESTS"
  echo "启动脚本的 --max-running-requests 是 64。并发 128 时多出的请求在队列里等待，和海光脚本的矩阵相同。"
  echo "若服务日志里的 max_prefill_tokens 小于 32768 或 131072，这两档输入会被拒绝。需要重启服务并加上足够大的 --max-prefill-tokens。"
  echo "========================================"
  if command -v mthreads-gmi >/dev/null 2>&1; then
    mthreads-gmi || true
  else
    echo "未找到 mthreads-gmi"
  fi
  echo "========================================"
} | tee -a "$BENCH_LOG"

if ! "$PYTHON" -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=5).read()' "http://${HOST}:${PORT}/health" >/dev/null 2>&1; then
  echo "服务未就绪: http://${HOST}:${PORT}/health 。先在容器里跑启动脚本，确认端口 ${PORT}。" | tee -a "$BENCH_LOG"
  exit 1
fi

for INPUT_LEN in "${INPUT_LENGTHS[@]}"; do
  for CONCURRENCY in "${CONCURRENCIES[@]}"; do
    NUM_PROMPTS=$((CONCURRENCY * REQUEST_MULTIPLIER))

    for ((REPEAT = 1; REPEAT <= REPEAT_COUNT; REPEAT++)); do
      {
        echo "========================================"
        echo "TEST_START: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "INPUT_LEN: $INPUT_LEN"
        echo "OUTPUT_LEN: $OUTPUT_LEN"
        echo "MAX_CONCURRENCY: $CONCURRENCY"
        echo "NUM_PROMPTS: $NUM_PROMPTS"
        echo "REPEAT: $REPEAT/$REPEAT_COUNT"
        echo "========================================"
      } | tee -a "$BENCH_LOG"

      "$PYTHON" -m sglang.bench_serving \
        --backend sglang \
        --host "$HOST" \
        --port "$PORT" \
        --dataset-name "$DATASET_NAME" \
        --dataset-path "$DATASET_PATH" \
        --num-prompts "$NUM_PROMPTS" \
        --max-concurrency "$CONCURRENCY" \
        --random-input-len "$INPUT_LEN" \
        --random-output-len "$OUTPUT_LEN" \
        --random-range-ratio 1.0 \
        --warmup-requests "$WARMUP_REQUESTS" \
        --flush-cache \
        2>&1 | tee -a "$BENCH_LOG"

      BENCH_EXIT_CODE=${PIPESTATUS[0]}
      if [[ "$BENCH_EXIT_CODE" -ne 0 ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi

      {
        echo "========================================"
        echo "TEST_END: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "BENCH_EXIT_CODE: $BENCH_EXIT_CODE"
        echo "========================================"
      } | tee -a "$BENCH_LOG"
    done
  done
done

{
  echo "========================================"
  echo "BENCH_END: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "BENCH_LOG: $BENCH_LOG"
  echo "FAIL_COUNT: $FAIL_COUNT"
  echo "========================================"
} | tee -a "$BENCH_LOG"

exit "$FAIL_COUNT"
