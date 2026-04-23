#!/usr/bin/env bash
# bpf_blk_merge_6.6.sh -- run bpf_blk_merge_6.6.bt (BPF/bpftrace)
#
# Env:
#   BPF_SECONDS   >0: stop after N seconds (SIGINT via timeout(1))
#   BPF_PID       optional PID filter (default 0 = all), same as bpftrace arg
#
# Examples:
#   sudo ./bpf_blk_merge_6.6.sh
#   sudo BPF_SECONDS=30 ./bpf_blk_merge_6.6.sh
#   sudo BPF_PID=$(pidof fio) BPF_SECONDS=60 ./bpf_blk_merge_6.6.sh
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BT="${BPFTRACE_BT:-$DIR/bpf_blk_merge_6.6.bt}"
SEC="${BPF_SECONDS:-0}"
PID_ARG="${BPF_PID:-0}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0"
command -v bpftrace >/dev/null 2>&1 || die "bpftrace not in PATH"
[[ -f "$BT" ]] || die "not found: $BT"

run_bt() {
  bpftrace "$BT" "$PID_ARG"
}

if [[ "$SEC" =~ ^[0-9]+$ ]] && [[ "$SEC" -gt 1 ]]; then
  command -v timeout >/dev/null 2>&1 || die "install coreutils (timeout) or unset BPF_SECONDS"
  exec timeout -s INT --preserve-status "${SEC}s" bpftrace "$BT" "$PID_ARG"
fi

exec bpftrace "$BT" "$PID_ARG"
