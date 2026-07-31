#!/usr/bin/env bash
# 30_mem_tests.sh — 内存能力层测试（MEM-00~07），规范见 PART1_TEST_SPEC.md §3
# 用法: sudo ROOT_DIR=~/cpu_test PLATFORM_ID=intel-6966p bash 30_mem_tests.sh [MEM-01 ...]
# 说明: MEM-00 抽样大小用 MEMTEST_GB 覆盖（默认 100，每 NUMA 节点各测一份）；
#       大内存机器全量检查不现实，抽样 + EDAC/ECC 计数核对（V0.2 修订）。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_linux
require_tool stream lat_mem_rd sysbench memtester numactl jq || exit 1
check_governor || exit 1
PIN=$(pick_pin_core)
NODES=$(numactl --hardware | awk '/available:/{print $2}')
HAS_MLC=0; command -v mlc >/dev/null && HAS_MLC=1
echo "绑核目标: core $PIN；NUMA 节点数: $NODES；MLC: $([[ $HAS_MLC == 1 ]] && echo 可用 || echo 不可用)"

mem00() {  # 内存正确性抽样（每节点 MEMTEST_GB，1 轮全模式）+ ECC 计数前后对比
    local GB="${MEMTEST_GB:-100}"
    mkdir -p "$RESULTS_DIR/MEM-00"
    edac-util --report=full > "$RESULTS_DIR/MEM-00/edac_before.txt" 2>&1 || true
    for (( n=0; n<NODES; n++ )); do
        WARMUP=0 RUNS=1 run_case "MEM-00-node$n" 1 parse_memtester \
            -- numactl --membind="$n" memtester "${GB}G" 1
    done
    edac-util --report=full > "$RESULTS_DIR/MEM-00/edac_after.txt" 2>&1 || true
    if ! diff -q "$RESULTS_DIR/MEM-00/edac_before.txt" "$RESULTS_DIR/MEM-00/edac_after.txt" >/dev/null 2>&1; then
        echo "!!! EDAC 计数发生变化，检查 MEM-00/edac_*.txt——内存可能有硬件问题"
    fi
}

mem01() {  # 顺序带宽：单线程（跨平台以 Triad 为准）
    run_case MEM-01-t1 1 parse_stream_triad \
        -- env OMP_NUM_THREADS=1 OMP_PROC_BIND=true stream
}

mem02() {  # 缓存/内存延迟阶梯：lat_mem_rd 全曲线（通用）+ MLC idle latency（x86）
    RUNS=$LONG_RUNS run_case MEM-02-ladder 1 parse_lat_mem_tail \
        -- taskset -c "$PIN" lat_mem_rd 2048 128
    (( HAS_MLC )) && WARMUP=1 run_case MEM-02-mlc-idle 1 parse_none -- mlc --idle_latency
}

mem03() {  # NUMA 延迟矩阵（多路必测）
    (( NODES < 2 )) && { echo "单 NUMA 节点，跳过 MEM-03"; return 0; }
    (( HAS_MLC )) && WARMUP=1 RUNS=$LONG_RUNS run_case MEM-03-latmatrix 1 parse_none \
        -- mlc --latency_matrix
    # 通用交叉验证：lat_mem_rd 在 节点绑定 组合下的 DRAM 段延迟
    for (( i=0; i<NODES; i++ )); do for (( j=0; j<NODES; j++ )); do
        WARMUP=1 RUNS=$LONG_RUNS run_case "MEM-03-lmr-c${i}m${j}" 1 parse_lat_mem_tail \
            -- numactl --cpunodebind="$i" --membind="$j" lat_mem_rd 2048 128
    done; done
}

mem04() {  # NUMA 带宽矩阵与峰值带宽
    (( NODES < 2 )) && { echo "单 NUMA 节点，跳过 MEM-04"; return 0; }
    if (( HAS_MLC )); then
        WARMUP=1 RUNS=$LONG_RUNS run_case MEM-04-bwmatrix 1 parse_none -- mlc --bandwidth_matrix
        WARMUP=1 RUNS=$LONG_RUNS run_case MEM-04-peak 1 parse_none -- mlc --peak_injection_bandwidth
    fi
    for (( i=0; i<NODES; i++ )); do for (( j=0; j<NODES; j++ )); do
        run_case "MEM-04-stream-c${i}m${j}" 1 parse_stream_triad \
            -- env OMP_NUM_THREADS=1 OMP_PROC_BIND=true \
               numactl --cpunodebind="$i" --membind="$j" stream
    done; done
}

mem05() {  # 负载下延迟（带宽-延迟曲线，高并发表现的关键指标；MRDIMM 主战场）
    (( HAS_MLC )) || { echo "无 MLC，MEM-05 缺项（记录到报告）"; return 0; }
    WARMUP=1 RUNS=$LONG_RUNS run_case MEM-05-loaded 1 parse_none -- mlc --loaded_latency
}

mem06() {  # 多线程带宽扩展：1,2,4,...,物理核
    local phys T=1; phys=$(nproc_physical)
    while (( T <= phys )); do
        run_case "MEM-06-t$T" "$T" parse_stream_triad \
            -- env OMP_NUM_THREADS="$T" OMP_PROC_BIND=spread stream
        (( T *= 2 ))
    done
    (( T/2 != phys )) && run_case "MEM-06-t$phys" "$phys" parse_stream_triad \
        -- env OMP_NUM_THREADS="$phys" OMP_PROC_BIND=spread stream
}

mem07() {  # 随机访问（指针追逐类负载，与 MEM-02 DRAM 段互相印证）
    run_case MEM-07-rnd 1 parse_sysbench_mem \
        -- taskset -c "$PIN" sysbench memory --memory-access-mode=rnd \
           --memory-block-size=8 --memory-total-size=8G --threads=1 run
}

ALL=(mem00 mem01 mem02 mem06 mem07 mem03 mem04 mem05)
if (( $# )); then
    for t in "$@"; do fn=$(echo "${t,,}" | tr -d '-'); $fn; done
else
    check_idle || exit 1
    for fn in "${ALL[@]}"; do $fn; done
fi
echo "MEM 层完成，记录在 $RESULTS_DIR/MEM-*/records.jsonl"
