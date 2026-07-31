#!/usr/bin/env bash
# 20_cpu_tests.sh — CPU 核心能力层测试（CPU-01~09），规范见 PART1_TEST_SPEC.md §2
# 用法: sudo ROOT_DIR=~/cpu_test PLATFORM_ID=intel-6966p bash 20_cpu_tests.sh [CPU-01 ...]
# 说明: CPU-03（浮点/SIMD）为可选低优先级项不在此处；CPU-07（SPEC/Geekbench）授权未定，单独处理。
#       CPU-08 时长用 STRESS_MIN 覆盖（默认 60 分钟）；CPU-09 随 CPU-02/08 自动采功耗。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_linux
require_tool sysbench 7zz zstd openssl core-to-core-latency stress-ng jq || exit 1
check_governor || exit 1
PIN=$(pick_pin_core)
SILESIA="$ROOT_DIR/workloads/silesia.tar"
echo "绑核目标: core $PIN"

# ---- 整机功耗采样（CPU-09）：每 5 秒读一次 BMC，csv: epoch,W ----
POWER_PID=""
power_start() {
    local out="$1"
    ( while :; do
        echo "$(date +%s),$(ipmitool dcmi power reading 2>/dev/null \
            | awk '/Instantaneous/{print $4}')"
        sleep 5
      done ) >> "$out" 2>/dev/null &
    POWER_PID=$!
}
power_stop() { [[ -n "$POWER_PID" ]] && kill "$POWER_PID" 2>/dev/null; POWER_PID=""; }

cpu01() {  # 单线程整数
    run_case CPU-01-sysbench 1 parse_sysbench_eps \
        -- taskset -c "$PIN" sysbench cpu --cpu-max-prime=20000 --threads=1 --time=30 run
    run_case CPU-01-7zip 1 parse_7z_mips -- taskset -c "$PIN" 7zz b -mmt1
}

cpu02() {  # 多线程整数与扩展性（满物理核档同步采功耗 → CPU-09）
    local phys; phys=$(nproc_physical)
    for N in $(thread_ladder); do
        if [[ "$N" == "$phys" ]]; then
            mkdir -p "$RESULTS_DIR/CPU-09"; power_start "$RESULTS_DIR/CPU-09/power_cpu02.csv"
        fi
        run_case "CPU-02-sysbench-t$N" "$N" parse_sysbench_eps \
            -- sysbench cpu --cpu-max-prime=20000 --threads="$N" --time=30 run
        [[ "$N" == "$phys" ]] && power_stop
        run_case "CPU-02-7zip-t$N" "$N" parse_7z_mips -- 7zz b -mmt"$N"
    done
}

cpu04() {  # 压缩/解压（固定数据集 Silesia，压缩率必须跨平台一致）
    [[ -f "$SILESIA" ]] || { echo "缺 silesia.tar"; return 1; }
    run_case CPU-04-zstd3-t1 1 parse_zstd_bench \
        -- taskset -c "$PIN" zstd -b3 -T1 "$SILESIA"
    run_case CPU-04-zstd3-all "$(nproc)" parse_zstd_bench -- zstd -b3 -T0 "$SILESIA"
    run_case CPU-04-zstd19-t1 1 parse_zstd_bench \
        -- taskset -c "$PIN" zstd -b19 -T1 "$SILESIA"
}

cpu05() {  # 加密/哈希（注意记录硬件加密指令启用情况，见 lscpu flags: aes / sha_ni）
    run_case CPU-05-sha256 1 parse_openssl_last \
        -- taskset -c "$PIN" openssl speed -evp sha256
    run_case CPU-05-aesgcm 1 parse_openssl_last \
        -- taskset -c "$PIN" openssl speed -evp aes-256-gcm
    run_case CPU-05-rsa2048 1 parse_none -- taskset -c "$PIN" openssl speed rsa2048
    run_case CPU-05-aesgcm-multi "$(nproc)" parse_none \
        -- openssl speed -multi "$(nproc)" -evp aes-256-gcm
}

cpu06() {  # 核间通信延迟矩阵（本身即全对遍历，跑 1 遍，产出 CSV 供画热力图）
    mkdir -p "$RESULTS_DIR/CPU-06"
    WARMUP=0 RUNS=1 run_case CPU-06-matrix 1 parse_none \
        -- bash -c "core-to-core-latency 5000 --csv > '$RESULTS_DIR/CPU-06/c2c_matrix.csv'"
    echo "    矩阵: $RESULTS_DIR/CPU-06/c2c_matrix.csv"
}

cpu08() {  # 持续性能与降频（默认 60 分钟满核 + turbostat 每 10s 采样 + 整机功耗）
    local MIN="${STRESS_MIN:-60}"
    mkdir -p "$RESULTS_DIR/CPU-08" "$RESULTS_DIR/CPU-09"
    turbostat --quiet --interval 10 --out "$RESULTS_DIR/CPU-08/turbostat.log" &
    local TPID=$!
    power_start "$RESULTS_DIR/CPU-09/power_cpu08.csv"
    WARMUP=0 RUNS=1 run_case CPU-08-sustained "$(nproc)" parse_stressng_bogo \
        -- stress-ng --cpu "$(nproc)" --cpu-method matrixprod --metrics-brief -t "${MIN}m"
    power_stop; kill "$TPID" 2>/dev/null
    echo "    频率/温度曲线: CPU-08/turbostat.log；功耗: CPU-09/power_cpu08.csv"
}

cpu09() {  # 空闲功耗单独采 5 分钟（负载功耗已随 CPU-02/08 采集）
    mkdir -p "$RESULTS_DIR/CPU-09"
    echo "=== [CPU-09] 空闲功耗采样 5 分钟（保持机器无负载）"
    power_start "$RESULTS_DIR/CPU-09/power_idle.csv"; sleep 300; power_stop
    echo "    完成: CPU-09/power_idle.csv"
}

trap power_stop EXIT
ALL=(cpu01 cpu02 cpu04 cpu05 cpu06 cpu09 cpu08)   # cpu08 一小时放最后
if (( $# )); then
    for t in "$@"; do fn=$(echo "${t,,}" | tr -d '-'); $fn; done
else
    check_idle || exit 1
    for fn in "${ALL[@]}"; do $fn; done
fi
echo "CPU 层完成，记录在 $RESULTS_DIR/CPU-*/records.jsonl"
