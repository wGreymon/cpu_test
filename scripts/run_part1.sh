#!/usr/bin/env bash
# run_part1.sh — 第一部分全量执行总控（执行顺序按 PART1_TEST_SPEC.md §4）
# 用法: sudo ROOT_DIR=~/cpu_test bash run_part1.sh <platform_id>
# 预计总时长（不含 SPEC）: 约 1~1.5 个工作日；建议 tmux/screen 里跑并保留终端日志。
#
# 顺序设计：
#   MEM-00 门槛 → OS 微基准（机器最干净时）→ CPU 常规 → MEM 带宽/延迟
#   → NUMA 矩阵 → OS-01 综合 → OS-06 存储 → CPU-09 空闲功耗 → CPU-08 一小时持续（最后）
set -uo pipefail
PLATFORM_ID="${1:?用法: sudo ROOT_DIR=~/cpu_test bash run_part1.sh <platform_id>}"
export PLATFORM_ID ROOT_DIR="${ROOT_DIR:-$HOME/cpu_test}"
S="$(dirname "${BASH_SOURCE[0]}")"
LOG="$ROOT_DIR/results/raw/$PLATFORM_ID/run_part1_$(date +%Y%m%d_%H%M).log"
mkdir -p "$(dirname "$LOG")"

run() { echo -e "\n######## $* ########" ; bash "$@" || echo "!!! $* 非零退出，检查后可单独重跑该项"; }

{
    echo "开始: $(date -Iseconds)  平台: $PLATFORM_ID"

    # 0. 环境基线（幂等，重复跑覆盖更新）
    run "$S/02_prepare_state.sh" "$PLATFORM_ID"

    # 1. 内存正确性门槛
    run "$S/30_mem_tests.sh" MEM-00

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

    echo "全部完成: $(date -Iseconds)"
    echo "结果目录: $ROOT_DIR/results/raw/$PLATFORM_ID/"
} 2>&1 | tee "$LOG"
