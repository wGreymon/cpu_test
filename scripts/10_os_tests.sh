#!/usr/bin/env bash
# 10_os_tests.sh — OS 能力及存储辅助测试（OS-01 ~ OS-06），规范见 PART1_TEST_SPEC.md §1/§3
# 用法: sudo PLATFORM_ID=intel-6966p SESSION_ID=<批次> bash 10_os_tests.sh [OS-02 OS-03 ...]
#       不带参数则按推荐顺序跑全部。UnixBench 次数可用 UNIXBENCH_RUNS 覆盖（默认 1）。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
CV_LIMIT=5

require_linux
require_tool jq lscpu taskset mpstat || exit 1
check_governor || exit 1
PIN=$(pick_pin_core) || exit 1
echo "绑核目标: core $PIN（中断最少）"
check_idle || exit 1
FIO_WORK_DIR=""
cleanup_fio() {
    if [[ -n "$FIO_WORK_DIR" && -d "$FIO_WORK_DIR" && "$(basename "$FIO_WORK_DIR")" == fio_tmp_* ]]; then
        find "$FIO_WORK_DIR" -depth -mindepth 1 -delete 2>/dev/null || true
        rmdir "$FIO_WORK_DIR" 2>/dev/null || true
        FIO_WORK_DIR=""
    fi
}
trap cleanup_fio EXIT
trap 'cleanup_fio; exit 130' INT
trap 'cleanup_fio; exit 143' TERM

os01single() {
    local UB="$ROOT_DIR/tools/src/byte-unixbench-5.1.3/UnixBench"
    [[ -x "$UB/Run" ]] || { echo "UnixBench 缺失"; return 1; }
    NO_PROFILE=1 WARMUP=0 RUNS="${UNIXBENCH_RUNS:-1}" run_case OS-01-single 1 parse_unixbench_index \
        -- bash -c "cd '$UB' && ./Run -c 1"
}

os01ncopy() {
    local UB="$ROOT_DIR/tools/src/byte-unixbench-5.1.3/UnixBench"
    local copies
    [[ -x "$UB/Run" ]] || { echo "UnixBench 缺失"; return 1; }
    # UnixBench 5.1.3 的 system 类每个子项 maxCopies=16；传入更大
    # -c 时套件会静默跳过所有子项并且仍返回 0。
    copies=$(nproc)
    (( copies > 16 )) && copies=16
    NO_PROFILE=1 WARMUP=0 RUNS="${UNIXBENCH_RUNS:-1}" run_case OS-01-ncopy "$copies" parse_unixbench_index \
        -- bash -c "cd '$UB' && ./Run -c $copies"
}

os01() {  # 系统综合基准（UnixBench 自带多轮迭代，默认整套只跑 1 遍）
    os01single
    os01ncopy
}

os02() {  # 系统调用延迟（-N 为 lmbench 内部重复轮数，5 轮足够，外层再跑 5 次）
    require_tool lat_syscall perf || return 1
    for op in null read write; do
        run_case "OS-02-$op" 1 parse_lat_syscall \
            -- taskset -c "$PIN" lat_syscall -N 5 "$op"
    done
    NO_PROFILE=1 run_case OS-02-perfbench 1 parse_perf_syscall \
        -- taskset -c "$PIN" perf bench syscall basic   # 避免 perf 套 perf
}

os03() {  # 进程创建
    require_tool lat_proc python3 || return 1
    for op in fork exec shell; do
        run_case "OS-03-$op" 1 parse_lat_generic \
            -- taskset -c "$PIN" lat_proc -N 5 "$op"
    done
    run_case OS-03-spawn1000 1 parse_spawn_p95 \
        -- taskset -c "$PIN" python3 "$ROOT_DIR/workloads/proc_spawn.py" 1000
}

os04() {  # 上下文切换：0KB 与 16KB 工作集 × 进程数梯度
    require_tool lat_ctx perf || return 1
    for np in 2 8 32; do
        run_case "OS-04-s0-p$np"  1 parse_lat_ctx -- taskset -c "$PIN" lat_ctx -N 5 -s 0 "$np"
        run_case "OS-04-s16-p$np" 1 parse_lat_ctx -- taskset -c "$PIN" lat_ctx -N 5 -s 16 "$np"
    done
    NO_PROFILE=1 run_case OS-04-perfpipe 1 parse_perf_sched \
        -- perf bench sched pipe -l 1000000   # 避免 perf 套 perf
}

os05() {  # 调度器压力：常规与过载两档
    require_tool hackbench || return 1
    run_case OS-05-g10 400  parse_hackbench_time -- hackbench -g 10 -l 2000
    run_case OS-05-g40 1600 parse_hackbench_time -- hackbench -g 40 -l 2000
}

os06() {  # 存储 I/O（辅助项，不参与平台排名）
    require_tool fio || return 1
    if [[ -e "$RESULTS_DIR/OS-06/storage_target.txt" || \
          -e "$RESULTS_DIR/OS-06-randread/records.jsonl" || \
          -e "$RESULTS_DIR/OS-06-seqread/records.jsonl" ]]; then
        echo "ERROR: OS-06 本 session 已有结果，拒绝覆盖；请使用新的 SESSION_ID" >&2
        return 1
    fi
    # 默认放在同步项目之外，避免 Mutagen/Git 等后台程序传输约 40GiB 测试文件并
    # 干扰 I/O 成绩。正式测试可用 FIO_DIR 指向两平台同类的独立数据盘挂载点。
    local base="${FIO_DIR:-/var/tmp/cpu_test_fio}"
    mkdir -p "$base"
    mkdir -p "$RESULTS_DIR/OS-06"
    findmnt -T "$base" > "$RESULTS_DIR/OS-06/storage_target.txt" 2>&1 || true
    df -hT "$base" >> "$RESULTS_DIR/OS-06/storage_target.txt" 2>&1 || true
    local min_free_gb="${FIO_MIN_FREE_GB:-45}" available required
    available=$(df -PB1 "$base" | awk 'NR==2 {print $4}')
    required=$(( min_free_gb * 1024 * 1024 * 1024 ))
    if [[ ! "$available" =~ ^[0-9]+$ ]] || (( available < required )); then
        echo "ERROR: OS-06 需要至少 ${min_free_gb}GiB 可用空间：$base" >&2
        return 1
    fi
    FIO_WORK_DIR=$(mktemp -d "$base/fio_tmp_${SESSION_ID}.XXXXXX") || return 1
    local D="$FIO_WORK_DIR"
    NO_PROFILE=1 run_case OS-06-randread 4 parse_fio_iops -- fio --name=randread --rw=randread \
        --bs=4k --iodepth=32 --ioengine=io_uring --direct=1 --size=8G --runtime=60 \
        --time_based --numjobs=4 --group_reporting --directory="$D" --output-format=json
    NO_PROFILE=1 run_case OS-06-seqread 1 parse_fio_bw -- fio --name=seqread --rw=read \
        --bs=1M --iodepth=8 --ioengine=io_uring --direct=1 --size=8G --runtime=60 \
        --time_based --directory="$D" --output-format=json
    cleanup_fio
}

# ---- 分发 ----
ALL=(os02 os03 os04 os05 os01 os06)   # 微基准在前（机器最干净时），综合与存储在后
if (( $# )); then
    for t in "$@"; do
        fn=$(echo "${t,,}" | tr -d '-')
        run_test_function "$fn"                    # OS-02 → os02
    done
else
    for fn in "${ALL[@]}"; do run_test_function "$fn"; done
fi
finish_test_layer "OS 能力测试" || exit 1
echo "记录在 $RESULTS_DIR/OS-*/records.jsonl"
