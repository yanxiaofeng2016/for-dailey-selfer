#!/usr/bin/env bash
# 用法: bash collect_mthreads_info.sh
# 也可: chmod +x collect_mthreads_info.sh && ./collect_mthreads_info.sh
# 指定报告路径: OUT=/tmp/report.txt bash collect_mthreads_info.sh
#
# 采集摩尔线程（Moore Threads）GPU 服务器的硬件与软件清单。
# 命令缺失、超时或权限不足时写入说明并继续，不中断整份报告。
# 不使用 set -e。摩尔线程 GPU 使用 mthreads-gmi，不调用 nvidia-smi。

set -u
set -o pipefail

CAP_RC=0
WORKDIR=""
OUTFILE=""
OUTFILE_ABS=""
ETHTOOL_BIN=""
LSPI_DONE=0
LSPI_STATUS=""
LSPI_FILE=""
LSPI_RC=0

cleanup() {
  if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
    rm -rf -- "${WORKDIR}"
  fi
}
trap cleanup EXIT

section() {
  printf '\n========== %s ==========\n' "$1"
}

resolve_bin() {
  local name="$1"
  local path=""
  path=$(type -P "$name" 2>/dev/null || true)
  if [[ -n "$path" && -x "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  local candidate
  for candidate in "/usr/sbin/${name}" "/sbin/${name}" "/usr/bin/${name}" "/bin/${name}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

run_to_file() {
  local outfile="$1"
  shift
  CAP_RC=0
  : >"$outfile"
  if [[ $# -lt 1 ]]; then
    printf '%s\n' "未指定命令" >"$outfile"
    CAP_RC=127
    return 0
  fi
  if [[ "$1" == */* ]]; then
    if [[ ! -x "$1" ]]; then
      printf '未找到或不可执行: %s\n' "$1" >"$outfile"
      CAP_RC=127
      return 0
    fi
  elif ! type -P "$1" >/dev/null 2>&1; then
    printf '未安装: %s\n' "$1" >"$outfile"
    CAP_RC=127
    return 0
  fi
  if type -P timeout >/dev/null 2>&1; then
    timeout 30 "$@" >"$outfile" 2>&1 || CAP_RC=$?
  else
    "$@" >"$outfile" 2>&1 || CAP_RC=$?
  fi
  return 0
}

note_rc() {
  local label="$1"
  if [[ "$CAP_RC" -eq 0 ]]; then
    return 0
  fi
  if [[ "$CAP_RC" -eq 124 ]]; then
    printf '[超时 30s] %s\n' "$label"
  else
    printf '[命令失败，退出码 %s] %s\n' "$CAP_RC" "$label"
  fi
  return 0
}

run_show() {
  local title="$1"
  shift
  local out="${WORKDIR}/cmd.out"
  printf '\n----- %s -----\n' "$title"
  run_to_file "$out" "$@"
  cat "$out"
  note_rc "$*"
  return 0
}

read_one_line() {
  local path="$1"
  local fallback="${2:-未知}"
  local value=""
  if [[ -r "$path" ]]; then
    value=$(tr -d '\n' <"$path" 2>/dev/null || true)
  fi
  if [[ -z "$value" ]]; then
    printf '%s\n' "$fallback"
  else
    printf '%s\n' "$value"
  fi
}

is_skipped_iface() {
  # Calico 网卡常见前缀是 cali，而不是 calico
  case "$1" in
    lo|lo[0-9]*|docker*|veth*|cni*|flannel*|calico*|cali*|virbr*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

print_name_list() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    printf '%s\n' "无"
    return 0
  fi
  awk 'NR>1 { printf " " } { printf "%s", $0 } END { printf "\n" }' "$file"
  return 0
}

resolve_pci() {
  local dev="$1"
  local cur="" name="" devname=""
  cur=$(readlink -f -- "$dev" 2>/dev/null || true)
  if [[ -z "$cur" ]]; then
    printf '%s\n' "未知"
    return 0
  fi
  devname=$(basename -- "$cur")
  while [[ -n "$cur" && "$cur" != "/" ]]; do
    name=$(basename -- "$cur")
    if [[ "$name" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
      printf '%s\n' "$name"
      return 0
    fi
    cur=$(dirname -- "$cur")
  done
  printf '%s（非 PCI 或未能向上解析 BDF）\n' "$devname"
  return 0
}

init_workdir() {
  if type -P mktemp >/dev/null 2>&1; then
    WORKDIR=$(mktemp -d 2>/dev/null || true)
  fi
  if [[ -z "$WORKDIR" || ! -d "$WORKDIR" ]]; then
    WORKDIR="/tmp/mthreads-collect-$$-${RANDOM}"
    mkdir -p -- "$WORKDIR"
  fi
  if [[ ! -d "$WORKDIR" ]]; then
    printf '无法创建临时目录，采集中止。\n' >&2
    exit 1
  fi
}

init_outfile() {
  local ts out_dir script_path out_abs
  ts=$(date '+%Y%m%d-%H%M%S')
  if [[ -n "${OUT:-}" ]]; then
    OUTFILE=$OUT
  else
    OUTFILE="./mthreads-inventory-${ts}.txt"
  fi
  out_dir=$(dirname -- "$OUTFILE")
  if [[ ! -d "$out_dir" ]]; then
    if ! mkdir -p -- "$out_dir"; then
      printf '无法创建输出目录 %s，改为当前目录。\n' "$out_dir" >&2
      OUTFILE="./mthreads-inventory-${ts}.txt"
    fi
  fi
  script_path=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")
  out_abs=$(readlink -f -- "$OUTFILE" 2>/dev/null || printf '%s' "$OUTFILE")
  if [[ "$script_path" == "$out_abs" ]]; then
    printf 'OUT 指向脚本自身，改为当前目录下的报告文件。\n' >&2
    OUTFILE="./mthreads-inventory-${ts}.txt"
  fi
  if ! touch -- "$OUTFILE"; then
    printf '无法写入 %s，仅输出到标准输出。\n' "$OUTFILE" >&2
    OUTFILE=""
    OUTFILE_ABS=""
    return 0
  fi
  OUTFILE_ABS=$(readlink -f -- "$OUTFILE" 2>/dev/null || printf '%s' "$OUTFILE")
}

collect_overview() {
  local host="" now="" user="" uid="" root_txt=""
  section "1. 采集概要"
  if type -P hostname >/dev/null 2>&1; then
    host=$(hostname 2>/dev/null || true)
  fi
  if [[ -z "$host" && -r /proc/sys/kernel/hostname ]]; then
    host=$(tr -d '\n' </proc/sys/kernel/hostname || true)
  fi
  host=${host:-未知}
  now=$(date '+%F %T %z' 2>/dev/null || printf '%s' "未知")
  user=$(id -un 2>/dev/null || printf '%s' "未知")
  uid=$(id -u 2>/dev/null || printf '%s' "未知")
  if [[ "$uid" == "0" ]]; then
    root_txt="是"
  else
    root_txt="否"
  fi
  printf '%s\n' "摩尔线程 GPU 服务器硬件与软件采集报告"
  printf '主机名: %s\n' "$host"
  printf '采集时间: %s\n' "$now"
  printf '当前用户: %s\n' "$user"
  printf 'uid: %s\n' "$uid"
  printf '是否 root: %s\n' "$root_txt"
  printf 'Bash: %s\n' "${BASH_VERSION}"
  if [[ -n "$OUTFILE_ABS" ]]; then
    printf '报告文件: %s\n' "$OUTFILE_ABS"
  else
    printf '%s\n' "报告文件: 仅标准输出（未能创建报告文件）"
  fi
  if [[ "$root_txt" == "否" ]]; then
    printf '%s\n' "提示: 当前不是 root。dmidecode 等命令可能因权限不足而无法读取 SMBIOS。"
  fi
}

collect_os() {
  local pretty="" hostctl=""
  section "2. 操作系统与内核"
  printf '内核版本: %s\n' "$(uname -r 2>/dev/null || printf '%s' "未知")"
  if [[ -r /etc/os-release ]]; then
    pretty=$(awk -F= '$1=="PRETTY_NAME" { gsub(/^"|"$/, "", $2); print $2; exit }' /etc/os-release || true)
    printf '操作系统: %s\n' "${pretty:-未知}"
    printf '\n----- /etc/os-release -----\n'
    cat /etc/os-release
  else
    printf '%s\n' "无法读取 /etc/os-release"
  fi
  printf '\n----- uname -a -----\n'
  uname -a || printf '%s\n' "uname 执行失败"
  hostctl=$(resolve_bin hostnamectl || true)
  if [[ -z "$hostctl" ]]; then
    printf '\n%s\n' "未安装: hostnamectl"
  else
    run_show "hostnamectl" "$hostctl"
  fi
}

summarize_lscpu() {
  awk '
    {
      n = index($0, ":")
      if (n == 0) next
      key = substr($0, 1, n - 1)
      val = substr($0, n + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (key == "Architecture") arch = val
      else if (key == "Vendor ID") vendor = val
      else if (key == "Model name") model = val
      else if (key == "Socket(s)") sockets = val
      else if (key == "Core(s) per socket") cores = val
      else if (key == "Thread(s) per core") tpc = val
      else if (key == "CPU(s)") cpus = val
      else if (key == "NUMA node(s)") numa = val
      else if (key == "CPU max MHz") maxmhz = val
      else if (key == "CPU(s) scaling MHz") curmhz = val
    }
    END {
      print "架构: " (arch == "" ? "未知" : arch)
      print "厂商: " (vendor == "" ? "未知" : vendor)
      print "型号: " (model == "" ? "未知" : model)
      print "插槽数 (Socket): " (sockets == "" ? "未知" : sockets)
      print "每槽核数: " (cores == "" ? "未知" : cores)
      print "每核线程数: " (tpc == "" ? "未知" : tpc)
      print "逻辑 CPU 数: " (cpus == "" ? "未知" : cpus)
      print "NUMA 节点数: " (numa == "" ? "未知" : numa)
      if (maxmhz != "") print "最高频率 MHz: " maxmhz
      if (curmhz != "") print "当前频率 MHz: " curmhz
    }
  ' "$1"
}

summarize_cpuinfo() {
  local cpuinfo="/proc/cpuinfo"
  local model="" sockets="" cores="" siblings="" logical=""
  if [[ ! -r "$cpuinfo" ]]; then
    printf '%s\n' "无法读取 /proc/cpuinfo"
    return 0
  fi
  model=$(awk -F: '/^model name/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }' "$cpuinfo" || true)
  logical=$(grep -c '^processor' "$cpuinfo" || true)
  if grep -q '^physical id' "$cpuinfo"; then
    sockets=$(awk -F: '/^physical id/ { gsub(/[[:space:]]/, "", $2); print $2 }' "$cpuinfo" | sort -u | grep -c . || true)
  else
    sockets="未知（无 physical id）"
  fi
  cores=$(awk -F: '/^cpu cores/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$cpuinfo" || true)
  siblings=$(awk -F: '/^siblings/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$cpuinfo" || true)
  printf '型号: %s\n' "${model:-未知}"
  printf '插槽数 (Socket): %s\n' "${sockets:-未知}"
  printf '每槽核数: %s\n' "${cores:-未知}"
  printf 'siblings: %s\n' "${siblings:-未知}"
  printf '逻辑 CPU 数: %s\n' "${logical:-未知}"
  return 0
}

collect_numa() {
  local -a nodes=()
  local node="" cpulist="" memline=""
  printf '\n----- NUMA -----\n'
  mapfile -t nodes < <(
    shopt -s nullglob
    for node in /sys/devices/system/node/node[0-9]*; do
      if [[ -e "$node" || -L "$node" ]]; then
        basename -- "$node"
      fi
    done | sort
  )
  if [[ ${#nodes[@]} -eq 0 ]]; then
    printf '%s\n' "未发现 NUMA 节点目录 /sys/devices/system/node/node*"
    return 0
  fi
  printf 'NUMA 节点数: %s\n' "${#nodes[@]}"
  for node in "${nodes[@]}"; do
    cpulist=$(read_one_line "/sys/devices/system/node/${node}/cpulist")
    memline="未知"
    if [[ -r "/sys/devices/system/node/${node}/meminfo" ]]; then
      memline=$(awk '/MemTotal/ { print $4 " " $5; exit }' "/sys/devices/system/node/${node}/meminfo" || true)
      memline=${memline:-未知}
    fi
    printf '  %s: CPU=%s MemTotal=%s\n' "$node" "$cpulist" "$memline"
  done
  return 0
}

collect_cpu() {
  local lscpu_bin="" lscpu_file="" rc=0
  section "3. CPU"
  lscpu_bin=$(resolve_bin lscpu || true)
  lscpu_file="${WORKDIR}/lscpu.txt"
  if [[ -z "$lscpu_bin" ]]; then
    printf '%s\n' "未安装: lscpu，改用 /proc/cpuinfo"
    summarize_cpuinfo
  else
    printf '%s\n' "lscpu 使用 C 区域设置，便于稳定解析字段。"
    if type -P timeout >/dev/null 2>&1; then
      LC_ALL=C timeout 30 "$lscpu_bin" >"$lscpu_file" 2>&1 || rc=$?
    else
      LC_ALL=C "$lscpu_bin" >"$lscpu_file" 2>&1 || rc=$?
    fi
    if [[ "$rc" -ne 0 && ! -s "$lscpu_file" ]]; then
      printf 'lscpu 执行失败（退出码 %s），改用 /proc/cpuinfo\n' "$rc"
      summarize_cpuinfo
    else
      printf '\n----- CPU 摘要 -----\n'
      summarize_lscpu "$lscpu_file"
      if [[ "$rc" -ne 0 ]]; then
        printf '[lscpu 退出码 %s]\n' "$rc"
      fi
      printf '\n----- lscpu 全文 -----\n'
      cat "$lscpu_file"
    fi
  fi
  collect_numa
}

summarize_dmidecode() {
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function size_gb(s,   n, rest) {
      if (s ~ /[Nn]o [Mm]odule/ || s ~ /[Nn]ot [Ii]nstalled/ || s ~ /[Nn]ot [Ss]pecified/ || s ~ /^[Uu]nknown$/ || s ~ /^[Nn]one$/)
        return -1
      if (match(s, /[0-9]+([.][0-9]+)?/)) {
        n = substr(s, RSTART, RLENGTH) + 0
        rest = substr(s, RSTART + RLENGTH)
        if (rest ~ /^[[:space:]]*[Tt][Bb]/) return n * 1024
        if (rest ~ /^[[:space:]]*[Mm][Bb]/) return n / 1024
        if (rest ~ /^[[:space:]]*[Gg][Bb]/) return n
        if (rest ~ /^[[:space:]]*[Kk][Bb]/) return n / 1048576
      }
      return -1
    }
    function flush(   gb, loc_s, type_s, speed_s, conf_s, mfr_s) {
      if (!in_dev) return
      in_dev = 0
      if (size == "") return
      gb = size_gb(size)
      if (gb <= 0) {
        empty++
        return
      }
      installed++
      total += gb
      have_total = 1
      loc_s = (loc == "" ? "未知" : loc)
      type_s = (type == "" ? "未知" : type)
      speed_s = (speed == "" ? "未知" : speed)
      conf_s = (conf == "" ? "未知" : conf)
      mfr_s = (mfr == "" ? "未知" : mfr)
      printf "  [%d] 位置=%s 容量=%s 类型=%s 标称速率=%s 当前速率=%s 厂商=%s\n", installed, loc_s, size, type_s, speed_s, conf_s, mfr_s
    }
    BEGIN { in_dev = 0; installed = 0; empty = 0; total = 0; have_total = 0 }
    /^Memory Device$/ {
      if (in_dev) flush()
      in_dev = 1
      size = ""; speed = ""; conf = ""; mfr = ""; loc = ""; type = ""
      next
    }
    in_dev && /^[[:space:]]*Size:/ {
      sub(/^[[:space:]]*Size:[[:space:]]*/, "")
      size = trim($0)
      next
    }
    in_dev && /^[[:space:]]*Speed:/ {
      sub(/^[[:space:]]*Speed:[[:space:]]*/, "")
      speed = trim($0)
      next
    }
    in_dev && /^[[:space:]]*Configured Memory Speed:/ {
      sub(/^[[:space:]]*Configured Memory Speed:[[:space:]]*/, "")
      conf = trim($0)
      next
    }
    in_dev && /^[[:space:]]*Manufacturer:/ {
      sub(/^[[:space:]]*Manufacturer:[[:space:]]*/, "")
      mfr = trim($0)
      next
    }
    in_dev && /^[[:space:]]*Locator:/ {
      sub(/^[[:space:]]*Locator:[[:space:]]*/, "")
      loc = trim($0)
      next
    }
    in_dev && /^[[:space:]]*Type:/ {
      sub(/^[[:space:]]*Type:[[:space:]]*/, "")
      type = trim($0)
      next
    }
    /^Handle / {
      if (in_dev) flush()
    }
    END {
      if (in_dev) flush()
      print "已安装内存条数量: " installed
      print "空槽位数量: " empty
      if (installed == 0 && empty == 0)
        print "未解析到 Memory Device 记录。"
      else if (have_total)
        printf "已安装容量合计: %.2f GB\n", total
    }
  ' "$1"
}

collect_memory() {
  local free_bin="" dmi_bin="" dmi_out="" dmi_err="" dmi_sum="" rc=0
  section "4. 内存"
  free_bin=$(resolve_bin free || true)
  if [[ -z "$free_bin" ]]; then
    printf '%s\n' "未安装: free"
  else
    run_show "free -h" env LC_ALL=C "$free_bin" -h
  fi
  printf '\n----- /proc/meminfo MemTotal -----\n'
  if [[ -r /proc/meminfo ]]; then
    if ! grep -E '^MemTotal:' /proc/meminfo; then
      printf '%s\n' "未找到 MemTotal"
    fi
  else
    printf '%s\n' "无法读取 /proc/meminfo"
  fi

  printf '\n----- 内存条摘要 (dmidecode -t memory) -----\n'
  dmi_bin=$(resolve_bin dmidecode || true)
  if [[ -z "$dmi_bin" ]]; then
    printf '%s\n' "未安装: dmidecode"
    return 0
  fi
  dmi_out="${WORKDIR}/dmi.out"
  dmi_err="${WORKDIR}/dmi.err"
  dmi_sum="${WORKDIR}/dmi.sum"
  if type -P timeout >/dev/null 2>&1; then
    LC_ALL=C timeout 30 "$dmi_bin" -t memory >"$dmi_out" 2>"$dmi_err" || rc=$?
  else
    LC_ALL=C "$dmi_bin" -t memory >"$dmi_out" 2>"$dmi_err" || rc=$?
  fi
  if [[ "$rc" -eq 124 ]]; then
    printf '%s\n' "dmidecode 超时（30s）。"
  elif [[ -s "$dmi_err" ]] && grep -qiE 'permission|privilege|not permitted|must be root|Operation not permitted|are you root' "$dmi_err"; then
    printf '%s\n' "dmidecode 无法读取 SMBIOS：权限不足。请以 root 运行本脚本后再采集内存条明细。"
  elif [[ "$rc" -ne 0 ]]; then
    printf 'dmidecode 执行失败，退出码 %s。\n' "$rc"
  fi
  if [[ -s "$dmi_err" ]]; then
    printf '%s\n' "dmidecode 标准错误:"
    sed 's/^/  /' "$dmi_err"
  fi
  if [[ ! -s "$dmi_out" ]]; then
    printf '%s\n' "dmidecode 没有可用的标准输出，已跳过内存条摘要。"
    return 0
  fi
  summarize_dmidecode "$dmi_out" >"$dmi_sum"
  cat "$dmi_sum"
  if grep -q '未解析到 Memory Device' "$dmi_sum"; then
    printf '%s\n' "dmidecode 原始输出前 30 行:"
    awk 'NR<=30 { print "  " $0 }' "$dmi_out"
  fi
  return 0
}

ensure_lspci() {
  local bin="" err=""
  if [[ "$LSPI_DONE" -eq 1 ]]; then
    return 0
  fi
  LSPI_DONE=1
  LSPI_STATUS="missing"
  LSPI_RC=0
  LSPI_FILE="${WORKDIR}/lspci.txt"
  err="${WORKDIR}/lspci.err"
  : >"$LSPI_FILE"
  : >"$err"
  bin=$(resolve_bin lspci || true)
  if [[ -z "$bin" ]]; then
    return 0
  fi
  if type -P timeout >/dev/null 2>&1; then
    LC_ALL=C timeout 30 "$bin" -Dnn >"$LSPI_FILE" 2>"$err" || LSPI_RC=$?
  else
    LC_ALL=C "$bin" -Dnn >"$LSPI_FILE" 2>"$err" || LSPI_RC=$?
  fi
  if [[ "$LSPI_RC" -ne 0 ]]; then
    LSPI_STATUS="fail"
  else
    LSPI_STATUS="ok"
  fi
  return 0
}

show_lspci_status() {
  ensure_lspci
  case "$LSPI_STATUS" in
    missing)
      printf '%s\n' "未安装: lspci"
      ;;
    fail)
      printf 'lspci 执行失败，退出码 %s。\n' "$LSPI_RC"
      if [[ -s "${WORKDIR}/lspci.err" ]]; then
        sed 's/^/  /' "${WORKDIR}/lspci.err"
      fi
      ;;
    ok)
      return 0
      ;;
    *)
      printf '%s\n' "lspci 状态未知"
      ;;
  esac
  return 1
}

dump_one_nic() {
  local iface="$1"
  local base="/sys/class/net/${iface}"
  local mac="" state="" mtu="" driver="" pci="" speed="" filtered=""
  local eth_out="${WORKDIR}/ethtool.out"
  mac=$(read_one_line "${base}/address")
  state=$(read_one_line "${base}/operstate")
  mtu=$(read_one_line "${base}/mtu")
  if [[ -e "${base}/device/driver" || -L "${base}/device/driver" ]]; then
    driver=$(basename -- "$(readlink -f -- "${base}/device/driver" 2>/dev/null || printf '%s' "未知")")
  else
    driver="未知"
  fi
  if [[ -e "${base}/device" || -L "${base}/device" ]]; then
    pci=$(resolve_pci "${base}/device")
  else
    pci="无"
  fi
  printf '接口: %s\n' "$iface"
  printf '  MAC: %s\n' "$mac"
  printf '  状态: %s\n' "$state"
  printf '  MTU: %s\n' "$mtu"
  printf '  驱动: %s\n' "$driver"
  printf '  PCI: %s\n' "$pci"
  if [[ -e "${base}/carrier" ]]; then
    local carrier=""
    carrier=$(tr -d '\n' <"${base}/carrier" 2>/dev/null || true)
    if [[ "$carrier" == "1" ]]; then
      printf '%s\n' "  链路: 已连接"
    elif [[ "$carrier" == "0" ]]; then
      printf '%s\n' "  链路: 未连接"
    else
      printf '%s\n' "  链路: 未知"
    fi
  fi
  if [[ -e "${base}/speed" ]]; then
    speed=$(tr -d '\n' <"${base}/speed" 2>/dev/null || true)
    if [[ -z "$speed" ]]; then
      printf '%s\n' "  速率(sysfs): 不可读（链路可能未就绪或无权限）"
    elif [[ "$speed" == "-1" ]]; then
      printf '%s\n' "  速率(sysfs): 未知（读数为 -1）"
    else
      printf '  速率(sysfs): %s Mb/s\n' "$speed"
    fi
  else
    printf '%s\n' "  速率(sysfs): 无 speed 文件"
  fi
  if [[ -n "$ETHTOOL_BIN" ]]; then
    printf '  ----- ethtool %s -----\n' "$iface"
    run_to_file "$eth_out" env LC_ALL=C "$ETHTOOL_BIN" "$iface"
    if grep -Ei 'Speed:|Duplex:|Link detected:|Port:|Auto-negotiation:' "$eth_out" | sed 's/^/  /'; then
      :
    else
      awk 'NR<=30 { print "  " $0 }' "$eth_out"
    fi
    note_rc "ethtool ${iface}" | sed 's/^/  /'
    printf '  ----- ethtool -i %s -----\n' "$iface"
    run_to_file "$eth_out" env LC_ALL=C "$ETHTOOL_BIN" -i "$iface"
    sed 's/^/  /' "$eth_out"
    note_rc "ethtool -i ${iface}" | sed 's/^/  /'
  fi
  printf '\n'
  return 0
}

collect_rdma() {
  local -a ibdevs=() ports=()
  local name="" f="" port="" tool="" bin="" any=0
  printf '\n----- RDMA / InfiniBand -----\n'
  if [[ ! -d /sys/class/infiniband ]]; then
    printf '%s\n' "未发现 /sys/class/infiniband（无 RDMA/InfiniBand 设备，或驱动未加载）。"
  else
    mapfile -t ibdevs < <(
      shopt -s nullglob
      for name in /sys/class/infiniband/*; do
        if [[ -e "$name" || -L "$name" ]]; then
          basename -- "$name"
        fi
      done | sort
    )
    if [[ ${#ibdevs[@]} -eq 0 ]]; then
      printf '%s\n' "/sys/class/infiniband 目录存在，但没有设备。"
    else
      for name in "${ibdevs[@]}"; do
        printf '设备: %s\n' "$name"
        for f in node_type node_guid node_desc hca_type fw_ver board_id; do
          if [[ -r "/sys/class/infiniband/${name}/${f}" ]]; then
            printf '  %s: %s\n' "$f" "$(read_one_line "/sys/class/infiniband/${name}/${f}" "")"
          fi
        done
        mapfile -t ports < <(
          shopt -s nullglob
          for port in "/sys/class/infiniband/${name}/ports/"*; do
            if [[ -e "$port" || -L "$port" ]]; then
              basename -- "$port"
            fi
          done | sort
        )
        if [[ ${#ports[@]} -eq 0 ]]; then
          printf '%s\n' "  无端口信息"
        else
          for port in "${ports[@]}"; do
            printf '  端口 %s:\n' "$port"
            for f in state rate link_layer phys_state; do
              if [[ -r "/sys/class/infiniband/${name}/ports/${port}/${f}" ]]; then
                printf '    %s: %s\n' "$f" "$(read_one_line "/sys/class/infiniband/${name}/ports/${port}/${f}" "")"
              fi
            done
          done
        fi
      done
    fi
  fi
  for tool in ibstat ibv_devinfo ibdev2netdev; do
    bin=$(resolve_bin "$tool" || true)
    if [[ -z "$bin" ]]; then
      printf '未安装: %s\n' "$tool"
    else
      any=1
      run_show "$tool" env LC_ALL=C "$bin"
    fi
  done
  if [[ "$any" -eq 0 ]]; then
    printf '%s\n' "RDMA 用户态工具均未安装。设备是否存在以 /sys/class/infiniband 为准。"
  fi
  return 0
}

collect_nics() {
  local ip_bin="" skipped_file="" virt_file="" count=0
  local -a entries=()
  local iface=""
  section "5. 网卡"
  ip_bin=$(resolve_bin ip || true)
  if [[ -z "$ip_bin" ]]; then
    printf '%s\n' "未安装: ip（无法执行 ip -br link / ip -br addr）。以下改用 /sys/class/net。"
  else
    run_show "ip -br link" env LC_ALL=C "$ip_bin" -br link
    run_show "ip -br addr" env LC_ALL=C "$ip_bin" -br addr
  fi

  printf '\n----- lspci 网络控制器 -----\n'
  printf '%s\n' "lspci 使用 C 区域设置，避免类名被翻译后无法匹配。"
  if show_lspci_status; then
    local nic_count=0
    nic_count=$(grep -Eic 'ethernet|infiniband|network' "$LSPI_FILE" || true)
    if [[ "${nic_count:-0}" -eq 0 ]]; then
      printf '%s\n' "未匹配到以太网 / InfiniBand / 网络控制器"
    else
      printf '匹配行数: %s\n' "$nic_count"
      grep -Ei 'ethernet|infiniband|network' "$LSPI_FILE"
    fi
  fi

  printf '\n----- 物理网卡明细 -----\n'
  printf '%s\n' "跳过名称匹配 lo、docker、veth、cni、flannel、calico、cali、virbr 的接口。"
  ETHTOOL_BIN=$(resolve_bin ethtool || true)
  if [[ -z "$ETHTOOL_BIN" ]]; then
    printf '%s\n' "未安装: ethtool，跳过各网卡速率与驱动详情查询。"
  fi
  skipped_file="${WORKDIR}/nic.skipped"
  virt_file="${WORKDIR}/nic.virtual"
  : >"$skipped_file"
  : >"$virt_file"
  mapfile -t entries < <(
    shopt -s nullglob
    for iface in /sys/class/net/*; do
      if [[ -e "$iface" || -L "$iface" ]]; then
        basename -- "$iface"
      fi
    done | sort
  )
  if [[ ${#entries[@]} -eq 0 ]]; then
    printf '%s\n' "未找到 /sys/class/net 下的接口"
  else
    for iface in "${entries[@]}"; do
      if is_skipped_iface "$iface"; then
        printf '%s\n' "$iface" >>"$skipped_file"
        continue
      fi
      if [[ -e "/sys/class/net/${iface}/device" || -L "/sys/class/net/${iface}/device" ]]; then
        count=$((count + 1))
        dump_one_nic "$iface" || true
      else
        printf '%s\n' "$iface" >>"$virt_file"
      fi
    done
  fi
  printf '物理网卡数量: %s\n' "$count"
  printf '%s' "已跳过接口: "
  print_name_list "$skipped_file"
  printf '%s' "非物理或无 device 的接口: "
  print_name_list "$virt_file"
  collect_rdma
}

find_mthreads_gmi() {
  local candidate="" found="" dir=""
  local -a roots=()
  candidate=$(resolve_bin mthreads-gmi || true)
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in \
    /usr/bin/mthreads-gmi \
    /usr/local/bin/mthreads-gmi \
    /usr/local/musa/bin/mthreads-gmi \
    /opt/musa/bin/mthreads-gmi \
    /opt/mthreads/bin/mthreads-gmi \
    /usr/local/mtgpu/bin/mthreads-gmi \
    /opt/mtgpu/bin/mthreads-gmi
  do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if ! type -P find >/dev/null 2>&1; then
    return 1
  fi
  # maxdepth 4 能覆盖 /usr/local/musa/bin/mthreads-gmi 这类路径
  for dir in /usr /opt; do
    if [[ -d "$dir" ]]; then
      roots+=("$dir")
    fi
  done
  if [[ ${#roots[@]} -eq 0 ]]; then
    return 1
  fi
  if type -P timeout >/dev/null 2>&1; then
    found=$(timeout 30 find "${roots[@]}" -maxdepth 4 -type f -name mthreads-gmi -print -quit 2>/dev/null || true)
  else
    found=$(find "${roots[@]}" -maxdepth 4 -type f -name mthreads-gmi -print -quit 2>/dev/null || true)
  fi
  if [[ -n "$found" && -x "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

parse_driver_version() {
  awk '
    /[Dd]river [Vv]ersion/ {
      line = $0
      sub(/.*[Dd]river [Vv]ersion[^:]*:[[:space:]]*/, "", line)
      gsub(/\|/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      sub(/[[:space:]].*/, "", line)
      if (line != "") {
        print line
        exit
      }
    }
  ' "$1"
}

find_musa_info() {
  local candidate="" found=""
  candidate=$(resolve_bin musaInfo || true)
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in /usr/local/musa/bin/musaInfo /opt/musa/bin/musaInfo /usr/local/bin/musaInfo; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if [[ -d /usr/local/musa ]] && type -P find >/dev/null 2>&1; then
    if type -P timeout >/dev/null 2>&1; then
      found=$(timeout 30 find /usr/local/musa -maxdepth 3 -type f -name musaInfo -print -quit 2>/dev/null || true)
    else
      found=$(find /usr/local/musa -maxdepth 3 -type f -name musaInfo -print -quit 2>/dev/null || true)
    fi
    if [[ -n "$found" && -x "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  fi
  return 1
}

collect_musa() {
  local info="" vfile="" bytes="" count=0 chunk=""
  local -a mccl=()
  printf '\n----- MUSA / musaInfo / libmccl -----\n'
  info=$(find_musa_info || true)
  if [[ -z "$info" ]]; then
    printf '%s\n' "未找到 musaInfo"
  else
    printf 'musaInfo 路径: %s\n' "$info"
    run_show "musaInfo" "$info"
  fi
  if [[ ! -d /usr/local/musa ]]; then
    printf '%s\n' "未找到目录 /usr/local/musa"
  elif ! type -P find >/dev/null 2>&1; then
    printf '%s\n' "未安装: find，跳过 /usr/local/musa 版本文件搜索"
  else
    printf '%s\n' "MUSA 目录: /usr/local/musa"
    while IFS= read -r vfile; do
      [[ -z "$vfile" ]] && continue
      count=$((count + 1))
      if [[ "$count" -gt 40 ]]; then
        printf '%s\n' "版本文件超过 40 个，其余已省略。"
        break
      fi
      printf '----- 版本文件: %s -----\n' "$vfile"
      if [[ ! -r "$vfile" ]]; then
        printf '%s\n' "(不可读，跳过内容)"
        continue
      fi
      bytes=$(wc -c <"$vfile" | tr -d '[:space:]' || true)
      chunk="${WORKDIR}/ver.chunk"
      head -c 65536 "$vfile" >"$chunk" 2>/dev/null || true
      if grep -q $'\0' "$chunk" 2>/dev/null; then
        printf '%s\n' "(二进制文件，跳过内容)"
      elif [[ "${bytes:-0}" -gt 65536 ]]; then
        printf '%s\n' "(文件超过 64KB，仅显示前 40 行)"
        awk 'NR<=40 { print }' "$chunk"
      else
        cat "$vfile"
      fi
    done < <(find /usr/local/musa -maxdepth 3 \( -type f -o -type l \) \( -iname 'version' -o -iname 'version.txt' -o -iname 'VERSION' -o -iname '*_version.h' -o -iname '*version*.txt' -o -iname 'musa_version*' \) 2>/dev/null || true)
    if [[ "$count" -eq 0 ]]; then
      printf '%s\n' "未找到 /usr/local/musa 下的版本文件"
    fi
  fi

  printf '\n----- libmccl -----\n'
  mapfile -t mccl < <(
    shopt -s nullglob
    for p in /usr/local/musa/lib/libmccl.so* /usr/local/musa/lib64/libmccl.so*; do
      if [[ -e "$p" || -L "$p" ]]; then
        printf '%s\n' "$p"
      fi
    done | sort
  )
  if [[ ${#mccl[@]} -eq 0 ]]; then
    printf '%s\n' "未找到 /usr/local/musa/lib/libmccl.so*（lib64 下也没有）"
  else
    ls -l "${mccl[@]}"
  fi
  return 0
}

collect_gpu() {
  local gmi="" raw="" ver="" gpu_count=0
  local mod_bin="" lsmod_bin="" mod_file="" lsmod_file="" rc=0
  section "6. GPU"
  printf '%s\n' "查找 mthreads-gmi（PATH 与常见安装路径）。"
  gmi=$(find_mthreads_gmi || true)
  if [[ -z "$gmi" ]]; then
    printf '%s\n' "未找到 mthreads-gmi"
    printf '%s\n' "未安装摩尔线程驱动或当前环境没有 GPU 时，这是预期结果。下面仍尝试采集 PCI 与内核模块信息。"
  else
    printf 'mthreads-gmi 路径: %s\n' "$gmi"
    run_show "mthreads-gmi" "$gmi"
    printf '\n----- Driver Version（来自 mthreads-gmi 摘要） -----\n'
    raw=$(grep -i -m 1 'Driver Version' "${WORKDIR}/cmd.out" || true)
    ver=$(parse_driver_version "${WORKDIR}/cmd.out" || true)
    if [[ -n "$raw" ]]; then
      printf '原始行: %s\n' "$raw"
    else
      printf '%s\n' "输出中未找到 Driver Version 行"
    fi
    if [[ -n "$ver" ]]; then
      printf '驱动版本: %s\n' "$ver"
    fi
    run_show "mthreads-gmi -v" "$gmi" -v
    run_show "mthreads-gmi -q" "$gmi" -q
    printf '\n%s\n' "说明: topo -m 的矩阵表示 GPU 之间如何互联，用于区分 MTLink 与 PCIe。mtlink -s 显示 MTLink 链路状态。"
    run_show "mthreads-gmi topo -m" "$gmi" topo -m
    run_show "mthreads-gmi mtlink -s" "$gmi" mtlink -s
  fi

  printf '\n----- lspci GPU / VGA / 摩尔线程 -----\n'
  printf '%s\n' "匹配 Moore Threads、厂商号 1ed5、3D/VGA/Display，以及 Processing accelerators（类码 1200）。"
  if show_lspci_status; then
    gpu_count=$(grep -Eic 'moore|mthreads|1ed5|3d controller|vga|display|processing accelerator|\[1200\]|\[0300\]|\[0302\]' "$LSPI_FILE" || true)
    if [[ "${gpu_count:-0}" -eq 0 ]]; then
      printf '%s\n' "未匹配到 GPU / VGA / 摩尔线程 PCI 设备"
    else
      printf '匹配行数: %s\n' "$gpu_count"
      grep -Ei 'moore|mthreads|1ed5|3d controller|vga|display|processing accelerator|\[1200\]|\[0300\]|\[0302\]' "$LSPI_FILE"
    fi
  fi

  printf '\n----- modinfo mtgpu -----\n'
  mod_bin=$(resolve_bin modinfo || true)
  if [[ -z "$mod_bin" ]]; then
    printf '%s\n' "未安装: modinfo"
  else
    mod_file="${WORKDIR}/modinfo.txt"
    run_to_file "$mod_file" "$mod_bin" mtgpu
    cat "$mod_file"
    if [[ "$CAP_RC" -ne 0 ]]; then
      printf '未找到内核模块 mtgpu，或 modinfo 执行失败（退出码 %s）。驱动未安装时这是预期结果。\n' "$CAP_RC"
    fi
  fi

  printf '\n----- /sys/module/mtgpu -----\n'
  if [[ -d /sys/module/mtgpu ]]; then
    printf '%s\n' "已发现 /sys/module/mtgpu"
    if [[ -r /sys/module/mtgpu/version ]]; then
      printf 'version: %s\n' "$(read_one_line /sys/module/mtgpu/version)"
    else
      printf '%s\n' "无 version 文件"
    fi
  else
    printf '%s\n' "未发现 /sys/module/mtgpu（模块未加载或不存在）"
  fi

  printf '\n----- lsmod | grep -i mt -----\n'
  printf '%s\n' "说明: 名称中含 mt 的已加载模块不一定都属于摩尔线程。"
  lsmod_bin=$(resolve_bin lsmod || true)
  if [[ -z "$lsmod_bin" ]]; then
    printf '%s\n' "未安装: lsmod"
  else
    lsmod_file="${WORKDIR}/lsmod.txt"
    rc=0
    if type -P timeout >/dev/null 2>&1; then
      timeout 30 "$lsmod_bin" >"$lsmod_file" 2>"${lsmod_file}.err" || rc=$?
    else
      "$lsmod_bin" >"$lsmod_file" 2>"${lsmod_file}.err" || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
      printf 'lsmod 执行失败，退出码 %s。\n' "$rc"
      if [[ -s "${lsmod_file}.err" ]]; then
        cat "${lsmod_file}.err"
      fi
    elif ! grep -i mt "$lsmod_file"; then
      printf '%s\n' "未匹配到名称含 mt 的已加载模块"
    fi
    if [[ "$rc" -eq 0 ]] && awk 'NR>1 && $1=="mtgpu" { found=1 } END { exit (found ? 0 : 1) }' "$lsmod_file"; then
      printf '%s\n' "mtgpu 模块: 已加载"
    elif [[ "$rc" -eq 0 ]]; then
      printf '%s\n' "mtgpu 模块: 未加载"
    fi
  fi

  collect_musa
  return 0
}

collect_end() {
  local now=""
  section "7. 采集结束与报告路径"
  now=$(date '+%F %T %z' 2>/dev/null || printf '%s' "未知")
  printf '结束时间: %s\n' "$now"
  if [[ -n "$OUTFILE_ABS" ]]; then
    printf '报告路径: %s\n' "$OUTFILE_ABS"
  else
    printf '%s\n' "报告路径: 仅标准输出（未能创建报告文件）"
  fi
  printf '%s\n' "采集结束。"
  return 0
}

main() {
  collect_overview
  collect_os
  collect_cpu
  collect_memory
  collect_nics
  collect_gpu
  collect_end
  return 0
}

init_workdir
init_outfile

rc_main=0
rc_tee=0
if [[ -n "$OUTFILE" ]] && type -P tee >/dev/null 2>&1; then
  main 2>&1 | tee "$OUTFILE"
  # 必须立刻复制。下一条赋值会覆盖 PIPESTATUS，不能分两次读取。
  pipe_status=("${PIPESTATUS[@]}")
  rc_main=${pipe_status[0]:-1}
  rc_tee=${pipe_status[1]:-0}
elif [[ -n "$OUTFILE" ]]; then
  printf '%s\n' "未安装: tee，先写入报告文件再打印到标准输出。" >&2
  main >"$OUTFILE" 2>&1
  rc_main=$?
  cat "$OUTFILE"
else
  main
  rc_main=$?
fi

if [[ "$rc_main" -ne 0 ]]; then
  exit "$rc_main"
fi
exit "$rc_tee"
