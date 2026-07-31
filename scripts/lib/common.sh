#!/usr/bin/env bash
# common.sh — 运行协议公共库（PART1_TEST_SPEC.md §0.2 / §0.3）
# 被 10_os_tests.sh / 20_cpu_tests.sh / 30_mem_tests.sh 引用，不单独执行。

set -u

# ---------- 全局配置（可用环境变量覆盖） ----------
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PLATFORM_ID="${PLATFORM_ID:-unknown-platform}"   # 必须由调用方指定，如 cpu-a
SANDBOX_TYPE="${SANDBOX_TYPE:-bare}"
WARMUP="${WARMUP:-2}"                            # 预热次数（§0.2）
RUNS="${RUNS:-5}"                                # 正式运行次数（§0.2）
LONG_RUNS="${LONG_RUNS:-3}"                      # >10min 用例的正式次数
PIN_CORE="${PIN_CORE:-}"                         # 单线程绑核编号，空则自动选择
RESULTS_DIR="$ROOT_DIR/results/raw/$PLATFORM_ID"
TOOLS_PREFIX="${TOOLS_PREFIX:-$ROOT_DIR/tools/bin}"
export PATH="$TOOLS_PREFIX:$PATH"

DATE_TAG="$(date +%Y%m%d)"

# ---------- 前置检查 ----------
require_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        echo "FATAL: 本脚本只能在 Linux 测试机上运行（当前: $(uname -s)）。" >&2
        echo "       本地 Mac 仅用于编写与语法检查，请部署到远程服务器执行。" >&2
        exit 1
    fi
}

require_tool() {
    local missing=0
    for t in "$@"; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "MISSING TOOL: $t（先运行 scripts/01_setup_tools.sh）" >&2
            missing=1
        fi
    done
    return $missing
}

# 选择绑核目标：避开中断最多的核（§0.2 第 3 条）
pick_pin_core() {
    if [[ -n "$PIN_CORE" ]]; then echo "$PIN_CORE"; return; fi
    # 统计 /proc/interrupts 每列（核）中断总数，取中断最少的在线核
    awk 'NR>1 {for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s[i-2]+=$i}
         END {min=-1; c=0; for(k in s) if(min<0 || s[k]<min){min=s[k]; c=k} print c}' /proc/interrupts
}

nproc_physical() {
    lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l
}

# 线程梯度：1、25%、50%、100% 物理核、全部逻辑核（§0.2 第 3 条）
thread_ladder() {
    local phys logical q h
    phys=$(nproc_physical); logical=$(nproc)
    q=$(( phys / 4 )); [[ $q -lt 1 ]] && q=1
    h=$(( phys / 2 )); [[ $h -lt 1 ]] && h=1
    printf '%s\n' 1 "$q" "$h" "$phys" "$logical" | sort -un
}

# 空闲基线检查：1 分钟平均空闲率需 >98%（§0.2 第 4 条）
check_idle() {
    local idle
    idle=$(mpstat 1 10 2>/dev/null | awk '/Average/ {print $NF}')
    if [[ -z "$idle" ]]; then
        echo "WARN: mpstat 不可用，跳过空闲检查" >&2; return 0
    fi
    if awk -v i="$idle" 'BEGIN{exit !(i < 98.0)}'; then
        echo "FATAL: CPU 空闲率 $idle% < 98%，存在干扰负载，中止测试。" >&2
        return 1
    fi
    echo "idle check OK: $idle%"
}

check_governor() {
    local g f="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    [[ -r "$f" ]] || { echo "WARN: 无法读取 governor（虚拟机？），请人工确认" >&2; return 0; }
    g=$(cat "$f")
    if [[ "$g" != "performance" ]]; then
        echo "FATAL: governor=$g，请先执行 cpupower frequency-set -g performance" >&2
        return 1
    fi
}

# ---------- 结果记录（方案 §9 JSON 格式） ----------
# emit_record <test_id> <iteration> <duration_ms> <metric_name> <metric_value> <unit> <threads> <exit_code> <raw_file> [notes]
emit_record() {
    local test_id="$1" iter="$2" dur="$3" mname="$4" mval="$5" unit="$6" \
          threads="$7" ec="$8" raw="$9" notes="${10:-}"
    local dir="$RESULTS_DIR/$test_id"
    mkdir -p "$dir"
    jq -nc \
        --arg run_id      "${DATE_TAG}-${PLATFORM_ID}-${SANDBOX_TYPE}-${test_id}-$(printf '%03d' "$iter")" \
        --arg timestamp   "$(date -Iseconds)" \
        --arg platform_id "$PLATFORM_ID" \
        --arg cpu_model   "$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')" \
        --arg os_kernel   "$(uname -sr)" \
        --arg mitigations "$(grep -h . /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null | sort -u | paste -sd';' -)" \
        --arg sandbox     "$SANDBOX_TYPE" \
        --arg test_id     "$test_id" \
        --argjson threads "${threads:-1}" \
        --argjson iter    "$iter" \
        --arg dur         "$dur" \
        --arg mname       "$mname" \
        --arg mval        "$mval" \
        --arg unit        "$unit" \
        --argjson ec      "${ec:-0}" \
        --arg raw         "$raw" \
        --arg notes       "$notes" \
        '{run_id:$run_id, timestamp:$timestamp, platform_id:$platform_id,
          cpu_model:$cpu_model, os_kernel:$os_kernel, mitigations:$mitigations,
          sandbox_type:$sandbox, test_id:$test_id, concurrency:$threads,
          iteration:$iter, duration_ms:($dur|tonumber? // null),
          metric:{name:$mname, value:($mval|tonumber? // null), unit:$unit},
          exit_code:$ec, correctness:(if $ec==0 then "pass" else "fail" end),
          raw_file:$raw, notes:$notes}' \
        >> "$dir/records.jsonl"
}

# ---------- 通用执行器 ----------
# run_case <test_id> <threads> <parser_fn> -- <cmd...>
#   预热 WARMUP 次（丢弃输出），正式 RUNS 次；
#   每次 stdout 存 results/raw/<platform>/<test_id>/iterN.out；
#   parser_fn 从 stdout 文件提取 "metric_name metric_value unit"（空格分隔一行）。
run_case() {
    local test_id="$1" threads="$2" parser="$3"; shift 3
    [[ "$1" == "--" ]] && shift
    local dir="$RESULTS_DIR/$test_id"
    mkdir -p "$dir"
    echo "=== [$test_id] threads=$threads  warmup=$WARMUP runs=$RUNS"
    echo "    cmd: $*"

    local i
    for (( i=1; i<=WARMUP; i++ )); do
        echo "    warmup $i/$WARMUP ..."
        "$@" > /dev/null 2>&1 || true
    done

    for (( i=1; i<=RUNS; i++ )); do
        local out="$dir/iter${i}_t${threads}.out"
        local t0 t1 dur ec=0
        t0=$(date +%s%N)
        "$@" > "$out" 2>&1 || ec=$?
        t1=$(date +%s%N)
        dur=$(( (t1 - t0) / 1000000 ))
        local parsed mname mval unit
        parsed=$("$parser" "$out" 2>/dev/null || echo "unknown  ")
        read -r mname mval unit <<< "$parsed"
        emit_record "$test_id" "$i" "$dur" "${mname:-unknown}" "${mval:-}" \
                    "${unit:-}" "$threads" "$ec" "$out"
        echo "    run $i/$RUNS: ${dur}ms  ${mname:-?}=${mval:-?} ${unit:-}"
    done
    report_cv "$test_id" "$threads"
}

# CV 检查（§0.3：计算类 ≤3%，系统/存储类 ≤5%——阈值由调用方判断，这里只报告）
report_cv() {
    local test_id="$1" threads="$2"
    jq -s --argjson t "$threads" \
        '[ .[] | select(.concurrency==$t and .metric.value!=null) | .metric.value ]
         | if length<2 then "CV: n/a（样本不足）"
           else (add/length) as $m
              | (map(($m - .)*($m - .)) | add/length | sqrt) as $sd
              | "CV: \(($sd/$m*100*100|round)/100)%  mean=\($m)  n=\(length)"
           end' \
        "$RESULTS_DIR/$test_id/records.jsonl" 2>/dev/null | tr -d '"' | sed 's/^/    /'
}

# ---------- 常用输出解析器 ----------
parse_sysbench_eps()   { awk '/events per second/ {print "events_per_sec", $NF, "events/s"}' "$1"; }
parse_7z_mips()        { awk '/^Tot:/ {print "total_mips", $NF, "MIPS"}' "$1"; }
parse_openssl_last()   { awk 'END {print "throughput_16KB", $NF, "kB/s"}' "$1"; }
parse_stream_triad()   { awk '/^Triad:/ {print "triad_bw", $2, "MB/s"}' "$1"; }
parse_hackbench_time() { awk '/^Time:/ {print "elapsed", $2, "s"}' "$1"; }
parse_zstd_bench() {
    # zstd -bN 输出形如: " 3#silesia.tar ... 123.4 MB/s ,  456.7 MB/s"
    awk -F',' '/MB\/s/ {gsub(/[^0-9. ]/,"",$(NF-1)); split($(NF-1),a," ");
               print "compress_speed", a[length(a)], "MB/s"; exit}' "$1"
}
parse_fio_json() {
    jq -r '.jobs[0] | "read_iops \(.read.iops // .write.iops) IOPS"' "$1" 2>/dev/null
}
parse_stressng_bogo()  { awk '/bogo ops\/s/ && /cpu/ {print "bogo_ops_per_sec", $(NF), "bogo-ops/s"; exit}' "$1"; }
parse_lat_generic() {
    # lmbench 输出到 stderr，形如 "Simple syscall: 0.1234 microseconds"
    awk -F': ' '/icrosecond/ {split($2,a," "); print "latency", a[1], "us"; exit}' "$1"
}
parse_unixbench_index() {
    awk '/System Benchmarks Index Score/ {print "index_score", $NF, "score"; exit}' "$1"
}
parse_perf_syscall() { awk '/usecs\/op/ {print "syscall_latency", $1, "us"; exit}' "$1"; }
parse_perf_sched()   { awk '/usecs\/op/ {print "pipe_op_latency", $1, "us"; exit}' "$1"; }
parse_spawn_p95()    { awk '/spawn_p95_us/ {print "spawn_p95", $2, "us"; exit}' "$1"; }
parse_lat_ctx() {
    # lat_ctx 输出（stderr）末行: "<进程数> <µs/切换>"
    awk 'END {print "ctx_switch", $2, "us"}' "$1"
}
parse_lat_mem_tail() {
    # lat_mem_rd 输出延迟曲线，末行为最大工作集（DRAM 段）: "<MB> <ns>"
    awk 'END {print "dram_latency", $2, "ns"}' "$1"
}
parse_memtester() {
    awk -v n="$(grep -c FAILURE "$1" 2>/dev/null)" \
        'BEGIN {print "memtester_failures", n+0, "count"}' /dev/null
}
parse_sysbench_mem() {
    awk '/Total operations:/ {gsub(/[()]/,""); print "ops_per_sec", $4, "ops/s"; exit}' "$1"
}
parse_geekbench() { echo "manual_review  "; }
parse_none()      { echo "see_raw  "; }
