#!/usr/bin/env bash
# run_part1.sh — 第一部分全量执行总控（执行顺序按 PART1_TEST_SPEC.md §5）
# 用法: sudo bash run_part1.sh <platform_id>
# 预计总时长: 约 1 个工作日；建议 tmux/screen 里跑并保留终端日志。
#
# 失败控制：
#   门槛步骤（环境准备、MEM-00 内存正确性）失败 → 立即中止全量测试
#   普通测试失败 → 记录后继续，事后单独补测
set -uo pipefail
PLATFORM_ID="${1:?用法: sudo bash run_part1.sh <platform_id>}"

# 项目根目录按脚本位置推导（scripts/ 的上一级），不依赖 $HOME/sudo 环境
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR="${ROOT_DIR:-$(dirname "$S")}"
export PLATFORM_ID
export SESSION_ID="${SESSION_ID:-$(date +%Y%m%d_%H%M%S)_$$}" # 本批次唯一，三个执行脚本共用
[[ "$PLATFORM_ID" =~ ^[A-Za-z0-9._-]+$ && "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { echo "platform_id/session_id 只能包含字母、数字、点、下划线和连字符" >&2; exit 1; }
export PROFILE="${PROFILE:-1}"                              # 每项附加 perf stat profiling 轮
PART_FAILURES=0
trap 'echo "收到中断，停止本批次" >&2; exit 130' INT
trap 'echo "收到终止信号，停止本批次" >&2; exit 143' TERM

LOG="$ROOT_DIR/results/raw/$PLATFORM_ID/$SESSION_ID/run_part1.log"
mkdir -p "$(dirname "$LOG")"
if [[ -e "$LOG" ]]; then
    echo "FATAL: 本 session 已有总控日志，拒绝覆盖：$LOG（请使用新的 SESSION_ID）" >&2
    exit 2
fi

run()      {
    echo -e "\n######## $* ########"
    if ! bash "$@"; then
        echo "!!! $* 非零退出，记录后继续（可单独补测）"
        PART_FAILURES=$(( PART_FAILURES + 1 ))
    fi
}
run_gate() { echo -e "\n######## [门槛] $* ########"; bash "$@" || { echo "FATAL: 门槛步骤失败，中止全量测试"; exit 1; }; }

{
    echo "开始: $(date -Iseconds)  平台: $PLATFORM_ID  批次: $SESSION_ID"

    # 0. 环境基线（门槛：governor/空闲率不达标即中止）
    run_gate "$S/02_prepare_state.sh" "$PLATFORM_ID"

    # 1. 内存正确性（门槛：任何错误即中止）
    run_gate "$S/30_mem_tests.sh" MEM-00

    # 2. OS 微基准（系统调用/进程创建/上下文切换/调度）
    run "$S/10_os_tests.sh" OS-02 OS-03 OS-04 OS-05

    # 3. CPU 常规项
    run "$S/20_cpu_tests.sh" CPU-01 CPU-02 CPU-04 CPU-05 CPU-06

    # 4. 内存带宽/延迟 + NUMA 矩阵
    run "$S/30_mem_tests.sh" MEM-01 MEM-02 MEM-06 MEM-07
    run "$S/30_mem_tests.sh" MEM-03 MEM-04 MEM-05

    # 5. 综合基准与存储（辅助）
    run "$S/10_os_tests.sh" OS-01
    run "$S/10_os_tests.sh" OS-06

    # 6. 功耗与持续性能（一小时满载，放最后）
    run "$S/20_cpu_tests.sh" CPU-09
    run "$S/20_cpu_tests.sh" CPU-08

    if (( PART_FAILURES > 0 )); then
        echo "批次执行结束但不完整: $(date -Iseconds)；失败测试组数: $PART_FAILURES"
        echo "结果目录: $ROOT_DIR/results/raw/$PLATFORM_ID/$SESSION_ID/"
        exit 2
    fi
    echo "全部测试有效: $(date -Iseconds)"
    echo "结果目录: $ROOT_DIR/results/raw/$PLATFORM_ID/$SESSION_ID/"
} 2>&1 | tee "$LOG"
