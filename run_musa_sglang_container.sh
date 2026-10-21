#!/usr/bin/env bash
# 在宿主机上按 sglang-server 的方式启动容器。
# 镜像是 local/ctr-33869d47a065:20261016。
# 宿主机模型目录是 /data1/models，容器内仍是 /data/models。
#
# 在 hlsc-moer-myt01 上执行:
#   bash run_musa_sglang_container.sh
#
# 进入容器后启动服务:
#   bash start_qwen35_397b_sglang_musa.sh Qwen3.5-397B-A17B-Channel-FP8-w8a8

set -u
set -o pipefail

IMAGE="${IMAGE:-local/ctr-33869d47a065:20261016}"
NAME="${NAME:-musa-sglang}"
HOST_MODELS="${HOST_MODELS:-/data1/models}"
CONTAINER_MODELS="${CONTAINER_MODELS:-/data/models}"
WORKDIR="${WORKDIR:-/sgl-workspace/sglang}"

if ! command -v docker >/dev/null 2>&1; then
  echo "未找到 docker。" >&2
  exit 1
fi

if [[ ! -d "$HOST_MODELS" ]]; then
  echo "宿主机模型目录不存在: $HOST_MODELS" >&2
  exit 1
fi

if docker container inspect "$NAME" >/dev/null 2>&1; then
  echo "已有同名容器: $NAME" >&2
  echo "先停止旧容器再启动: docker rm -f $NAME" >&2
  exit 1
fi

echo "IMAGE=$IMAGE"
echo "NAME=$NAME"
echo "挂载: ${HOST_MODELS} -> ${CONTAINER_MODELS}"
echo "WORKDIR=$WORKDIR"

docker run -it \
  --name "$NAME" \
  --shm-size 64g \
  --network=host \
  --privileged \
  --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -u root \
  -v "${HOST_MODELS}:${CONTAINER_MODELS}" \
  -w "$WORKDIR" \
  "$IMAGE" \
  bash
