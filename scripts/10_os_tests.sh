#!/usr/bin/env bash
# 10_os_tests.sh — 系统能力层测试（OS-01 ~ OS-06），规范见 PART1_TEST_SPEC.md §1
# 用法: sudo ROOT_DIR=~/cpu_test PLATFORM_ID=intel-6966p bash 10_os_tests.sh [OS-02 OS-03 ...]
#       不带参数则按推荐顺序跑全部。UnixBench 次数可用 UNIXBENCH_RUNS 覆盖（默认 1）。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_linux
require_tool lat_syscall lat_proc lat_ctx hackbench fio perf jq python3 || exit 1
check_governor || exit 1
PIN=$(pick_pin_core)
echo "绑核目标: core $PIN（中断最少）"

os01() {  # 系统综合基准（UnixBench 自带多轮迭代，默认整套只跑 1 遍）
    local UB="$ROOT_DIR/tools/src/byte-unixbench-5.1.3/UnixBench"
    [[ -x "$UB/Run" ]] || { echo "UnixBench 缺失"; return 1; }
    WARMUP=0 RUNS="${UNIXBENCH_RUNS:-1}" run_case OS-01-single 1 parse_unixbench_index \
        -- bash -c "cd '$UB' && ./Run -c 1"
    WARMUP=0 RUNS="${UNIXBENCH_RUNS:-1}" run_case OS-01-ncopy "$(nproc)" parse_unixbench_index \
        -- bash -c "cd '$UB' && ./Run -c $(nproc)"
}

os02() {  # 系统调用延迟
    for op in null read write; do
        run_case "OS-02-$op" 1 parse_lat_generic \
            -- taskset -c "$PIN" lat_syscall -N 100 "$op"
    done
    run_case OS-02-perfbench 1 parse_perf_syscall \
        -- taskset -c "$PIN" perf bench syscall basic
}

os03() {  # 进程/线程创建
    for op in fork exec shell; do
        run_case "OS-03-$op" 1 parse_lat_generic \
            -- taskset -c "$PIN" lat_proc -N 100 "$op"
    done
    run_case OS-03-spawn1000 1 parse_spawn_p95 \
        -- taskset -c "$PIN" python3 "$ROOT_DIR/workloads/proc_spawn.py" 1000
}

os04() {  # 上下文切换：0KB 与 16KB 工作集 × 进程数梯度
    for np in 2 8 32; do
        run_case "OS-04-s0-p$np"  1 parse_lat_ctx -- taskset -c "$PIN" lat_ctx -N 100 -s 0 "$np"
        run_case "OS-04-s16-p$np" 1 parse_lat_ctx -- taskset -c "$PIN" lat_ctx -N 100 -s 16 "$np"
    done
    run_case OS-04-perfpipe 1 parse_perf_sched \
        -- perf bench sched pipe -l 1000000
}

os05() {  # 调度器压力：常规与过载两档
    run_case OS-05-g10 400  parse_hackbench_time -- hackbench -g 10 -l 2000
    run_case OS-05-g40 1600 parse_hackbench_time -- hackbench -g 40 -l 2000
}

os06() {  # 存储 I/O（辅助项，不参与平台排名）
    local D="${FIO_DIR:-$ROOT_DIR/fio_tmp}"; mkdir -p "$D"
    run_case OS-06-randread 4 parse_fio_json -- fio --name=randread --rw=randread \
        --bs=4k --iodepth=32 --ioengine=io_uring --direct=1 --size=8G --runtime=60 \
        --time_based --numjobs=4 --group_reporting --directory="$D" --output-format=json
    run_case OS-06-seqread 1 parse_fio_json -- fio --name=seqread --rw=read \
        --bs=1M --iodepth=8 --ioengine=io_uring --direct=1 --size=8G --runtime=60 \
        --time_based --directory="$D" --output-format=json
    rm -rf "$D"
}

# ---- 分发 ----
ALL=(os02 os03 os04 os05 os01 os06)   # 微基准在前（机器最干净时），综合与存储在后
if (( $# )); then
    for t in "$@"; do fn=$(echo "${t,,}" | tr -d '-'); $fn; done   # OS-02 → os02
else
    check_idle || exit 1
    for fn in "${ALL[@]}"; do $fn; done
fi
echo "OS 层完成，记录在 $RESULTS_DIR/OS-*/records.jsonl"
