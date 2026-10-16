# 摩尔线程 MTT S5000 运行 Qwen3.5-397B：启动与压测手册

适用环境：8 张 MTT S5000 的服务器 `hlsc-moer-myt01`，容器 `sglang-service`，镜像 SGLang v0.5.12.post1（MUSA）。
服务参数与海光 BW1100 脚本保持一致，便于两边比较性能。

## 1. 文件一览

| 文件 | 在哪里执行 | 作用 |
| --- | --- | --- |
| `mount_models_into_container.sh` | 宿主机 | 给运行中的容器动态挂载模型目录 |
| `run_musa_sglang_container.sh` | 宿主机 | 新建容器时一次性挂载模型目录并启动 |
| `start_qwen35_397b_sglang_musa.sh` | 容器内 | 启动 SGLang 服务，模型作为第一个参数 |
| `bench_qwen35_397b_sglang_musa.sh` | 容器内 | 对已启动的服务做性能压测，模型参数与启动脚本相同 |

脚本完整内容见第 6 章。

## 2. 目录约定

| 位置 | 路径 |
| --- | --- |
| 宿主机模型目录 | `/data1/models` |
| 容器内模型目录 | `/data/models`（容器内路径固定不变） |
| 数据集 | `/data/models/ShareGPT_V3_unfiltered_cleaned_split.json` |
| 工作目录 | `/sgl-workspace/sglang`（容器内存在 `/lujq` 时用 `/lujq`） |
| 服务与压测日志 | `$WORK_DIR/log/<模型名>-musa/server_*.log`、`bench_*.log` |

日志按模型名分目录。Channel-FP8 与 block FP8 的日志不会写到一起。

## 3. 启动步骤

### 3.1 确认模型目录已进入容器

宿主机上执行：

```bash
docker exec sglang-service ls /data/models
```

能列出 `Qwen3.5-397B-A17B-Channel-FP8-w8a8` 等目录就跳到 3.3。列不出来，或目录为空，做 3.2。

### 3.2 给运行中的容器动态挂载模型目录

Docker 没有给运行中的容器追加挂载的命令。`mount_models_into_container.sh` 用宿主机权限完成这件事，不重启容器，不影响容器里已经运行的进程。

```bash
bash mount_models_into_container.sh
```

默认参数是容器 `sglang-service`，把宿主机 `/data1/models` 挂到容器 `/data/models`。其他情况：

```bash
bash mount_models_into_container.sh <容器名> <宿主机目录> <容器内目录>
```

成功时输出类似：

```
mounted /data1/models -> /data/models
TARGET       SOURCE                  FSTYPE OPTIONS
/data/models /dev/nvme0n1p1[/models] ext4   rw,relatime
```

注意：

- 挂载只在容器本次运行期间有效。容器重启后要再执行一次。
- 要长期生效，用 `run_musa_sglang_container.sh` 新建容器，它带 `-v /data1/models:/data/models`。
- 挂载之后再启动 SGLang。之前已经打开旧目录的进程看不到新内容。

### 3.3 启动前检查

进入容器：

```bash
docker exec -it sglang-service bash
```

确认没有旧服务占着端口和显卡：

```bash
ss -lntp | grep 31216
ps -ef | grep sglang | grep -v grep
mthreads-gmi
```

有旧的 `sglang serve` 进程就先停掉，再继续。

### 3.4 启动服务

容器内执行，模型名作为第一个参数：

```bash
cd /sgl-workspace/sglang
bash start_qwen35_397b_sglang_musa.sh Qwen3.5-397B-A17B-Channel-FP8-w8a8
```

模型名不含路径时，在 `/data/models` 下查找。也可以传完整路径：

```bash
bash start_qwen35_397b_sglang_musa.sh /data/models/Qwen3.5-397B-A17B-FP8
```

脚本默认使用全部可见的 8 张卡，`TP_SIZE` 跟卡数走。可用环境变量调整：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MTHREADS_VISIBLE_DEVICES` | `0,1,2,3,4,5,6,7` | 可见显卡 |
| `TP_SIZE` | 可见卡数 | 必须与可见卡数相同 |
| `PORT` | `31216` | 服务端口 |
| `MODELS_DIR` | `/data/models` | 模型名的查找目录 |
| `SERVED_MODEL_NAME` | 模型目录名 | 服务对外的模型名 |
| `NUMA_NODES` | 空 | 绑核，个数必须等于 `TP_SIZE` |
| `ALLOW_OVERSIZE` | `0` | 设为 `1` 时跳过显存估算检查 |

### 3.5 确认服务就绪

启动需要编译 CUDA Graph 并做 MoE 调优，耗时较长。看到下面这行才算就绪：

```
The server is fired up and ready to roll!
```

另开一个终端检查：

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:31216/health
```

返回 `200` 才能压测。

## 4. 性能压测步骤

服务就绪后，在同一个容器里另开终端：

```bash
docker exec -it sglang-service bash
cd /sgl-workspace/sglang
bash bench_qwen35_397b_sglang_musa.sh Qwen3.5-397B-A17B-Channel-FP8-w8a8
```

模型参数必须与启动脚本一致，日志会写到同一个目录。

压测矩阵与海光脚本相同：

| 项 | 取值 |
| --- | --- |
| 输入长度 | 1024、4096、32768、131072 |
| 并发 | 1、2、4、8、16、32、64、128 |
| 输出长度 | 512 |
| 请求数 | 并发 × 4 |
| 重复次数 | 每组 3 次 |
| 预热请求 | 1 |
| 其他 | `--flush-cache`，`--backend sglang`，`--random-range-ratio 1.0` |

数据集策略：

- 默认读取 `/data/models/ShareGPT_V3_unfiltered_cleaned_split.json`，使用 `--dataset-name random`，与海光相同，不访问外网。
- 文件不存在时自动改为 `random-ids`，输入来自词表随机 token，和海光使用的 ShareGPT 文本不同，对比时要注明。

压测完成后检查：

```bash
tail -n 6 /sgl-workspace/sglang/log/Qwen3.5-397B-A17B-Channel-FP8-w8a8-musa/bench_*.log
```

`FAIL_COUNT: 0` 表示全部组合成功。脚本退出码就是失败次数。

## 5. 问题处理

### 5.1 启动阶段

**`MTHREADS_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 共 8 张卡，TP_SIZE=4。两者必须相同。`**

- 原因：容器里已 `export` 了 8 张卡，而脚本固定了 `TP_SIZE=4`。
- 处理：脚本已改为未指定 `TP_SIZE` 时跟可见卡数走。需要手动指定时，保证两个值相等。

**TP=4 时加载权重就 OOM，或脚本提示“权重装不下”**

- 原因：Qwen3.5-397B 的权重约 378 GiB。MTT S5000 单卡 80 GiB，PyTorch 可见约 76 GiB。TP=8 时每卡约 47 GiB，TP=4 时约 95 GiB，超出单卡显存。海光 BW1100 单卡 144 GiB，所以 TP=4 能跑。
- 处理：使用 TP=8。脚本会按模型目录大小估算每卡权重，放不下时直接停止。确认显存足够时可用 `ALLOW_OVERSIZE=1` 跳过。
- 对比提示：两边 TP 不同时，吞吐不能直接比较。海光侧要同步改成 TP=8。

**`Unable to find address for: bond0`（Gloo 报错）**

- 原因：容器继承了多机环境变量，`GLOO_SOCKET_IFNAME` 或 `TP_SOCKET_IFNAME` 指向了不存在的网卡。
- 处理：脚本在这两个变量为空或为 `bond0` 时，自动设为 `lo`。

**`--quantization slimquant_marlin` 报参数不识别并退出**

- 原因：`slimquant_marlin` 是海光镜像的量化后端，摩尔线程镜像没有。
- 处理：脚本不传该参数，由镜像按 checkpoint 的 `quantization_config` 识别 FP8。
- 加载 Channel-FP8 权重时，日志出现 `Detected fp8 checkpoint` 可以继续压测。报量化方法不支持或 scale 形状错误，说明这份权重需要海光的 `slimquant_marlin`，当前镜像加载不了，改用 block FP8 权重 `Qwen3.5-397B-A17B-FP8`。

**海光脚本里的 DCU 环境变量带不过来**

- 原因：`HIP_*`、`HSA_*`、`ROC_*`、`USE_DCU_*`、`SGLANG_USE_LIGHTOP`、`SGLANG_USE_AITER_LINEAR_ATTN`、`SGLANG_KV_LAYOUT_DCU_FA`、`SGLANG_USE_FP8_W8A8_MOE`、`NCCL_MIN/MAX_NCHANNELS` 只作用于海光 DCU 或那台机器的通信调优。
- 处理：脚本启动前统一 `unset`，避免同一个 shell 里的残留变量影响本次进程。
- `--numa-node 4 5 5 7` 是 BW1100 的拓扑，默认不传。需要时先看 `numactl -H`，再设置 `NUMA_NODES`，个数等于 `TP_SIZE`。

**`--enable-piecewise-cuda-graph` 和日志里的 `Disable piecewise CUDA graph because --disable-piecewise-cuda-graph is set`**

- 原因：SGLang v0.5.12 中 `--enable-piecewise-cuda-graph` 已废弃，传了也不生效。Qwen3.5 的结构是 `Qwen3_5MoeForConditionalGeneration`，被归为多模态模型，启动时自动关闭 piecewise CUDA Graph。日志里那句话是版本自带的提示，不表示命令行写了 disable。
- 处理：脚本不再传 `--enable-piecewise-cuda-graph`。要跳过自动关闭，参数是 `--enforce-piecewise-cuda-graph`。强制打开前，先确认海光日志是不是也是同一句话。

**`--linear-attn-backend` 相关启动失败**

- 原因：Qwen3.5 含 GDN 线性注意力层，摩尔线程需要 FlashInfer 作为线性注意力后端，对应海光的 `SGLANG_USE_AITER_LINEAR_ATTN=1`。
- 处理：脚本已加 `--linear-attn-backend flashinfer`。

**EAGLE 报缺少 draft model**

- 处理：Qwen3.5 自带 MTP，把 `--speculative-algorithm EAGLE` 改成 `NEXTN`，`3 / 1 / 4` 三个数字不要改。改名后两边不再是同一条投机路径，对比时要注明。

**`--kv-cache-dtype fp8_e4m3` 报不支持**

- 处理：去掉该参数会退回 bf16 KV，与海光不再同配，对比时要注明。

**`dmesg` 出现 `submission response INVALID`，或 CUDA Graph 捕获失败**

- 原因：mtgpu 驱动拒绝了已提交的 GPU 命令。曾出现在 3.3.5 驱动回放 CUDA Graph 时，换到 5.2.0-server 驱动后普通 CUDA Graph 已能使用。
- 处理：先确认驱动版本。再次出现时，保留 `dmesg` 里的 `cmd` 和 `Command Graph` 行，反馈给摩尔线程。

### 5.2 压测阶段

**`服务未就绪: http://127.0.0.1:31216/health`**

- 原因：服务还在编译 CUDA Graph、调优 MoE，或端口不对。
- 处理：等服务日志出现 `The server is fired up and ready to roll!`，再用 `curl` 确认 `/health` 返回 `200`。仍然不通时检查 `ss -lntp | grep 31216` 和 `PORT` 是否一致。

**`[Errno 99] Cannot assign requested address`（下载 ShareGPT）**

- 原因：`sglang.bench_serving` 默认从 Hugging Face 下载 ShareGPT，容器没有外网。
- 处理：脚本改读本地 `/data/models/ShareGPT_V3_unfiltered_cleaned_split.json`。文件不存在时自动用 `random-ids`，不会访问外网。
- 需要在有外网的机器上准备数据集时，下载后放到 `/data1/models/` 下即可，容器内路径是 `/data/models/`。

**输入 32768、131072 的组合被拒绝**

- 原因：服务日志里的 `max_prefill_tokens` 小于输入长度。
- 处理：重启服务并加上足够大的 `--max-prefill-tokens`，同时确认海光侧是同一个值。

**并发 128 时请求排队**

- 说明：启动脚本是 `--max-running-requests 64`，并发 128 时多出的请求在队列里等待。海光脚本的矩阵相同，属于预期行为。

### 5.3 动态挂载模型目录

**容器里 `/data/models` 为空，或找不到新模型**

- 原因：创建容器时挂载的是 `/data/mtt/models`。该宿主机目录已经删除，容器里的 `/data/models` 仍挂着这个失效目录，`findmnt` 显示 `/dev/sda2[/data/mtt/models//deleted]`。
- 处理：执行 `bash mount_models_into_container.sh`。

**Docker 能不能给运行中的容器追加挂载？**

- 结论：不能。`docker run -v` 只在创建容器时生效，`docker update` 也不支持挂载。
- 处理：长期使用就重新创建容器，加 `-v /data1/models:/data/models`。只想临时使用，用 `mount_models_into_container.sh`，容器重启后失效。

**`mount --bind` 报 `wrong fs type, bad option, bad superblock`**

- 原因：`nsenter -m` 进入容器的挂载空间后，宿主机目录和容器目录不在同一棵挂载树上，`/proc/<pid>/root` 只是视图，不能作为 `--bind` 的目标。
- 处理：不要用 `mount --bind` 直接挂。脚本改用 `open_tree` 在宿主机克隆一份独立挂载，再 `setns` 进容器，用 `move_mount` 挂到目标路径。

**`docker exec ... umount` 报 `must be superuser to unmount`**

- 原因：`docker exec` 进入容器的 root 没有卸载权限。
- 处理：在宿主机上用 `nsenter` 卸载，脚本已处理。

**`umount failed: No such file or directory` 和 `findmnt: can't read /proc/mounts`**

- 原因：`nsenter -m` 只进入挂载空间，没有进入 PID 空间，容器里的 `/proc/self` 对宿主机进程不可见。
- 处理：加 `-p`，用 `nsenter -t <pid> -m -p`。脚本已处理。

**`move_mount` 报 `FileNotFoundError: [Errno 2]`**

- 原因：目标 `/data/models` 上挂着已删除的旧目录，内核不允许再往上挂。
- 处理：先 `umount -l` 卸掉失效挂载，再 `mkdir -p` 重新建目录，然后 `move_mount`。脚本会循环卸载，直到该路径上没有挂载。

**挂载成功但服务读不到模型**

- 原因：服务进程在挂载之前就启动，仍看着旧目录。
- 处理：挂载完成之后再启动 SGLang。已经启动的服务需要重启。

## 6. 脚本内容

以下内容与仓库中的脚本一致。

### mount_models_into_container.sh

```bash
#!/usr/bin/env bash
# 在宿主机上，把宿主机目录挂载进正在运行的容器，不需要重建容器。
# 默认把宿主机 /data1/models 挂到容器 sglang-service 的 /data/models。
#
#   bash mount_models_into_container.sh
#   bash mount_models_into_container.sh <容器名> <宿主机目录> <容器内目录>
#
# 挂载只在容器本次运行期间有效。容器重启后要再执行一次。
# 容器内目标路径若挂着已经删除的旧目录（findmnt 显示 //deleted），本脚本会先卸掉。

set -u

name="${1:-${CONTAINER:-sglang-service}}"
src="${2:-${HOST_MODELS:-/data1/models}}"
dst="${3:-${CONTAINER_MODELS:-/data/models}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "需要 root 权限，请用 root 或 sudo 执行。" >&2
  exit 1
fi
for cmd in docker nsenter python3 findmnt; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "宿主机缺少命令: $cmd" >&2
    exit 1
  fi
done

pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null)
if [[ -z "$pid" || "$pid" == "0" ]]; then
  echo "容器未运行: $name" >&2
  exit 1
fi
if [[ ! -d "$src" ]]; then
  echo "宿主机目录不存在: $src" >&2
  exit 1
fi

# 同时进入容器的挂载空间和 PID 空间。只进挂载空间时，容器内的 /proc 不可见，
# umount 和 findmnt 会报 No such file or directory。
in_ctr() { nsenter -t "$pid" -m -p -- "$@"; }

echo "容器=$name PID=$pid"
echo "挂载: $src -> $dst"
echo "== 卸载前 =="
in_ctr findmnt -T "$dst" || true

# 旧挂载指向已删除的目录时，新挂载放不上去，必须先卸掉。可能叠了多层，循环卸。
while in_ctr findmnt -M "$dst" >/dev/null 2>&1; do
  in_ctr umount -l "$dst" || { echo "卸载 $dst 失败，停止。" >&2; exit 1; }
done
in_ctr mkdir -p "$dst"

# docker exec 里的 root 没有卸载权限，mount --bind 也进不了容器的挂载树。
# 这里先在宿主机克隆一份独立挂载（open_tree），再 setns 进容器，用 move_mount 挂到目标路径。
python3 - "$pid" "$src" "$dst" << 'PY' || exit 1
import ctypes, os, sys

libc = ctypes.CDLL(None, use_errno=True)
libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_void_p]
libc.mount.restype = ctypes.c_int
libc.umount.argtypes = [ctypes.c_char_p]
libc.umount.restype = ctypes.c_int
libc.setns.argtypes = [ctypes.c_int, ctypes.c_int]
libc.setns.restype = ctypes.c_int
libc.syscall.restype = ctypes.c_long


def die(what):
    raise OSError(ctypes.get_errno(), what)


pid, src, dst = sys.argv[1:]
AT_FDCWD = -100
OPEN_TREE_CLONE = 1
AT_RECURSIVE = 0x8000
MOVE_MOUNT_F_EMPTY_PATH = 4
MS_BIND_REC = 4096
SYS_OPEN_TREE = 428
SYS_MOVE_MOUNT = 429

nsfd = os.open(f"/proc/{pid}/ns/mnt", os.O_RDONLY)

added = not os.path.ismount(src)
if added and libc.mount(src.encode(), src.encode(), None, MS_BIND_REC, None) != 0:
    die("bind " + src)

libc.syscall.argtypes = [ctypes.c_long, ctypes.c_int, ctypes.c_char_p, ctypes.c_ulong]
fd = libc.syscall(SYS_OPEN_TREE, AT_FDCWD, src.encode(), OPEN_TREE_CLONE | os.O_CLOEXEC | AT_RECURSIVE)
if fd < 0:
    err = ctypes.get_errno()
    if added:
        libc.umount(src.encode())
    raise OSError(err, "open_tree")
if added and libc.umount(src.encode()) != 0:
    die("umount temporary bind")

if libc.setns(nsfd, 0) != 0:
    die("setns")
os.close(nsfd)

libc.syscall.argtypes = [ctypes.c_long, ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_ulong]
if libc.syscall(SYS_MOVE_MOUNT, int(fd), b"", AT_FDCWD, dst.encode(), MOVE_MOUNT_F_EMPTY_PATH) < 0:
    die("move_mount")
print("mounted", src, "->", dst)
PY

echo "== 挂载后 =="
in_ctr findmnt -T "$dst"
in_ctr ls "$dst"
```

### run_musa_sglang_container.sh

```bash
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
```

### start_qwen35_397b_sglang_musa.sh

```bash
#!/usr/bin/env bash
# 摩尔线程 MTT S5000 上启动 Qwen3.5-397B，服务参数与海光 BW1100 脚本对齐，便于对比。
#
# 在容器里执行，模型目录或模型名作为第一个参数。日志按模型名分开。
#   bash start_qwen35_397b_sglang_musa.sh Qwen3.5-397B-A17B-Channel-FP8-w8a8
#   bash start_qwen35_397b_sglang_musa.sh /data/models/Qwen3.5-397B-A17B-FP8
#
# Docker 在宿主机执行 run_musa_sglang_container.sh。
# 镜像 local/ctr-33869d47a065:20261016，宿主机 /data1/models 挂到容器 /data/models。
# 不要使用海光的 --device=/dev/kfd、/dev/dri、/dev/mkfd，也不要挂载 /opt/hyhal。
# 摩尔线程用 --privileged 暴露 /dev/musa*。
#
# 与海光脚本相同的服务参数:
#   --tp-size 4 --pp-size 1 --trust-remote-code --dtype bfloat16
#   --port 31216 --attention-backend fa3 --page-size 64
#   --watchdog-timeout 36000 --kv-cache-dtype fp8_e4m3
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
#      模型由第一个参数指定，例如 Qwen3.5-397B-A17B-Channel-FP8-w8a8。
#      不传 slimquant_marlin，由镜像按 checkpoint 的 quantization_config 识别 FP8。
#   2. --numa-node 4 5 5 7
#      这是 BW1100 的 NUMA 拓扑。填错会绑到错误的 CPU。默认不传，按本机 numactl -H 填。
#   3. HIP_*、HSA_*、ROC_*、USE_DCU_*、SGLANG_USE_LIGHTOP、SGLANG_USE_AITER_LINEAR_ATTN、
#      SGLANG_KV_LAYOUT_DCU_FA、SGLANG_USE_FP8_W8A8_MOE、NCCL_MIN/MAX_NCHANNELS
#      这些只作用于海光 DCU 或那台机器的通信调优，不带进摩尔线程进程。
#   4. --enable-piecewise-cuda-graph
#      v0.5.12 里这个参数已废弃，解析后不生效。piecewise 默认会开，
#      但 Qwen3.5 的结构是 Qwen3_5MoeForConditionalGeneration，属于多模态模型，
#      启动时会被自动关掉。日志仍打印
#      "because --disable-piecewise-cuda-graph is set"，并不表示命令行写了 disable。
#      要跳过自动关闭，参数是 --enforce-piecewise-cuda-graph。海光脚本里的 enable
#      在同一版本上同样不生效。强制打开前先看海光日志是否也是这句。
#   5. --linear-attn-backend flashinfer
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

# 容器里若已经 export 了 8 张卡，未指定 TP_SIZE 时跟卡数走。
# 海光原脚本是 4 张卡。这台 S5000 要装下该模型需要 8 张卡。
export MTHREADS_VISIBLE_DEVICES="${MTHREADS_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7}"
if [[ -z "${TP_SIZE:-}" ]]; then
  TP_SIZE=$(awk -F',' '{print NF}' <<<"$MTHREADS_VISIBLE_DEVICES")
fi

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

MODELS_DIR="${MODELS_DIR:-/data/models}"

usage() {
  cat <<EOF
用法: bash $0 <模型目录或模型名>

模型名不含路径时，在 ${MODELS_DIR} 下查找。
日志默认写到 \$WORK_DIR/log/<模型名>-musa/server_*.log。
可用环境变量 MODEL_PATH、LOG_DIR、WORK_DIR、PORT、SERVED_MODEL_NAME 覆盖。

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
elif [[ -z "${MODEL_PATH:-}" ]]; then
  usage >&2
  exit 1
fi

MODEL_NAME="$(basename "${MODEL_PATH%/}")"
if [[ ! -d "$MODEL_PATH" ]]; then
  echo "模型目录不存在: $MODEL_PATH" >&2
  echo "传入 ${MODELS_DIR} 下的目录名，或完整路径。" >&2
  exit 1
fi
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$MODEL_NAME}"
PORT="${PORT:-31216}"
if [[ -z "${WORK_DIR:-}" ]]; then
  if [[ -d /lujq ]]; then
    WORK_DIR=/lujq
  else
    WORK_DIR=/sgl-workspace/sglang
  fi
fi
LOG_DIR="${LOG_DIR:-$WORK_DIR/log/${MODEL_NAME}-musa}"
export SGLANG_TORCH_PROFILER_DIR="${SGLANG_TORCH_PROFILER_DIR:-$WORK_DIR/profile/${MODEL_NAME}}"

# 海光是 --numa-node 4 5 5 7。这里默认留空。
# 查看本机: numactl -H
# 个数必须等于 TP_SIZE。例: NUMA_NODES="0 0 1 1"
NUMA_NODES="${NUMA_NODES:-}"

# 未指定时按模型目录大小估计权重合计，用来判断当前 TP 放不放得下。
ALLOW_OVERSIZE="${ALLOW_OVERSIZE:-0}"

mkdir -p "$LOG_DIR" "$SGLANG_TORCH_PROFILER_DIR"
SERVER_LOG="$LOG_DIR/server_$(date +%Y%m%d_%H%M%S).log"

gpu_count=$(awk -F',' '{print NF}' <<<"$MTHREADS_VISIBLE_DEVICES")
if [[ "$gpu_count" -ne "$TP_SIZE" ]]; then
  echo "MTHREADS_VISIBLE_DEVICES=$MTHREADS_VISIBLE_DEVICES 共 ${gpu_count} 张卡，TP_SIZE=$TP_SIZE。两者必须相同。" | tee -a "$SERVER_LOG"
  echo "8 张卡启动: TP_SIZE=${gpu_count} bash $0 ${MODEL_NAME}" | tee -a "$SERVER_LOG"
  exit 1
fi

if [[ -z "${WEIGHT_TOTAL_GIB:-}" ]]; then
  weight_bytes=$(du -sb "$MODEL_PATH" 2>/dev/null | awk '{print $1}')
  if [[ -n "${weight_bytes:-}" ]]; then
    WEIGHT_TOTAL_GIB=$(awk -v bytes="$weight_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 / 1024 }')
  else
    WEIGHT_TOTAL_GIB=0
  fi
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
  echo "MODEL_NAME=$MODEL_NAME"
  echo "MODEL_PATH=$MODEL_PATH"
  echo "SERVED_MODEL_NAME=$SERVED_MODEL_NAME"
  echo "LOG_DIR=$LOG_DIR"
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
    echo "已停止。模型 ${MODEL_NAME} 目录约 ${WEIGHT_TOTAL_GIB} GiB，TP=$TP_SIZE 时每卡约 ${need_gib} GiB，单卡可用约 ${usable_gib} GiB。"
    echo "加大 TP_SIZE，使它等于可见卡数。确认显存足够时用 ALLOW_OVERSIZE=1 bash $0 ${MODEL_NAME}。"
    echo "海光 BW1100 单卡 144 GiB。两边 TP 不同时，不要把吞吐直接比较。"
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
  --speculative-algorithm EAGLE
  --speculative-num-steps 3
  --speculative-eagle-topk 1
  --speculative-num-draft-tokens 4
  --model-path "$MODEL_PATH"
  --served-model-name "$SERVED_MODEL_NAME"
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
  echo "v0.5.12 的 --enable-piecewise-cuda-graph 已废弃，不会打开 piecewise。Qwen3.5 是多模态结构，启动时会自动关闭，日志仍写 because --disable-piecewise-cuda-graph is set。"
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
```

### bench_qwen35_397b_sglang_musa.sh

```bash
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
```
