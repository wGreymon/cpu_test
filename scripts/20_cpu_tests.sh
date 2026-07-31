#!/usr/bin/env bash
# 20_cpu_tests.sh — CPU 计算及持续性能测试（CPU-01~09），规范见 PART1_TEST_SPEC.md §2/§4
# 用法: sudo PLATFORM_ID=intel-6966p SESSION_ID=<批次> bash 20_cpu_tests.sh [CPU-01 ...]
# 说明: CPU-03（浮点/SIMD）为可选低优先级项不在此处；CPU-07（SPEC/Geekbench）授权未定，单独处理。
#       CPU-08 时长用 STRESS_MIN 覆盖（默认 60 分钟）；CPU-09 随 CPU-02/08 自动采功耗。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
CV_LIMIT=3

require_linux
require_tool jq lscpu taskset mpstat || exit 1
check_governor || exit 1
PIN=$(pick_pin_core) || exit 1
SILESIA="$ROOT_DIR/workloads/silesia.tar"
SILESIA_SHA="5f6103f1cff22287f378f52c36c4ba9fb1fc2865edf6e0ab4206913dee65a6d6"
echo "绑核目标: core $PIN"
check_idle || exit 1

# ---- 整机功耗采样（CPU-09）：每 5 秒读一次 BMC，CSV: epoch,power_w ----
POWER_PID=""
TURBO_PID=""
read_power_w() {
    ipmitool dcmi power reading 2>/dev/null \
        | awk '/Instantaneous power reading/ {
            for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+([.][0-9]+)?$/) {print $i; exit}
          }'
}
power_start() {
    local out="$1"
    require_tool ipmitool || return 1
    local first
    first=$(read_power_w)
    is_number "${first:-}" || {
        echo "ERROR: BMC 未返回有效的 DCMI Instantaneous power reading" >&2
        return 1
    }
    printf 'epoch,power_w\n%s,%s\n' "$(date +%s)" "$first" > "$out"
    ( while :; do
        sleep 5
        local value
        value=$(read_power_w)
        is_number "${value:-}" && printf '%s,%s\n' "$(date +%s)" "$value"
      done ) >> "$out" 2>/dev/null &
    POWER_PID=$!
}
power_stop() {
    if [[ -n "$POWER_PID" ]]; then
        kill "$POWER_PID" 2>/dev/null || true
        wait "$POWER_PID" 2>/dev/null || true
        POWER_PID=""
    fi
}
power_validate() {
    local file="$1" minimum="${2:-1}" count
    count=$(awk -F, 'NR>1 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+([.][0-9]+)?$/ {n++} END {print n+0}' "$file" 2>/dev/null)
    if (( count < minimum )); then
        echo "ERROR: 功耗文件有效样本不足（$count < $minimum）：$file" >&2
        return 1
    fi
}
turbo_stop() {
    if [[ -n "$TURBO_PID" ]]; then
        kill "$TURBO_PID" 2>/dev/null || true
        wait "$TURBO_PID" 2>/dev/null || true
        TURBO_PID=""
    fi
}
cleanup_monitors() { power_stop; turbo_stop; }

cpu01() {  # 单线程标量/通用计算
    require_tool sysbench 7zz || return 1
    run_case CPU-01-sysbench 1 parse_sysbench_eps \
        -- taskset -c "$PIN" sysbench cpu --cpu-max-prime=20000 --threads=1 --time=30 run
    run_case CPU-01-7zip 1 parse_7z_mips -- taskset -c "$PIN" 7zz b -mmt1
}

cpu02() {  # 多线程通用计算与扩展性（满物理核档另跑独立功耗轮 → CPU-09）
    require_tool sysbench 7zz || return 1
    local phys case_ok; phys=$(nproc_physical)
    for N in $(thread_ladder); do
        case_ok=1
        run_case "CPU-02-sysbench-t$N" "$N" parse_sysbench_eps \
            -- sysbench cpu --cpu-max-prime=20000 --threads="$N" --time=30 run || case_ok=0
        if [[ "$N" == "$phys" && "$case_ok" == "1" ]]; then
            # 能效使用独立运行，避免把预热、5 次正式运行和 perf profiling
            # 混入同一功耗窗口。主性能成绩仍来自上面的 run_case。
            mkdir -p "$RESULTS_DIR/CPU-09"
            if power_start "$RESULTS_DIR/CPU-09/power_cpu02.csv"; then
                printf 'start_epoch=%s\n' "$(date +%s)" \
                    > "$RESULTS_DIR/CPU-09/power_cpu02_window.txt"
                sysbench cpu --cpu-max-prime=20000 --threads="$N" --time=30 run \
                    > "$RESULTS_DIR/CPU-09/cpu02_power_run.out" 2>&1
                local power_ec=$?
                printf 'end_epoch=%s\n' "$(date +%s)" \
                    >> "$RESULTS_DIR/CPU-09/power_cpu02_window.txt"
                power_stop
                power_validate "$RESULTS_DIR/CPU-09/power_cpu02.csv" 2 || power_ec=1
                if (( power_ec != 0 )); then
                    echo "ERROR: CPU-02 独立功耗轮失败（exit=$power_ec）" >&2
                    RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
                fi
            else
                echo "ERROR: CPU-02 性能成绩有效，但 CPU-09 缺少满物理核整机功耗" >&2
                RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
            fi
        fi
        run_case "CPU-02-7zip-t$N" "$N" parse_7z_mips -- 7zz b -mmt"$N"
    done
}

cpu04() {  # 压缩/解压（固定数据集；单线程同参数压缩率应一致）
    require_tool zstd || return 1
    [[ -f "$SILESIA" ]] || { echo "缺 silesia.tar"; return 1; }
    echo "$SILESIA_SHA  $SILESIA" | sha256sum -c --quiet - 2>/dev/null \
        || { echo "ERROR: Silesia SHA-256 不符合规范" >&2; return 1; }
    local phys; phys=$(nproc_physical)
    run_case CPU-04-zstd3-t1 1 parse_zstd_bench \
        -- taskset -c "$PIN" zstd -b3 -T1 "$SILESIA"
    run_case CPU-04-zstd3-phys "$phys" parse_zstd_bench -- zstd -b3 -T"$phys" "$SILESIA"
    run_case CPU-04-zstd19-t1 1 parse_zstd_bench \
        -- taskset -c "$PIN" zstd -b19 -T1 "$SILESIA"
}

cpu05() {  # 加密/哈希（注意记录硬件加密指令启用情况，见 lscpu flags: aes / sha_ni）
    require_tool openssl || return 1
    run_case CPU-05-sha256 1 parse_openssl_last \
        -- taskset -c "$PIN" openssl speed -evp sha256
    run_case CPU-05-aesgcm 1 parse_openssl_last \
        -- taskset -c "$PIN" openssl speed -evp aes-256-gcm
    run_case CPU-05-rsa2048 1 parse_openssl_rsa -- taskset -c "$PIN" openssl speed rsa2048
    run_case CPU-05-aesgcm-multi "$(nproc)" parse_openssl_last \
        -- openssl speed -multi "$(nproc)" -evp aes-256-gcm
}

cpu06() {  # 核间通信延迟矩阵（本身即全对遍历，跑 1 遍，产出 CSV 供画热力图）
    require_tool core-to-core-latency || return 1
    mkdir -p "$RESULTS_DIR/CPU-06"
    NO_PROFILE=1 WARMUP=0 RUNS=1 run_case CPU-06-matrix 1 parse_none \
        -- bash -c "core-to-core-latency 5000 --csv > '$RESULTS_DIR/CPU-06/c2c_matrix.csv'"   # 防 profiling 轮覆盖矩阵
    if [[ ! -s "$RESULTS_DIR/CPU-06/c2c_matrix.csv" ]]; then
        echo "ERROR: CPU-06 核间延迟矩阵为空" >&2
        RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
        return 1
    fi
    echo "    矩阵: $RESULTS_DIR/CPU-06/c2c_matrix.csv"
}

cpu08() {  # 持续性能与降频（默认 60 分钟满核 + turbostat 每 10s 采样 + 整机功耗）
    require_tool stress-ng sysbench || return 1
    local MIN="${STRESS_MIN:-60}" status=0 stress_status=0 power_ok=0
    [[ "$MIN" =~ ^[0-9]+$ ]] && (( MIN > 0 )) \
        || { echo "ERROR: STRESS_MIN 必须是正整数（分钟）" >&2; return 1; }
    if [[ -e "$RESULTS_DIR/CPU-08-pre/records.jsonl" || \
          -e "$RESULTS_DIR/CPU-08-sustained/records.jsonl" || \
          -e "$RESULTS_DIR/CPU-08/turbostat.log" ]]; then
        echo "ERROR: CPU-08 本 session 已有结果，拒绝覆盖；请使用新的 SESSION_ID" >&2
        return 1
    fi
    local phys; phys=$(nproc_physical)
    mkdir -p "$RESULTS_DIR/CPU-08" "$RESULTS_DIR/CPU-09"

    # 压力前后各跑一次相同的短负载，得到可直接比较的吞吐下降比例。
    NO_PROFILE=1 WARMUP=1 RUNS=1 run_case CPU-08-pre "$phys" parse_sysbench_eps \
        -- sysbench cpu --cpu-max-prime=20000 --threads="$phys" --time=30 run \
        || return 1

    if require_tool turbostat; then
        turbostat --quiet --Summary --interval 10 --out "$RESULTS_DIR/CPU-08/turbostat.log" &
        TURBO_PID=$!
        sleep 1
        if ! kill -0 "$TURBO_PID" 2>/dev/null; then
            echo "ERROR: turbostat 启动失败，CPU-08 缺少频率/温度曲线" >&2
            wait "$TURBO_PID" 2>/dev/null || true
            TURBO_PID=""
            status=1
        fi
    else
        status=1
    fi
    if power_start "$RESULTS_DIR/CPU-09/power_cpu08.csv"; then
        power_ok=1
        printf 'start_epoch=%s\n' "$(date +%s)" \
            > "$RESULTS_DIR/CPU-09/power_cpu08_window.txt"
    else
        echo "ERROR: CPU-08 将继续造压，但本轮没有整机功耗数据" >&2
        status=1
    fi
    NO_PROFILE=1 WARMUP=0 RUNS=1 run_case CPU-08-sustained "$(nproc)" parse_stressng_bogo \
        -- stress-ng --cpu "$(nproc)" --cpu-method matrixprod --metrics-brief -t "${MIN}m" \
        || stress_status=$?
    if (( power_ok )); then
        printf 'end_epoch=%s\n' "$(date +%s)" \
            >> "$RESULTS_DIR/CPU-09/power_cpu08_window.txt"
    fi
    cleanup_monitors
    if (( power_ok )); then
        power_validate "$RESULTS_DIR/CPU-09/power_cpu08.csv" 2 || status=1
    fi
    if [[ ! -s "$RESULTS_DIR/CPU-08/turbostat.log" ]]; then
        echo "ERROR: turbostat 日志为空：$RESULTS_DIR/CPU-08/turbostat.log" >&2
        status=1
    fi

    NO_PROFILE=1 WARMUP=1 RUNS=1 run_case CPU-08-post "$phys" parse_sysbench_eps \
        -- sysbench cpu --cpu-max-prime=20000 --threads="$phys" --time=30 run \
        || status=1
    (( stress_status != 0 )) && status=1
    echo "    频率/温度曲线: CPU-08/turbostat.log；功耗: CPU-09/power_cpu08.csv"
    return "$status"
}

cpu09() {  # 空闲功耗单独采 5 分钟（负载功耗已随 CPU-02/08 采集）
    local seconds="${IDLE_POWER_SECONDS:-300}"
    local settle="${IDLE_SETTLE_SECONDS:-300}"
    [[ "$seconds" =~ ^[0-9]+$ ]] && (( seconds > 0 )) \
        || { echo "ERROR: IDLE_POWER_SECONDS 必须是正整数" >&2; return 1; }
    [[ "$settle" =~ ^[0-9]+$ ]] \
        || { echo "ERROR: IDLE_SETTLE_SECONDS 必须是非负整数" >&2; return 1; }
    mkdir -p "$RESULTS_DIR/CPU-09"
    if [[ -e "$RESULTS_DIR/CPU-09/power_idle.csv" ]]; then
        echo "ERROR: CPU-09 本 session 已有空闲功耗结果，拒绝覆盖；请使用新的 SESSION_ID" >&2
        return 1
    fi
    check_idle || return 1
    echo "=== [CPU-09] 先静置 ${settle} 秒，再采空闲功耗 ${seconds} 秒"
    sleep "$settle"
    power_start "$RESULTS_DIR/CPU-09/power_idle.csv" || return 1
    sleep "$seconds"
    power_stop
    power_validate "$RESULTS_DIR/CPU-09/power_idle.csv" 1 || return 1
    echo "    完成: CPU-09/power_idle.csv"
}

trap cleanup_monitors EXIT
trap 'cleanup_monitors; exit 130' INT
trap 'cleanup_monitors; exit 143' TERM
ALL=(cpu01 cpu02 cpu04 cpu05 cpu06 cpu09 cpu08)   # cpu08 一小时放最后
if (( $# )); then
    for t in "$@"; do
        fn=$(echo "${t,,}" | tr -d '-')
        run_test_function "$fn"
    done
else
    for fn in "${ALL[@]}"; do run_test_function "$fn"; done
fi
finish_test_layer "CPU 计算及持续性能测试" || exit 1
echo "记录在 $RESULTS_DIR/CPU-*/records.jsonl"
