#!/usr/bin/env bash
# 02_prepare_state.sh — 测试前系统状态设置与环境基线采集（方案 §8）
# 用法：sudo bash 02_prepare_state.sh <platform_id>   例: sudo bash 02_prepare_state.sh intel-6966p
# 单独分步执行时，应给准备脚本和后续测试显式传入同一个 SESSION_ID。
# 注意：governor 设置重启后失效，机器重启过要重跑本脚本。
set -uo pipefail
export LC_ALL=C

PLATFORM_ID="${1:?用法: sudo bash 02_prepare_state.sh <platform_id>}"
# 项目根目录按脚本位置推导，不依赖 $HOME/sudo 环境
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# 基线跟随批次（session）存放：每批测试都有自己对应的环境快照，重跑不覆盖历史
SESSION_ID="${SESSION_ID:-standalone_$(date +%Y%m%d_%H%M%S)_$$}"
[[ "$PLATFORM_ID" =~ ^[A-Za-z0-9._-]+$ && "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { echo "platform_id/session_id 只能包含字母、数字、点、下划线和连字符" >&2; exit 1; }
ENV_DIR="$ROOT_DIR/results/raw/$PLATFORM_ID/$SESSION_ID/env"
[[ "$(id -u)" == "0" ]] || { echo "需要 root"; exit 1; }
for required in lscpu numactl mpstat dmidecode lsblk findmnt; do
    command -v "$required" >/dev/null 2>&1 \
        || { echo "FATAL: 缺少环境采集工具 $required（先运行 01_setup_tools.sh）" >&2; exit 2; }
done
if [[ -e "$ENV_DIR/uname.txt" || -e "$ENV_DIR/governor.txt" ]]; then
    echo "FATAL: 本 session 已有环境快照，拒绝覆盖：$ENV_DIR（请使用新的 SESSION_ID）" >&2
    exit 2
fi
mkdir -p "$ENV_DIR"

echo "==> 1. 设置 performance governor"
GOVERNOR_FILES=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
if [[ -r "${GOVERNOR_FILES[0]}" ]]; then
    if command -v cpupower >/dev/null 2>&1; then
        cpupower frequency-set -g performance >/dev/null 2>&1 || \
            echo "WARN: cpupower 设置失败，将根据实际 governor 状态判定" >&2
    else
        for f in "${GOVERNOR_FILES[@]}"; do
            printf '%s\n' performance > "$f" 2>/dev/null || true
        done
    fi
else
    echo "WARN: 系统未暴露 cpufreq governor（虚拟机或驱动未加载），无法强制设置" >&2
fi
sleep 1
if [[ -r "${GOVERNOR_FILES[0]}" ]]; then
    GOVERNORS=$(cat "${GOVERNOR_FILES[@]}" 2>/dev/null | sort -u | paste -sd, -)
    printf '%s\n' "$GOVERNORS" > "$ENV_DIR/governor.txt"
    echo "    governor 现状: $GOVERNORS"
    if [[ "$GOVERNORS" != "performance" ]]; then
        echo "FATAL: 并非所有在线 CPU 都处于 performance governor（实际: $GOVERNORS）" >&2
        exit 2
    fi
else
    printf '%s\n' unavailable > "$ENV_DIR/governor.txt"
fi

echo "==> 2. 采集环境基线 → $ENV_DIR"
uname -a                          > "$ENV_DIR/uname.txt"
cat /etc/os-release               > "$ENV_DIR/os-release.txt" 2>&1
lscpu                             > "$ENV_DIR/lscpu.txt"
lscpu -e                         > "$ENV_DIR/lscpu_topology.txt"
numactl --hardware                > "$ENV_DIR/numactl.txt"
grep -r . /sys/devices/system/cpu/vulnerabilities/ > "$ENV_DIR/mitigations.txt"
cat /proc/cmdline                 > "$ENV_DIR/kernel_cmdline.txt"
grep -m1 microcode /proc/cpuinfo  > "$ENV_DIR/microcode.txt"
cat /sys/kernel/mm/transparent_hugepage/enabled > "$ENV_DIR/thp.txt"
cat /sys/devices/system/cpu/smt/active > "$ENV_DIR/smt_active.txt" 2>&1 || echo "unknown" > "$ENV_DIR/smt_active.txt"
{
    [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]] \
        && echo "intel_pstate_no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
    [[ -r /sys/devices/system/cpu/cpufreq/boost ]] \
        && echo "cpufreq_boost=$(cat /sys/devices/system/cpu/cpufreq/boost)"
} > "$ENV_DIR/turbo_state.txt"
cat /proc/sys/kernel/sched_autogroup_enabled > "$ENV_DIR/sched_autogroup_enabled.txt" 2>&1 || true
cat /proc/sys/kernel/perf_event_paranoid > "$ENV_DIR/perf_event_paranoid.txt" 2>&1 || true
cat /proc/sys/kernel/nmi_watchdog > "$ENV_DIR/nmi_watchdog.txt" 2>&1 || true
{
    EPP_FILES=(/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference)
    if [[ -r "${EPP_FILES[0]}" ]]; then
        cat "${EPP_FILES[@]}" 2>/dev/null | sort -u
    else
        echo unavailable
    fi
} > "$ENV_DIR/energy_performance_preference.txt"
timedatectl status                 > "$ENV_DIR/time_sync.txt" 2>&1 || true
dmidecode -t bios                 > "$ENV_DIR/bios.txt" 2>&1
dmidecode -t processor            > "$ENV_DIR/processor_dmi.txt" 2>&1
dmidecode -t memory               > "$ENV_DIR/dimm_full.txt" 2>&1
dmidecode -t memory | grep -E "Speed|Type:|Size|Manufacturer|Part Number" \
    | sort | uniq -c              > "$ENV_DIR/dimm_summary.txt" 2>&1
lsblk -o NAME,MODEL,SIZE,ROTA,TRAN,MOUNTPOINT > "$ENV_DIR/storage.txt" 2>&1
ip -br link                       > "$ENV_DIR/network.txt" 2>&1 || true
findmnt -D                         > "$ENV_DIR/mounts.txt" 2>&1 || true
df -hT                             > "$ENV_DIR/disk_space.txt" 2>&1
lstopo-no-graphics                > "$ENV_DIR/lstopo.txt" 2>&1 || true
cat /proc/interrupts              > "$ENV_DIR/interrupts_before.txt"
free -b                           > "$ENV_DIR/memory.txt"
edac-util --report=full           > "$ENV_DIR/edac_before.txt" 2>&1 || true
ipmitool dcmi power reading       > "$ENV_DIR/idle_power.txt" 2>&1 || echo "ipmitool 不可用" > "$ENV_DIR/idle_power.txt"
if command -v turbostat >/dev/null 2>&1; then
    timeout 10 turbostat --quiet --Summary --interval 1 --num_iterations 1 \
        > "$ENV_DIR/idle_turbostat.txt" 2>&1 \
        || echo "turbostat 空闲快照采集失败" >> "$ENV_DIR/idle_turbostat.txt"
else
    echo "turbostat 不可用" > "$ENV_DIR/idle_turbostat.txt"
fi
cp "$ROOT_DIR/tools/VERSIONS.txt"   "$ENV_DIR/versions.txt" 2>/dev/null || echo "先运行 01_setup_tools.sh" > "$ENV_DIR/versions.txt"

echo "==> 3. 空闲率检查（1 分钟，要求 ≥98%）"
command -v mpstat >/dev/null 2>&1 \
    || { echo "FATAL: 缺少 mpstat（请安装 sysstat）" >&2; exit 2; }
IDLE=$(mpstat 6 10 | awk '/Average/ {print $NF}')
echo "    平均空闲: ${IDLE}%"
echo "$IDLE" > "$ENV_DIR/idle_baseline.txt"
awk -v i="$IDLE" 'BEGIN{exit !(i >= 98.0)}' || { echo "FATAL: 空闲率不足，排查干扰进程（top / systemctl list-timers）"; exit 2; }

echo "==> 4. 干扰源提示（人工确认以下输出是否可接受）"
echo "    -- 活跃定时器（关注 unattended-upgrades / apt / man-db）:"
systemctl list-timers --no-pager 2>/dev/null | head -15 || true
systemctl list-timers --all --no-pager > "$ENV_DIR/systemd_timers.txt" 2>&1 || true
echo "    -- 推荐临时停用: systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer"

echo
echo "==> 完成。基线已存 $ENV_DIR，可以开始测试。"
