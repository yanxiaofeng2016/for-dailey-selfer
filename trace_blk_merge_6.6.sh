#!/usr/bin/env bash
# trace_blk_merge_6.6.sh -- Linux 6.6: trace plug merge vs mq-deadline scheduler merge
#
# Plug: blk_attempt_plug_merge (per-thread plug list).
# Scheduler: blk_mq_sched_bio_merge -> dd_bio_merge (mq-deadline).
#
# Needs: perf (recommended); optional bpftrace / trace-cmd.
#
# Examples:
#   TRACE_SECONDS=30 sudo ./trace_blk_merge_6.6.sh perf-merge-events
#   sudo ./trace_blk_merge_6.6.sh bpftrace-merge
#   ./trace_blk_merge_6.6.sh show-symbols
#
# NOTE: Every header line MUST start with "#". If bash reports "command not found"
# on Chinese/English words from line 2+, your copy lost the "#" or has UTF-16 BOM.
#
set -euo pipefail

DURATION="${TRACE_SECONDS:-15}"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "请用 root 运行: sudo $0 ..."; }

check_bins() {
  local missing=()
  for b in "$@"; do command -v "$b" >/dev/null 2>&1 || missing+=("$b"); done
  [[ ${#missing[@]} -eq 0 ]] || die "缺少命令: ${missing[*]}"
}

show_symbols() {
  echo "=== /proc/kallsyms 中与 merge 相关的常用符号（T/t 表示在 vmlinux 里）==="
  grep -E 'blk_attempt_plug_merge|blk_mq_sched_bio_merge|dd_bio_merge|dd_request_merge|blk_mq_submit_bio' /proc/kallsyms 2>/dev/null | head -30 || die "无法读 kallsyms"
}

perf_merge_events() {
  check_bins perf
  need_root
  echo ">>> ${DURATION}s: 录制 block_bio_backmerge / block_bio_frontmerge + 调用栈"
  echo ">>> 读栈：若栈顶附近出现 blk_attempt_plug_merge —— 多为 plug；"
  echo ">>> 若主要经 dd_bio_merge / blk_mq_sched_bio_merge —— 调度器路径。"
  perf record -a -g --call-graph fp,dwarf -e block:block_bio_backmerge -e block:block_bio_frontmerge \
    -- sleep "$DURATION"
  echo ""
  echo ">>> 以下片段摘自 perf script（完整见 perf report）"
  perf script 2>/dev/null | head -120 || true
  echo ""
  echo ">>> 交互分析: perf report    或折叠栈: perf report --children -G folded"
}

perf_probe_howto() {
  cat <<'EOF'
=== 可选：用 kprobe 精确盯两个函数（6.6 通用）===

1) 查看函数是否可探针（需 root）:
   sudo perf probe -v blk_mq_sched_bio_merge
   sudo perf probe -v blk_attempt_plug_merge

2) 添加（若未存在）:
   sudo perf probe -a blk_attempt_plug_merge
   sudo perf probe -a blk_mq_sched_bio_merge

3) 录制:
   sudo perf record -a -g -e probe:blk_attempt_plug_merge -e probe:blk_mq_sched_bio_merge -- sleep 15

4) 用完删除:
   sudo perf probe -d '*'
EOF
}

perf_probe_record() {
  check_bins perf
  need_root
  if ! perf probe -l 2>/dev/null | grep -q 'probe:blk_attempt_plug_merge'; then
    perf probe -a blk_attempt_plug_merge 2>/dev/null || echo "WARN: blk_attempt_plug_merge 探针添加失败，执行子命令 probes 查看说明"
  fi
  if ! perf probe -l 2>/dev/null | grep -q 'probe:blk_mq_sched_bio_merge'; then
    perf probe -a blk_mq_sched_bio_merge 2>/dev/null || echo "WARN: blk_mq_sched_bio_merge 探针添加失败"
  fi
  echo ">>> ${DURATION}s: perf probe 事件（若上面失败则无数据）"
  perf record -a -g --call-graph fp,dwarf \
    -e probe:blk_attempt_plug_merge -e probe:blk_mq_sched_bio_merge \
    -- sleep "$DURATION" || die "perf record 失败；请运行: $0 perf-probe-help"
  perf script | head -80 || true
  echo ">>> perf report"
}

bpftrace_merge() {
  check_bins bpftrace
  need_root
  echo ">>> bpftrace: 统计 blk_attempt_plug_merge / blk_mq_sched_bio_merge 调用次数（${DURATION}s）"
  # 兼容有无 BTF 的路径
  bpftrace <<BPF
kprobe:blk_attempt_plug_merge { @plug[comm] = count(); }
kprobe:blk_mq_sched_bio_merge { @sched[comm] = count(); }
interval:s:${DURATION} { exit(); }
END {
  print(@plug);
  print(@sched);
}
BPF
}

tracecmd_hint() {
  cat <<'EOF'
=== trace-cmd（可选，开销大）===

若内核开启 FUNCTION_GRAPH：
  sudo trace-cmd reset
  sudo trace-cmd record -p function_graph \\
    -l blk_mq_submit_bio -l blk_attempt_plug_merge -l blk_mq_sched_bio_merge \\
    -o trace.dat -- sleep 15
  sudo trace-cmd report -i trace.dat | less

若提示未启用 graph：请换用本脚本的 perf-merge-events。
EOF
}

usage() {
  echo "trace_blk_merge_6.6.sh -- Linux 6.6 block merge tracing (plug vs mq-deadline)"
  echo ""
  echo "子命令:"
  echo "  show-symbols       列出 kallsyms 中的 merge 相关符号"
  echo "  perf-merge-events  perf + block tracepoint（推荐先做）"
  echo "  perf-probe-help    打印 perf probe 分步命令"
  echo "  perf-probe-record  自动 add probe 并 record（可能因内核裁剪失败）"
  echo "  bpftrace-merge     bpftrace 粗计数两路 merge 入口"
  echo "  tracecmd-hint      打印 trace-cmd 用法"
}

case "${1:-}" in
  show-symbols) show_symbols ;;
  perf-merge-events) perf_merge_events ;;
  perf-probe-help) perf_probe_howto ;;
  perf-probe-record) perf_probe_record ;;
  bpftrace-merge) bpftrace_merge ;;
  tracecmd-hint) tracecmd_hint ;;
  "") usage ;;
  *) usage; exit 1 ;;
esac
