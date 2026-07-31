#!/usr/bin/env bash
# 30_mem_tests.sh — 数据访问能力中的内存/NUMA 测试（MEM-00~07），规范见 PART1_TEST_SPEC.md §3
# 用法: sudo PLATFORM_ID=intel-6966p SESSION_ID=<批次> bash 30_mem_tests.sh [MEM-01 ...]
# 说明: MEM-00 抽样大小用 MEMTEST_GB 覆盖（常规默认 10，每 NUMA 节点各测一份）；
#       100GB/节点或更大规模留作过夜专项检查。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
CV_LIMIT=3

require_linux
require_tool numactl jq lscpu taskset mpstat || exit 1
check_governor || exit 1
PIN=$(pick_pin_core) || exit 1
mapfile -t NODE_IDS < <(numactl --hardware | awk '/^node [0-9]+ cpus:/ {print $2}')
NODES=${#NODE_IDS[@]}
(( NODES > 0 )) || { echo "FATAL: 无法从 numactl 取得 NUMA 节点列表" >&2; exit 1; }
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/{gsub(/[[:space:]]/, "", $2); print $2; exit}')
HAS_MLC=0
MLC_EXPECTED=0
[[ "$CPU_VENDOR" == "GenuineIntel" || "${ENABLE_MLC_ON_AMD:-0}" == "1" ]] && MLC_EXPECTED=1
if command -v mlc >/dev/null 2>&1; then
    if [[ "$CPU_VENDOR" == "GenuineIntel" || "${ENABLE_MLC_ON_AMD:-0}" == "1" ]]; then
        MLC_RUNTIME_VERSION=$(mlc --version 2>&1 | head -1 || true)
        if [[ "$MLC_RUNTIME_VERSION" == *"v3.12"* ]]; then
            HAS_MLC=1
        else
            echo "ERROR: MLC 版本不是规范要求的 v3.12（实际: ${MLC_RUNTIME_VERSION:-unknown}）" >&2
        fi
    elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        echo "INFO: AMD 平台默认不运行 Intel MLC；完成兼容性验证后可设 ENABLE_MLC_ON_AMD=1。"
    fi
elif (( MLC_EXPECTED )); then
    echo "ERROR: Intel 平台缺少规范要求的 MLC v3.12；通用内存项仍可执行，但 MEM-05 将记为缺项。" >&2
fi
echo "绑核目标: core $PIN；NUMA 节点数: $NODES；CPU vendor: ${CPU_VENDOR:-unknown}；MLC: $([[ $HAS_MLC == 1 ]] && echo 启用 || echo 未启用)"
check_idle || exit 1
trap 'exit 130' INT
trap 'exit 143' TERM

edac_counts() {  # 分别汇总全部内存控制器 CE、UE 计数
    # EDAC 不可用（虚拟机/驱动未加载）时输出 "na"，不得与 0 错误混淆
    ls /sys/devices/system/edac/mc/mc* >/dev/null 2>&1 || { echo "na na"; return; }
    local ce ue
    ce=$(cat /sys/devices/system/edac/mc/mc*/ce_count 2>/dev/null \
        | awk '{s+=$1} END {print s+0}')
    ue=$(cat /sys/devices/system/edac/mc/mc*/ue_count 2>/dev/null \
        | awk '{s+=$1} END {print s+0}')
    echo "$ce $ue"
}

mem00() {  # 内存正确性抽样（每节点 MEMTEST_GB，1 轮全模式）+ ECC 计数前后对比
    # 硬门槛：memtester 报错或 ECC 计数新增 → 返回非零，调用方必须中止后续测试
    require_tool memtester || return 1
    local GB="${MEMTEST_GB:-10}"
    [[ "$GB" =~ ^[0-9]+$ ]] && (( GB > 0 )) \
        || { echo "ERROR: MEMTEST_GB 必须是正整数" >&2; return 1; }
    if compgen -G "$RESULTS_DIR/MEM-00-node*/records.jsonl" >/dev/null; then
        echo "ERROR: MEM-00 本 session 已有结果，拒绝覆盖辅助文件；请使用新的 SESSION_ID" >&2
        return 1
    fi
    mkdir -p "$RESULTS_DIR/MEM-00"
    local ce_before ue_before ce_after ue_after
    read -r ce_before ue_before < <(edac_counts)
    if [[ "$ce_before" == "na" ]]; then
        echo "WARN: EDAC 不可用（无 /sys/devices/system/edac/mc），ECC 检查缺项，本项仅凭 memtester 判定" \
            | tee "$RESULTS_DIR/MEM-00/edac_unavailable.txt"
    fi
    if command -v edac-util >/dev/null 2>&1; then
        edac-util --report=full > "$RESULTS_DIR/MEM-00/edac_before.txt" 2>&1 || true
    else
        echo "edac-util 未安装；判定使用 sysfs EDAC 计数" > "$RESULTS_DIR/MEM-00/edac_before.txt"
    fi
    local n
    for n in "${NODE_IDS[@]}"; do
        NUMA_POLICY="membind=$n" NO_PROFILE=1 WARMUP=0 RUNS=1 run_case "MEM-00-node$n" 1 parse_memtester \
            -- numactl --membind="$n" memtester "${GB}G" 1
    done
    read -r ce_after ue_after < <(edac_counts)
    if command -v edac-util >/dev/null 2>&1; then
        edac-util --report=full > "$RESULTS_DIR/MEM-00/edac_after.txt" 2>&1 || true
    else
        echo "edac-util 未安装；判定使用 sysfs EDAC 计数" > "$RESULTS_DIR/MEM-00/edac_after.txt"
    fi

    local gate_fail=0
    if grep -rq FAILURE "$RESULTS_DIR"/MEM-00-node*/iter*.out 2>/dev/null; then
        echo "FATAL: memtester 报告 FAILURE（详见 MEM-00-node*/iter*.out）"
        gate_fail=1
    fi
    if jq -es 'map(select(.exit_code != 0)) | length > 0' \
        "$RESULTS_DIR"/MEM-00-node*/records.jsonl >/dev/null 2>&1; then
        echo "FATAL: memtester 进程非零退出"
        gate_fail=1
    fi
    if [[ "$ce_before" != "na" && "$ce_after" != "na" ]] \
        && (( ce_after > ce_before || ue_after > ue_before )); then
        echo "FATAL: ECC 计数新增（CE: $ce_before→$ce_after，UE: $ue_before→$ue_after）"
        gate_fail=1
    fi
    if [[ "$ce_before" != "na" && "$ce_after" != "na" ]] \
        && (( ce_after < ce_before || ue_after < ue_before )); then
        echo "WARN: ECC 计数下降（CE: $ce_before→$ce_after，UE: $ue_before→$ue_after），可能发生驱动重载；需人工复核"
    fi
    if (( gate_fail )); then
        echo "MEM-00 未通过：该机器停止一切性能测试，报修或换机。"
        return 1
    fi
    if [[ "$ce_before" == "na" ]]; then
        echo "MEM-00 通过（memtester 0 错误；EDAC 不可用，ECC 检查缺项已记录）"
    else
        echo "MEM-00 通过：memtester 0 错误，ECC 计数无新增（累计 CE=$ce_before, UE=$ue_before）"
    fi
}

mem01() {  # 顺序带宽：单线程（跨平台以 Triad 为准）
    require_tool stream || return 1
    WARMUP=0 run_case MEM-01-t1 1 parse_stream_triad \
        -- taskset -c "$PIN" env OMP_NUM_THREADS=1 OMP_PROC_BIND=true OMP_PLACES=cores \
           bash "$ROOT_DIR/workloads/stream_checked.sh"
}

mem02() {  # 缓存/内存延迟阶梯：lat_mem_rd 全曲线（通用）+ MLC idle latency（x86）
    require_tool lat_mem_rd || return 1
    NO_PROFILE=1 RUNS=$LONG_RUNS run_case MEM-02-ladder 1 parse_lat_mem_tail \
        -- taskset -c "$PIN" lat_mem_rd 2048 128
    if (( HAS_MLC )); then
        NO_PROFILE=1 WARMUP=1 run_case MEM-02-mlc-idle 1 parse_none -- mlc --idle_latency
    fi
}

mem03() {  # NUMA 延迟矩阵（多路必测）
    require_tool lat_mem_rd || return 1
    (( NODES < 2 )) && { echo "单 NUMA 节点，跳过 MEM-03"; return 0; }
    if (( HAS_MLC )); then
        NO_PROFILE=1 WARMUP=1 RUNS=$LONG_RUNS run_case MEM-03-latmatrix 1 parse_none \
            -- mlc --latency_matrix
    fi
    # 通用交叉验证：lat_mem_rd 在节点绑定组合下的 DRAM 段延迟
    # 通用基线每组合跑 1 遍（单次 2GB 阶梯即十几分钟）；MLC 只作补充。
    local i j node_cpu
    for i in "${NODE_IDS[@]}"; do for j in "${NODE_IDS[@]}"; do
        node_cpu=$(physical_cpu_list_node "$i" | head -1)
        [[ -n "$node_cpu" ]] || {
            echo "ERROR: NUMA 节点 $i 没有可用于 MEM-03 的在线物理核" >&2
            RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
            continue
        }
        NUMA_POLICY="physcpubind=$node_cpu,membind=$j" NO_PROFILE=1 WARMUP=1 RUNS=1 run_case "MEM-03-lmr-c${i}m${j}" 1 parse_lat_mem_tail \
            -- numactl --physcpubind="$node_cpu" --membind="$j" lat_mem_rd 2048 128
    done; done
}

mem04() {  # NUMA 带宽矩阵与峰值带宽
    require_tool stream || return 1
    (( NODES < 2 )) && { echo "单 NUMA 节点，跳过 MEM-04"; return 0; }
    if (( HAS_MLC )); then
        NO_PROFILE=1 WARMUP=1 RUNS=$LONG_RUNS run_case MEM-04-bwmatrix 1 parse_none -- mlc --bandwidth_matrix
        NO_PROFILE=1 WARMUP=1 RUNS=$LONG_RUNS run_case MEM-04-peak 1 parse_none -- mlc --peak_injection_bandwidth
    fi
    local i j node_threads
    for i in "${NODE_IDS[@]}"; do for j in "${NODE_IDS[@]}"; do
        node_threads=$(nproc_physical_node "$i")
        (( node_threads > 0 )) || {
            echo "ERROR: NUMA 节点 $i 没有可用于 MEM-04 的在线物理核" >&2
            RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
            continue
        }
        NUMA_POLICY="cpunodebind=$i,membind=$j" WARMUP=0 run_case "MEM-04-stream-c${i}m${j}" "$node_threads" parse_stream_triad \
            -- env OMP_NUM_THREADS="$node_threads" OMP_PROC_BIND=spread OMP_PLACES=cores \
               numactl --cpunodebind="$i" --membind="$j" \
               bash "$ROOT_DIR/workloads/stream_checked.sh"
    done; done
}

mem05() {  # 负载下延迟（带宽-延迟曲线，高并发表现的关键指标；MRDIMM 主战场）
    if (( ! HAS_MLC )); then
        if (( MLC_EXPECTED )); then
            echo "ERROR: Intel 平台缺少 MLC，MEM-05 无法执行" >&2
            return 1
        fi
        echo "无已验证的 MLC，MEM-05 缺项（跨厂商报告中明确注明）"
        return 0
    fi
    NO_PROFILE=1 WARMUP=1 RUNS=$LONG_RUNS run_case MEM-05-loaded 1 parse_none -- mlc --loaded_latency
}

mem06() {  # 多线程带宽扩展：1,2,4,...,物理核
    require_tool stream || return 1
    local phys T=1; phys=$(nproc_physical)
    while (( T <= phys )); do
        WARMUP=0 run_case "MEM-06-t$T" "$T" parse_stream_triad \
            -- env OMP_NUM_THREADS="$T" OMP_PROC_BIND=spread OMP_PLACES=cores \
               bash "$ROOT_DIR/workloads/stream_checked.sh"
        (( T *= 2 ))
    done
    if (( T/2 != phys )); then
        WARMUP=0 run_case "MEM-06-t$phys" "$phys" parse_stream_triad \
            -- env OMP_NUM_THREADS="$phys" OMP_PROC_BIND=spread OMP_PLACES=cores \
               bash "$ROOT_DIR/workloads/stream_checked.sh"
    fi
}

mem07() {  # 随机访问（与 MEM-02 DRAM 段互相印证）
    require_tool pointer_chase sysbench || return 1
    local l3_mib work_mib accesses_million
    l3_mib=$(total_l3_mib)
    work_mib=${POINTER_CHASE_MIB:-$(( l3_mib * 2 ))}
    [[ "$work_mib" =~ ^[0-9]+$ ]] && (( work_mib > 0 )) \
        || { echo "ERROR: POINTER_CHASE_MIB 必须是正整数" >&2; return 1; }
    (( work_mib < 2048 )) && work_mib=2048
    accesses_million=${POINTER_CHASE_MILLION:-20}
    [[ "$accesses_million" =~ ^[0-9]+$ ]] && (( accesses_million > 0 )) \
        || { echo "ERROR: POINTER_CHASE_MILLION 必须是正整数" >&2; return 1; }

    # 主数据：固定种子随机单链，工作集默认 max(2048MiB, 2×整机L3)。
    NO_PROFILE=1 WARMUP=0 RUNS=$LONG_RUNS run_case MEM-07-pointer 1 parse_pointer_chase \
        -- taskset -c "$PIN" pointer_chase "$work_mib" "$accesses_million"
    local checksum_lines checksum_unique
    checksum_lines=$(awk '/^checksum / {n++} END {print n+0}' \
        "$RESULTS_DIR"/MEM-07-pointer/iter*.out 2>/dev/null)
    checksum_unique=$(awk '/^checksum / {print $2}' \
        "$RESULTS_DIR"/MEM-07-pointer/iter*.out 2>/dev/null | sort -u | wc -l)
    if (( checksum_lines != LONG_RUNS || checksum_unique != 1 )); then
        echo "ERROR: pointer_chase 各轮 checksum 缺失或不一致" >&2
        RUN_CASE_FAILURES=$(( RUN_CASE_FAILURES + 1 ))
    fi

    # tinymembench 0.4.9 最大工作集只有 64MiB，在大缓存服务器上只能作为
    # cache/TLB 辅助曲线，不能代表随机 DRAM 延迟。
    if command -v tinymembench >/dev/null 2>&1; then
        NO_PROFILE=1 WARMUP=0 RUNS=1 run_case MEM-07-tinymembench-aux 1 parse_tinymembench_random \
            -- taskset -c "$PIN" tinymembench
    else
        echo "WARN: tinymembench 未安装，MEM-07 缺少 cache/TLB 辅助曲线" >&2
    fi
    # 参考数据：sysbench 8 字节小块随机负载偏 cache/TLB，不代表大工作集 DRAM 随机访问
    run_case MEM-07-rnd 1 parse_sysbench_mem \
        -- taskset -c "$PIN" sysbench memory --memory-access-mode=rnd \
           --memory-block-size=8 --memory-total-size=8G --threads=1 run
}

ALL=(mem00 mem01 mem02 mem06 mem07 mem03 mem04 mem05)
if (( $# )); then
    for t in "$@"; do
        fn=$(echo "${t,,}" | tr -d '-')
        run_test_function "$fn"
    done
else
    for fn in "${ALL[@]}"; do run_test_function "$fn"; done
fi
finish_test_layer "数据访问能力测试" || exit 1
echo "记录在 $RESULTS_DIR/MEM-*/records.jsonl"
