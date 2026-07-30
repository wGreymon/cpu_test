#!/usr/bin/env bash
# 02_prepare_state.sh — 测试前系统状态设置与环境基线采集（方案 §7）
# 用法：sudo bash 02_prepare_state.sh <platform_id>   例: sudo bash 02_prepare_state.sh intel-6966p
# 注意：governor 设置重启后失效，机器重启过要重跑本脚本。
set -uo pipefail

PLATFORM_ID="${1:?用法: sudo bash 02_prepare_state.sh <platform_id>}"
ROOT_DIR="${ROOT_DIR:-$HOME/cpu_test}"
ENV_DIR="$ROOT_DIR/results/raw/$PLATFORM_ID/env"
mkdir -p "$ENV_DIR"

[[ "$(id -u)" == "0" ]] || { echo "需要 root"; exit 1; }

echo "==> 1. 设置 performance governor"
if command -v cpupower >/dev/null; then
    cpupower frequency-set -g performance >/dev/null
else
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$f" 2>/dev/null
    done
fi
sleep 1
echo "    governor 现状: $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | paste -sd,)"

echo "==> 2. 采集环境基线 → $ENV_DIR"
uname -a                          > "$ENV_DIR/uname.txt"
lscpu                             > "$ENV_DIR/lscpu.txt"
lscpu -e                         > "$ENV_DIR/lscpu_topology.txt"
numactl --hardware                > "$ENV_DIR/numactl.txt"
grep -r . /sys/devices/system/cpu/vulnerabilities/ > "$ENV_DIR/mitigations.txt"
cat /proc/cmdline                 > "$ENV_DIR/kernel_cmdline.txt"
cat /sys/kernel/mm/transparent_hugepage/enabled > "$ENV_DIR/thp.txt"
dmidecode -t bios                 > "$ENV_DIR/bios.txt" 2>&1
dmidecode -t memory | grep -E "Speed|Type:|Size|Manufacturer|Part Number" \
    | sort | uniq -c              > "$ENV_DIR/dimm_summary.txt" 2>&1
lsblk -o NAME,MODEL,SIZE,ROTA,TRAN,MOUNTPOINT > "$ENV_DIR/storage.txt" 2>&1
lstopo-no-graphics                > "$ENV_DIR/lstopo.txt" 2>&1 || true
cat /proc/interrupts              > "$ENV_DIR/interrupts_before.txt"
free -b                           > "$ENV_DIR/memory.txt"
edac-util --report=full           > "$ENV_DIR/edac_before.txt" 2>&1 || true
ipmitool dcmi power reading       > "$ENV_DIR/idle_power.txt" 2>&1 || echo "ipmitool 不可用" > "$ENV_DIR/idle_power.txt"
cp "$ROOT_DIR/tools/VERSIONS.txt"   "$ENV_DIR/versions.txt" 2>/dev/null || echo "先运行 01_setup_tools.sh" > "$ENV_DIR/versions.txt"

echo "==> 3. 空闲率检查（1 分钟，要求 >98%）"
IDLE=$(mpstat 6 10 | awk '/Average/ {print $NF}')
echo "    平均空闲: ${IDLE}%"
echo "$IDLE" > "$ENV_DIR/idle_baseline.txt"
awk -v i="$IDLE" 'BEGIN{exit !(i >= 98.0)}' || { echo "FATAL: 空闲率不足，排查干扰进程（top / systemctl list-timers）"; exit 2; }

echo "==> 4. 干扰源提示（人工确认以下输出是否可接受）"
echo "    -- 活跃定时器（关注 unattended-upgrades / apt / man-db）:"
systemctl list-timers --no-pager 2>/dev/null | head -15 || true
echo "    -- 推荐临时停用: systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer"

echo
echo "==> 完成。基线已存 $ENV_DIR，可以开始测试。"
