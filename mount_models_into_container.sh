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
