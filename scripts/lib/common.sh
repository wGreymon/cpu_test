#!/usr/bin/env bash
# common.sh — 运行协议公共库（PART1_TEST_SPEC.md §0.2 / §0.3）
# 被 10_os_tests.sh / 20_cpu_tests.sh / 30_mem_tests.sh 引用，不单独执行。

set -u
export LC_ALL=C

# ---------- 全局配置（可用环境变量覆盖） ----------
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PLATFORM_ID="${PLATFORM_ID:-unknown-platform}"   # 必须由调用方指定，如 cpu-a
SANDBOX_TYPE="${SANDBOX_TYPE:-bare}"
NUMA_POLICY="${NUMA_POLICY:-default}"
WARMUP="${WARMUP:-2}"                            # 预热次数（§0.2）
RUNS="${RUNS:-5}"                                # 正式运行次数（§0.2）
LONG_RUNS="${LONG_RUNS:-3}"                      # >10min 用例的正式次数
PIN_CORE="${PIN_CORE:-}"                         # 单线程绑核编号，空则自动选择
RUN_CASE_FAILURES="${RUN_CASE_FAILURES:-0}"       # 本层正式运行/解析失败总数
CV_LIMIT="${CV_LIMIT:-}"                           # 百分比；由执行层设置（CPU/MEM=3，OS=5）
[[ "$WARMUP" =~ ^[0-9]+$ && "$RUNS" =~ ^[1-9][0-9]*$ && "$LONG_RUNS" =~ ^[1-9][0-9]*$ ]] \
    || { echo "FATAL: WARMUP 必须为非负整数，RUNS/LONG_RUNS 必须为正整数" >&2; exit 1; }
# 每批测试一个 session：目录按批隔离，同日补测不会覆盖/混入旧记录
# run_part1.sh 统一导出 SESSION_ID；单独跑某层脚本时自动生成新批次
SESSION_ID="${SESSION_ID:-$(date +%Y%m%d_%H%M%S)_$$}"
export SESSION_ID
[[ "$PLATFORM_ID" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { echo "FATAL: PLATFORM_ID 只能包含字母、数字、点、下划线和连字符" >&2; exit 1; }
[[ "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { echo "FATAL: SESSION_ID 只能包含字母、数字、点、下划线和连字符" >&2; exit 1; }
RESULTS_DIR="$ROOT_DIR/results/raw/$PLATFORM_ID/$SESSION_ID"
TOOLS_PREFIX="${TOOLS_PREFIX:-$ROOT_DIR/tools/bin}"
export PATH="$TOOLS_PREFIX:$PATH"

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

# 执行一个用例组函数；函数自身非零但未被 run_case 计数时补记一次。
# 这样缺工具等前置失败也会反映到该层退出码，同时其余普通用例仍可继续。
run_test_function() {
    local fn="$1" before="$RUN_CASE_FAILURES" rc=0
    if ! declare -F "$fn" >/dev/null 2>&1; then
        echo "ERROR: 未知测试项对应函数：$fn" >&2
        RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
        return 0
    fi
    "$fn" || rc=$?
    if (( rc != 0 && RUN_CASE_FAILURES == before )); then
        RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
    fi
    return 0
}

finish_test_layer() {
    local layer="$1"
    if (( RUN_CASE_FAILURES > 0 )); then
        echo "ERROR: $layer 有 $RUN_CASE_FAILURES 个正式运行、解析或前置检查失败；原始结果已保留。" >&2
        return 1
    fi
    echo "$layer 完成，全部已执行项有效。"
}

# 判断 CPU 编号当前是否在线。cpu0 通常没有 online 文件，视为在线。
cpu_is_online() {
    # Bash 会在执行 local 赋值前展开同一条命令的全部右值。
    # set -u 下不能在同一条 local 中立即引用刚声明的 cpu。
    local cpu="$1"
    local online="/sys/devices/system/cpu/cpu${cpu}/online"
    [[ "$cpu" =~ ^[0-9]+$ ]] || return 1
    [[ -d "/sys/devices/system/cpu/cpu${cpu}" ]] || return 1
    [[ ! -r "$online" || "$(cat "$online")" == "1" ]]
}

# 每个在线物理核输出一个逻辑 CPU。只依赖 lscpu 的通用三列，避免部分
# util-linux 版本不支持 ONLINE 列时把物理核数误判为 0。
physical_cpu_list() {
    local cpu core socket key
    declare -A seen=()
    while IFS=, read -r cpu core socket; do
        [[ "$cpu" =~ ^[0-9]+$ ]] || continue
        cpu_is_online "$cpu" || continue
        key="${socket}:${core}"
        [[ -n "${seen[$key]:-}" ]] && continue
        seen[$key]=1
        printf '%s\n' "$cpu"
    done < <(lscpu -p=CPU,CORE,SOCKET 2>/dev/null)
}

# 选择绑核目标：同一 session 固定复用；自动选择时只考虑每个物理核的
# 第一个在线硬件线程，并避开累计中断最多的核（§0.2 第 3 条）。
pick_pin_core() {
    local pin_file="$RESULTS_DIR/env/pin_core.txt" saved candidates selected
    mkdir -p "$(dirname "$pin_file")"

    if [[ -s "$pin_file" ]]; then
        saved=$(tr -d '[:space:]' < "$pin_file")
        if ! cpu_is_online "$saved"; then
            echo "FATAL: 已记录的绑核 CPU $saved 当前不在线：$pin_file" >&2
            return 1
        fi
        if [[ -n "$PIN_CORE" && "$PIN_CORE" != "$saved" ]]; then
            echo "FATAL: PIN_CORE=$PIN_CORE 与本批次已记录的 CPU $saved 不一致" >&2
            return 1
        fi
        echo "$saved"
        return 0
    fi

    if [[ -n "$PIN_CORE" ]]; then
        cpu_is_online "$PIN_CORE" || {
            echo "FATAL: PIN_CORE=$PIN_CORE 不是在线 CPU" >&2
            return 1
        }
        selected="$PIN_CORE"
    else
        # CPU,CORE,SOCKET 组合用于排除 SMT sibling。
        candidates=$(physical_cpu_list | paste -sd, -)
        [[ -n "$candidates" ]] || {
            echo "FATAL: 无法从 lscpu 取得在线物理核列表" >&2
            return 1
        }
        # /proc/interrupts 标题从第 1 列开始，数据行因 IRQ 名多占 1 列。
        selected=$(awk -v candidates="$candidates" '
            BEGIN {
                n=split(candidates, a, ",")
                for (i=1; i<=n; i++) { wanted[a[i]]=1; total[a[i]]=0 }
            }
            NR==1 {
                for (i=1; i<=NF; i++) if ($i ~ /^CPU[0-9]+$/) {
                    cpu=$i; sub(/^CPU/, "", cpu); column[cpu]=i+1
                }
                next
            }
            {
                for (cpu in wanted) {
                    c=column[cpu]
                    if (c && $c ~ /^[0-9]+$/) total[cpu]+=$c
                }
            }
            END {
                chosen=""
                for (cpu in wanted)
                    if (chosen=="" || total[cpu]<minimum ||
                        (total[cpu]==minimum && cpu+0<chosen+0)) {
                        chosen=cpu; minimum=total[cpu]
                    }
                print chosen
            }' /proc/interrupts)
        cpu_is_online "$selected" || {
            echo "FATAL: 自动选择的 CPU $selected 不在线" >&2
            return 1
        }
    fi

    printf '%s\n' "$selected" > "$pin_file"
    echo "$selected"
}

nproc_physical() {
    physical_cpu_list | wc -l
}

physical_cpu_list_node() {
    local wanted="$1" cpu core socket node key
    declare -A seen=()
    while IFS=, read -r cpu core socket node; do
        [[ "$cpu" =~ ^[0-9]+$ && "$node" == "$wanted" ]] || continue
        cpu_is_online "$cpu" || continue
        key="${socket}:${core}"
        [[ -n "${seen[$key]:-}" ]] && continue
        seen[$key]=1
        printf '%s\n' "$cpu"
    done < <(lscpu -p=CPU,CORE,SOCKET,NODE 2>/dev/null)
}

nproc_physical_node() {
    physical_cpu_list_node "$1" | wc -l
}

total_l3_mib() {
    local bytes mib
    bytes=$(lscpu -B 2>/dev/null | awk -F: '/^L3 cache:/ {
        gsub(/^[[:space:]]+/, "", $2); split($2,a,/[^0-9.]+/); print a[1]; exit
    }')
    if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 0 )); then
        echo $(( (bytes + 1048575) / 1048576 ))
        return
    fi
    mib=$(lscpu 2>/dev/null | awk -F: '/^L3 cache:/ {
        gsub(/^[[:space:]]+/, "", $2); split($2,a,/[[:space:]]+/)
        v=a[1]+0; u=a[2]
        if (u ~ /^Ki?B$/) v/=1024
        else if (u ~ /^Gi?B$/) v*=1024
        printf "%.0f\n", v; exit
    }')
    echo "${mib:-32}"
}

# 线程梯度：1、25%、50%、100% 物理核、全部逻辑核（§0.2 第 3 条）
thread_ladder() {
    local phys logical q h
    phys=$(nproc_physical); logical=$(nproc)
    q=$(( phys / 4 )); [[ $q -lt 1 ]] && q=1
    h=$(( phys / 2 )); [[ $h -lt 1 ]] && h=1
    printf '%s\n' 1 "$q" "$h" "$phys" "$logical" | sort -un
}

# 敏感测试组开始前快速复查：10 秒平均空闲率需 ≥98%（§0.2 第 4 条）
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
    local g files=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
    [[ -r "${files[0]}" ]] || { echo "WARN: 无法读取 governor（虚拟机？），请人工确认" >&2; return 0; }
    g=$(cat "${files[@]}" 2>/dev/null | sort -u | paste -sd, -)
    if [[ "$g" != "performance" ]]; then
        echo "FATAL: governor 状态=$g（要求所有 CPU 均为 performance），请先执行 cpupower frequency-set -g performance" >&2
        return 1
    fi
}

# ---------- 结果记录（方案 §10 JSON 格式） ----------
# emit_record <test_id> <iteration> <duration_ms> <metric_name> <metric_value> <unit>
#             <threads> <exit_code> <raw_file> [notes] [metric_state]
# metric_state: valid / incomplete / raw_only
emit_record() {
    local test_id="$1" iter="$2" dur="$3" mname="$4" mval="$5" unit="$6" \
          threads="$7" ec="$8" raw="$9" notes="${10:-}" mstate="${11:-valid}"
    local dir="$RESULTS_DIR/$test_id" git_commit git_dirty
    mkdir -p "$dir"
    if [[ -z "${FRAMEWORK_GIT_COMMIT:-}" ]]; then
        FRAMEWORK_GIT_COMMIT=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)
        if [[ -n "$FRAMEWORK_GIT_COMMIT" && -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal -- \
            CPU_AGENT_SANDBOX_TEST_PLAN.md PART1_TEST_SPEC.md notes.md scripts workloads 2>/dev/null)" ]]; then
            FRAMEWORK_GIT_DIRTY=true
        elif [[ -n "$FRAMEWORK_GIT_COMMIT" ]]; then
            FRAMEWORK_GIT_DIRTY=false
        else
            FRAMEWORK_GIT_COMMIT=unavailable
            FRAMEWORK_GIT_DIRTY=null
        fi
    fi
    git_commit=$FRAMEWORK_GIT_COMMIT
    git_dirty=${FRAMEWORK_GIT_DIRTY:-null}
    if [[ -z "${FRAMEWORK_SHA256:-}" ]]; then
        FRAMEWORK_SHA256=$(cd "$ROOT_DIR" && {
            find scripts -type f -name '*.sh' -print
            printf '%s\n' CPU_AGENT_SANDBOX_TEST_PLAN.md PART1_TEST_SPEC.md notes.md \
                workloads/proc_spawn.py workloads/pointer_chase.c workloads/stream_checked.sh
        } | sort -u | while IFS= read -r f; do
            [[ -f "$f" ]] && sha256sum "$f"
        done | sha256sum | awk '{print $1}')
    fi
    jq -nc \
        --arg run_id      "${SESSION_ID}-${PLATFORM_ID}-${SANDBOX_TYPE}-${test_id}-$(printf '%03d' "$iter")" \
        --arg session_id  "$SESSION_ID" \
        --arg timestamp   "$(date -Iseconds)" \
        --arg platform_id "$PLATFORM_ID" \
        --arg cpu_model   "$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')" \
        --arg os_kernel   "$(uname -sr)" \
        --arg mitigations "$(mitigations_summary)" \
        --arg sandbox     "$SANDBOX_TYPE" \
        --arg numa_policy "$NUMA_POLICY" \
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
        --arg mstate      "$mstate" \
        --arg git_commit  "$git_commit" \
        --argjson git_dirty "$git_dirty" \
        --arg framework_sha256 "$FRAMEWORK_SHA256" \
        '{run_id:$run_id, session_id:$session_id, timestamp:$timestamp, platform_id:$platform_id,
          cpu_model:$cpu_model, os_kernel:$os_kernel, mitigations:$mitigations,
          sandbox_type:$sandbox, test_id:$test_id, concurrency:$threads,
          numa_policy:$numa_policy,
          iteration:$iter, duration_ms:($dur|tonumber? // null),
          cpu_time_ms:null, peak_rss_mb:null, energy_j:null,
          metric:{name:$mname, value:($mval|tonumber? // null), unit:$unit},
          metric_valid:(if $mstate=="valid" then true
                        elif $mstate=="incomplete" then false else null end),
          exit_code:$ec,
          correctness:(if $ec!=0 then "fail"
                       elif $mstate=="incomplete" then "incomplete" else "pass" end),
          raw_file:$raw, git_commit:$git_commit, git_dirty:$git_dirty,
          framework_sha256:$framework_sha256, notes:$notes}' \
        >> "$dir/records.jsonl"
}

is_number() {
    [[ "$1" =~ ^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]]
}

mitigations_summary() {
    local f name value first=1
    for f in /sys/devices/system/cpu/vulnerabilities/*; do
        [[ -r "$f" ]] || continue
        name=${f##*/}
        value=$(tr '\n' ' ' < "$f" | sed 's/[[:space:]]*$//')
        (( first )) || printf ';'
        printf '%s=%s' "$name" "$value"
        first=0
    done
}

# ---------- 通用执行器 ----------
# run_case <test_id> <threads> <parser_fn> -- <cmd...>
#   预热 WARMUP 次（丢弃输出），正式 RUNS 次；
#   每次 stdout 存 results/raw/<platform>/<session>/<test_id>/iterN.out；
#   parser_fn 从 stdout 文件提取 "metric_name metric_value unit"（空格分隔一行）。
run_case() {
    local test_id="$1" threads="$2" parser="$3"; shift 3
    [[ "$1" == "--" ]] && shift
    local dir="$RESULTS_DIR/$test_id"
    local existing=("$dir"/iter*_t*.out)
    if [[ -e "$dir/records.jsonl" || -e "${existing[0]}" ]]; then
        echo "ERROR: [$test_id] 本 session 已有结果，拒绝覆盖/混入；请使用新的 SESSION_ID" >&2
        RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
        return 1
    fi
    mkdir -p "$dir"
    echo "=== [$test_id] threads=$threads  warmup=$WARMUP runs=$RUNS"
    echo "    cmd: $*"
    {
        printf 'command='
        printf '%q ' "$@"
        printf '\nthreads=%s\nwarmup=%s\nruns=%s\nnuma_policy=%s\n' \
            "$threads" "$WARMUP" "$RUNS" "$NUMA_POLICY"
    } > "$dir/command.txt"

    local i fails=0 nometric=0 metric_required=1
    [[ "$parser" == "parse_none" ]] && metric_required=0
    for (( i=1; i<=WARMUP; i++ )); do
        echo "    warmup $i/$WARMUP ..."
        "$@" > /dev/null 2>&1 || true
    done

    # 主成绩运行不带任何包裹（perf stat 采集移至正式轮之后的独立 profiling 轮）
    for (( i=1; i<=RUNS; i++ )); do
        local out="$dir/iter${i}_t${threads}.out"
        local t0 t1 dur ec=0
        t0=$(date +%s%N)
        "$@" > "$out" 2>&1 || ec=$?
        t1=$(date +%s%N)
        dur=$(( (t1 - t0) / 1000000 ))
        local parsed mname mval unit mstate="valid"
        parsed=$("$parser" "$out" 2>/dev/null || true)
        read -r mname mval unit <<< "$parsed"
        if (( metric_required )); then
            if [[ -z "${mval:-}" ]] || ! is_number "$mval"; then
                mstate="incomplete"
                nometric=$(( nometric + 1 ))
            fi
        else
            mstate="raw_only"
        fi
        emit_record "$test_id" "$i" "$dur" "${mname:-unknown}" "${mval:-}" \
                    "${unit:-}" "$threads" "$ec" "$out" "" "$mstate"
        echo "    run $i/$RUNS: ${dur}ms  ${mname:-?}=${mval:-?} ${unit:-}"
        [[ "$ec" != "0" ]] && fails=$(( fails + 1 ))
    done

    # 任一次正式运行失败或主指标无法解析，都使本层最终返回非零；调用方仍会
    # 继续执行本层其他普通用例，便于一次收集完整的问题清单。
    (( nometric > 0 )) && echo "    WARN: [$test_id] $nometric/$RUNS 次未解析出指标值（检查工具输出与解析器）"
    (( fails > 0 ))    && echo "    WARN: [$test_id] $fails/$RUNS 次非零退出"
    if (( fails > 0 || nometric > 0 )); then
        RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + fails + nometric ))
    fi

    # profiling 轮（PROFILE=1 且该用例未标记 NO_PROFILE）：主成绩之外单独跑一次，
    # 采微架构计数器，只作解释用，不进 records.jsonl。
    # 长耗时/自带 perf/产出会被覆盖的用例由调用方设 NO_PROFILE=1 跳过。
    if [[ "${PROFILE:-0}" == "1" && "${NO_PROFILE:-0}" != "1" ]] && command -v perf >/dev/null 2>&1; then
        echo "    profiling run (perf stat) ..."
        local profile_ec=0
        perf stat -e task-clock,cycles,instructions,cache-references,cache-misses,context-switches,page-faults \
            -o "$dir/profile_t${threads}.perfstat" -- "$@" \
            > "$dir/profile_t${threads}.out" 2>&1 || profile_ec=$?
        (( profile_ec != 0 )) && echo "    WARN: [$test_id] perf profiling 轮失败（不影响主成绩）"
    fi
    local cv_bad=0
    report_cv "$test_id" "$threads" || cv_bad=1
    if (( cv_bad )); then
        RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
    fi
    (( fails == 0 && nometric == 0 && cv_bad == 0 ))
}

# CV 检查（§0.3：计算/内存类 ≤3%，系统/存储类 ≤5%）。
report_cv() {
    local test_id="$1" threads="$2" stats state cv mean n
    stats=$(jq -rs --argjson t "$threads" '
        [ .[] | select(.concurrency==$t and .correctness=="pass" and .metric.value!=null) | .metric.value ]
        | if length<2 then ["na", 0, 0, length]
          else (add/length) as $m
            | if $m==0 then ["zero", 0, 0, length]
              else (map(($m - .)*($m - .)) | add/length | sqrt) as $sd
                | ["ok", ($sd/$m*100), $m, length]
              end
          end | @tsv' "$RESULTS_DIR/$test_id/records.jsonl" 2>/dev/null)
    IFS=$'\t' read -r state cv mean n <<< "$stats"
    case "$state" in
        ok)
            printf '    CV: %.2f%%  mean=%s  n=%s\n' "$cv" "$mean" "$n"
            if [[ -n "$CV_LIMIT" ]] && awk -v c="$cv" -v l="$CV_LIMIT" 'BEGIN {exit !(c>l)}'; then
                echo "    ERROR: [$test_id] CV ${cv}% 超过阈值 ${CV_LIMIT}%" >&2
                return 1
            fi
            ;;
        zero) echo "    CV: n/a（均值为 0）  mean=0  n=$n" ;;
        *)    echo "    CV: n/a（样本不足）" ;;
    esac
}

# ---------- 常用输出解析器 ----------
parse_sysbench_eps()   { awk '/events per second/ {print "events_per_sec", $NF, "events/s"}' "$1"; }
parse_7z_mips()        { awk '/^Tot:/ {print "total_mips", $NF, "MIPS"}' "$1"; }
parse_openssl_last()   {
    awk 'END {v=$NF; sub(/[kK]$/, "", v); print "throughput_16KB", v, "kB/s"}' "$1"
}
parse_stream_triad()   { awk '/^Triad:/ {print "triad_bw", $2, "MB/s"}' "$1"; }
parse_hackbench_time() { awk '/^Time:/ {print "elapsed", $2, "s"}' "$1"; }
parse_zstd_bench() {
    # zstd -bN 输出形如: " 3#silesia.tar ... 123.4 MB/s ,  456.7 MB/s"
    awk -F',' '/MB\/s/ {gsub(/[^0-9. ]/,"",$(NF-1)); split($(NF-1),a," ");
               print "compress_speed", a[length(a)], "MB/s"; exit}' "$1"
}
parse_fio_iops() {
    jq -r '.jobs[0] | "read_iops \(.read.iops // .write.iops) IOPS"' "$1" 2>/dev/null
}
parse_fio_bw() {
    jq -r '.jobs[0] | "read_bandwidth_mib_s \((.read.bw_bytes // .write.bw_bytes) / 1048576) MiB/s"' \
        "$1" 2>/dev/null
}
parse_stressng_bogo()  {
    awk '/stress-ng: (metrc|metrics):.* cpu +[0-9]/ {
             print "bogo_ops_per_sec", $(NF-1), "bogo-ops/s"; exit
         }' "$1"
}
parse_lat_generic() {
    # lmbench 输出到 stderr，形如 "Simple syscall: 0.1234 microseconds"
    awk -F': ' '/icrosecond/ {split($2,a," "); print "latency", a[1], "us"; exit}' "$1"
}
parse_unixbench_index() {
    awk '/System Benchmarks Index Score/ {print "index_score", $NF, "score"; exit}' "$1"
}
parse_lat_syscall() {
    awk -F': ' '/icrosecond/ {split($2,a," "); printf "syscall_latency %.6f ns\n", a[1]*1000; exit}' "$1"
}
parse_perf_syscall() {
    awk '/usecs\/op/ {printf "syscall_latency %.6f ns\n", $1*1000; exit}' "$1"
}
parse_perf_sched()   { awk '/usecs\/op/ {print "pipe_op_latency", $1, "us"; exit}' "$1"; }
parse_spawn_p95()    { awk '/spawn_p95_us/ {print "spawn_p95", $2, "us"; exit}' "$1"; }
parse_lat_ctx() {
    # lat_ctx 输出（stderr）末行: "<进程数> <µs/切换>"
    awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+$/ {value=$2}
         END {if (value!="") print "ctx_switch", value, "us"}' "$1"
}
parse_lat_mem_tail() {
    # lat_mem_rd 输出延迟曲线，末行为最大工作集（DRAM 段）: "<MB> <ns>"
    awk '$1 ~ /^[0-9.]+$/ && $2 ~ /^[0-9.]+$/ {value=$2}
         END {if (value!="") print "dram_latency", value, "ns"}' "$1"
}
parse_memtester() {
    awk -v n="$(grep -c FAILURE "$1" 2>/dev/null)" \
        'BEGIN {print "memtester_failures", n+0, "count"}' /dev/null
}
parse_sysbench_mem() {
    awk '/Total operations:/ {gsub(/[()]/,""); print "ops_per_sec", $4, "ops/s"; exit}' "$1"
}
parse_tinymembench_random() {
    # 取第一个（MADV_NOHUGEPAGE）延迟区段的最大工作集单路随机读延迟。
    awk '
        /^block size/ {section++; capture=(section==1); next}
        capture && /^[[:space:]]*[0-9]+[[:space:]]*:/ {value=$3}
        END {if (value!="") print "random_read_latency_max_ws", value, "ns"}
    ' "$1"
}
parse_pointer_chase() {
    awk '/^pointer_chase_ns_per_access / {
             print "pointer_chase_latency", $2, "ns"; exit
         }' "$1"
}
parse_openssl_rsa() {
    # "rsa 2048 bits 0.00012s 0.000004s  8123.4 270123.5" → sign/s
    awk '/^rsa +2048/ {print "rsa2048_sign_per_s", $(NF-1), "sign/s"; exit}' "$1"
}
parse_none()      { echo "see_raw  "; }
