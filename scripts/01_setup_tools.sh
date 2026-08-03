#!/usr/bin/env bash
# 01_setup_tools.sh — 测试工具安装脚本（平台通用版）
# 支持：Ubuntu/Debian(apt) 与 RHEL/CentOS/Fedora(dnf)，x86_64 与 aarch64
# 自动探测：包管理器、CPU 架构、L3 容量（决定 STREAM 数组大小）
# 用法：sudo bash 01_setup_tools.sh
#       网络慢时: sudo GITHUB_MIRROR="https://ghfast.top/https://github.com" bash 01_setup_tools.sh
#       正式对比: 各平台使用相同 STREAM_ARRAY_MIB（每个数组的 MiB）
# 幂等：已装好的工具跳过；结束时打印版本清单到 tools/VERSIONS.txt
set -uo pipefail
export LC_ALL=C

# 项目根目录按脚本位置推导（scripts/ 的上一级），不依赖 $HOME/sudo 环境
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOOLS="$ROOT_DIR/tools"
SRC="$TOOLS/src"
BIN="$TOOLS/bin"
mkdir -p "$SRC" "$BIN" "$ROOT_DIR"/{configs,workloads,scripts,results/raw,results/processed,reports}

FAIL=()
log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mWARN: $*\033[0m"; }

# GitHub 加速：网络慢时用镜像前缀重跑
GH="${GITHUB_MIRROR:-https://github.com}"
WGET="wget --timeout=30 --tries=2 --show-progress -q"

# 版本锁定（规范 §0.1）：跨平台必须完全一致
LMBENCH_COMMIT="a33716428dc2e717ce3e7dfce767302583eb8fdc"
STREAM_COMMIT="6703f7504a38a8da96b353cadafa64d3c2d7a2d3"
STREAM_SHA="c388924eb140fda95f534cdb808ae7f1f8ebb18da41d8aec1b512a3c8d303c9b"
TINYMEMBENCH_COMMIT="a2cf6d7e382e3aea1eb39173174d9fa28cad15f3"
C2C_VERSION="1.2.0"
SILESIA_TAR_SHA="5f6103f1cff22287f378f52c36c4ba9fb1fc2865edf6e0ab4206913dee65a6d6"

[[ "$(uname -s)" == "Linux" ]] || { echo "只能在 Linux 测试机上运行"; exit 1; }
[[ "$(id -u)" == "0" ]] || { echo "需要 root（sudo bash $0）"; exit 1; }

# ---------------- 平台探测 ----------------
ARCH="$(uname -m)"                       # x86_64 / aarch64
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/{gsub(/[[:space:]]/, "", $2); print $2; exit}')
if command -v apt-get >/dev/null; then PKG=apt
elif command -v dnf  >/dev/null; then PKG=dnf
else echo "不支持的包管理器（需要 apt 或 dnf）"; exit 1; fi

# L3 总量（MiB）→ STREAM 数组大小：每数组 ≥ 4×L3 总量（规范 MEM-01）。
# lscpu -B 可避免把 GiB/ MiB 单位误读；旧版 lscpu 则回退到带单位解析。
detect_l3_mib() {
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
L3_MIB=$(detect_l3_mib)
STREAM_ARRAY_MIB="${STREAM_ARRAY_MIB:-$(( L3_MIB * 4 ))}"
[[ "$STREAM_ARRAY_MIB" =~ ^[0-9]+$ ]] && (( STREAM_ARRAY_MIB > 0 )) \
    || { echo "STREAM_ARRAY_MIB 必须是正整数（MiB）"; exit 1; }
STREAM_SIZE=$(( STREAM_ARRAY_MIB * 1024 * 1024 / 8 ))       # 元素数（double=8B）
STREAM_SIZE=$(( (STREAM_SIZE + 9999999) / 10000000 * 10000000 )) # 向上取整到千万
STREAM_BYTES_TOTAL=$(( STREAM_SIZE * 8 * 3 ))
# 静态数组超 2GB 需要更大的代码模型（x86 用 medium，aarch64 用 large）
MCMODEL=""
if (( STREAM_BYTES_TOTAL > 2147483648 )); then
    [[ "$ARCH" == "x86_64" ]] && MCMODEL="-mcmodel=medium" || MCMODEL="-mcmodel=large"
fi

echo "平台探测: ARCH=$ARCH  PKG=$PKG  L3=${L3_MIB}MiB  STREAM_ARRAY_SIZE=$STREAM_SIZE（每数组约 ${STREAM_ARRAY_MIB}MiB，3 数组合计 $((STREAM_BYTES_TOTAL/1024/1024/1024))GiB） $MCMODEL"

# ---------------------------------------------------------------
log "1/6 基础包（编译环境 + 系统工具 + 发行版版本可用的基准工具）"
if [[ "$PKG" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q \
        build-essential git wget jq unzip xz-utils python3 \
        libtirpc-dev \
        numactl hwloc sysstat dmidecode ipmitool \
        fio sysbench stress-ng rt-tests memtester zstd openssl \
        edac-utils cargo \
        || FAIL+=("apt 基础包（检查上面报错的具体包名）")
    apt-get install -y -q linux-tools-common "linux-tools-$(uname -r)" \
        || apt-get install -y -q linux-tools-generic \
        || FAIL+=("perf/turbostat 内核工具（当前内核可能需要厂商对应的软件包）")
else
    dnf groupinstall -y -q "Development Tools" 2>/dev/null || true
    dnf install -y -q \
        git wget jq unzip xz python3 \
        libtirpc-devel \
        numactl hwloc sysstat dmidecode ipmitool \
        perf kernel-tools \
        fio sysbench stress-ng rt-tests memtester zstd openssl \
        edac-utils cargo \
        || FAIL+=("dnf 基础包（sysbench/stress-ng 可能需 EPEL: dnf install epel-release）")
fi

# ---------------------------------------------------------------
log "2/6 UnixBench 5.1.3（源码）"
if [[ ! -x "$SRC/byte-unixbench-5.1.3/UnixBench/Run" ]]; then
    cd "$SRC"
    $WGET "$GH/kdlucas/byte-unixbench/archive/refs/tags/v5.1.3.tar.gz" \
        -O unixbench-5.1.3.tar.gz \
        && tar xf unixbench-5.1.3.tar.gz \
        && make -C byte-unixbench-5.1.3/UnixBench -s \
        || FAIL+=("UnixBench")
else echo "已存在，跳过"; fi

# ---------------------------------------------------------------
log "3/6 lmbench（intel fork，锁定 commit ${LMBENCH_COMMIT:0:7}）"
if [[ ! -d "$SRC/lmbench" ]]; then
    cd "$SRC"
    git clone -q "$GH/intel/lmbench.git" || FAIL+=("lmbench clone")
fi
if [[ -d "$SRC/lmbench/.git" ]]; then
    LMBENCH_CURRENT=$(git -C "$SRC/lmbench" rev-parse HEAD 2>/dev/null || true)
    if [[ "$LMBENCH_CURRENT" != "$LMBENCH_COMMIT" ]]; then
        git -C "$SRC/lmbench" fetch -q origin "$LMBENCH_COMMIT" \
            && git -C "$SRC/lmbench" checkout -q "$LMBENCH_COMMIT" \
            || FAIL+=("lmbench 无法切换到锁定 commit（检查 tools/src/lmbench 是否有本地修改）")
    fi
    if [[ "$(git -C "$SRC/lmbench" rev-parse HEAD 2>/dev/null)" == "$LMBENCH_COMMIT" ]]; then
        make -C "$SRC/lmbench" -s build CFLAGS="-O2 -I/usr/include/tirpc" \
            LDFLAGS="-ltirpc" 2>"$SRC/lmbench/build.log" \
            && printf '%s\n' "$LMBENCH_COMMIT" > "$SRC/lmbench/LMBENCH_COMMIT.txt" \
            || FAIL+=("lmbench（看 $SRC/lmbench/build.log）")
    fi
else
    FAIL+=("lmbench 目录存在但不是 Git 仓库：$SRC/lmbench")
fi
LMBIN=$(ls -d "$SRC"/lmbench/bin/*/ 2>/dev/null | head -1)
[[ -n "${LMBIN:-}" ]] && for f in lat_syscall lat_proc lat_ctx lat_mem_rd bw_mem; do
    [[ -x "$LMBIN/$f" ]] && ln -sf "$LMBIN/$f" "$BIN/$f"
done

# ---------------------------------------------------------------
log "4/6 7-Zip 24.08 官方版 / core-to-core-latency"
SEVEN_ACTUAL=$("$BIN/7zz" 2>/dev/null | head -2 | tail -1 || true)
if [[ ! -x "$BIN/7zz" || "$SEVEN_ACTUAL" != *"24.08"* ]]; then
    case "$ARCH" in
        x86_64)  SEVENZIP=7z2408-linux-x64.tar.xz ;;
        aarch64) SEVENZIP=7z2408-linux-arm64.tar.xz ;;
        *)       SEVENZIP="" ;;
    esac
    if [[ -n "$SEVENZIP" ]]; then
        cd "$SRC" && mkdir -p 7zip && cd 7zip
        # 优先使用仓库自带的安装包（workloads/dist/），没有才下载
        [[ -f "$ROOT_DIR/workloads/dist/$SEVENZIP" ]] \
            && cp "$ROOT_DIR/workloads/dist/$SEVENZIP" . \
            || $WGET "https://www.7-zip.org/a/$SEVENZIP"
        tar xf "$SEVENZIP" 2>/dev/null && ln -sf "$PWD/7zz" "$BIN/7zz" \
            || FAIL+=("7-Zip 24.08：在网络快的机器下载 https://www.7-zip.org/a/$SEVENZIP 放到 workloads/dist/ 后重跑")
    else warn "未知架构 $ARCH，跳过 7-Zip"; fi
fi
export CARGO_HOME="$SRC/cargo"
C2C_CURRENT=$(cargo install --list --root "$TOOLS" 2>/dev/null \
    | awk '/^core-to-core-latency/{gsub(/:$/, "", $2); print $2; exit}')
if [[ ! -x "$TOOLS/bin/core-to-core-latency" || "$C2C_CURRENT" != "v$C2C_VERSION" ]]; then
    cargo install -q --force core-to-core-latency --version "$C2C_VERSION" --root "$TOOLS" 2>/dev/null \
        || FAIL+=("core-to-core-latency（cargo install --version $C2C_VERSION 失败）")
fi

# ---------------------------------------------------------------
log "5/6 STREAM 5.10（L3=${L3_MIB}MiB，每数组目标=${STREAM_ARRAY_MIB}MiB）+ Silesia 数据集"
STREAM_BUILD_KEY="STREAM_COMMIT=$STREAM_COMMIT STREAM_ARRAY_SIZE=$STREAM_SIZE NTIMES=20 MCMODEL=$MCMODEL L3_MIB=$L3_MIB STREAM_ARRAY_MIB=$STREAM_ARRAY_MIB"
if [[ ! -x "$BIN/stream" ]] || ! grep -Fqx "$STREAM_BUILD_KEY" "$TOOLS/stream_build.txt" 2>/dev/null; then
    cd "$SRC"
    # 从锁定 commit 下载到临时文件，校验通过后再替换，避免半截文件污染源码。
    if [[ "$(sha256sum stream.c 2>/dev/null | awk '{print $1}')" != "$STREAM_SHA" ]]; then
        STREAM_TMP="$SRC/stream.c.download"
        $WGET "$GH/jeffhammond/STREAM/raw/$STREAM_COMMIT/stream.c" -O "$STREAM_TMP" \
            && echo "$STREAM_SHA  $STREAM_TMP" | sha256sum -c --quiet - \
            && mv "$STREAM_TMP" "$SRC/stream.c" \
            || { rm -f "$STREAM_TMP"; FAIL+=("stream.c 锁定版本下载或校验失败"); }
    fi
    if [[ "$(sha256sum stream.c 2>/dev/null | awk '{print $1}')" == "$STREAM_SHA" ]]; then
        gcc -O3 -fopenmp $MCMODEL \
            -DSTREAM_ARRAY_SIZE=$STREAM_SIZE -DNTIMES=20 \
            stream.c -o "$BIN/stream" \
            && { echo "$STREAM_BUILD_KEY"
                 echo "stream.c $(sha256sum stream.c | awk '{print $1}')"; } > "$TOOLS/stream_build.txt" \
            || FAIL+=("STREAM 编译")
    fi
fi
SEVEN_ACTUAL=$("$BIN/7zz" 2>/dev/null | head -2 | tail -1 || true)
[[ "$SEVEN_ACTUAL" == *"24.08"* ]] || FAIL+=("7-Zip 实际版本不是 24.08")
if [[ ! -f "$ROOT_DIR/workloads/silesia.tar" ]]; then
    cd "$ROOT_DIR/workloads"
    # 优先使用已放置的本地 zip（scp/同步过来的），完整性校验通过才解压；
    # 没有或损坏才从原站下载（慢，约 68MB @ 数十KB/s）
    unzip -tq silesia.zip >/dev/null 2>&1 || {
        rm -f silesia.zip silesia.zip.*
        $WGET https://sun.aei.polsl.pl/~sdeor/corpus/silesia.zip -O silesia.zip
    }
    if ! SILESIA_TMP=$(mktemp -d "$ROOT_DIR/workloads/.silesia_extract.XXXXXX"); then
        FAIL+=("Silesia 数据集：无法创建临时解压目录")
    else
        mkdir -p "$SILESIA_TMP/silesia"
        if unzip -tq silesia.zip >/dev/null 2>&1 \
            && unzip -q silesia.zip -d "$SILESIA_TMP/silesia" \
            && tar cf silesia.tar -C "$SILESIA_TMP" silesia \
            && sha256sum silesia.tar > silesia.tar.sha256; then
            find "$SILESIA_TMP" -depth -mindepth 1 -delete && rmdir "$SILESIA_TMP"
        else
            FAIL+=("Silesia 数据集：在网络快的机器下载 https://sun.aei.polsl.pl/~sdeor/corpus/silesia.zip 后放到 workloads/ 重跑；失败的临时目录保留在 $SILESIA_TMP")
        fi
    fi
fi
# 无论新建还是已存在，都强制核对规范锁定的 SHA-256（保证跨平台数据集完全一致）
if [[ -f "$ROOT_DIR/workloads/silesia.tar" ]]; then
    echo "$SILESIA_TAR_SHA  $ROOT_DIR/workloads/silesia.tar" | sha256sum -c --quiet - 2>/dev/null \
        && printf '%s  %s\n' "$SILESIA_TAR_SHA" silesia.tar > "$ROOT_DIR/workloads/silesia.tar.sha256" \
        || FAIL+=("Silesia 校验失败：silesia.tar 与规范锁定 SHA-256 不符，删除 workloads/silesia.tar 后重跑")
fi

# ---------------------------------------------------------------
if [[ "$ARCH" == "x86_64" ]]; then
    MLC_REQUIRED=0
    [[ "$CPU_VENDOR" == "GenuineIntel" ]] && MLC_REQUIRED=1
    MLC_REQUESTED="${ENABLE_MLC_ON_AMD:-0}"
    if (( MLC_REQUIRED )); then
        log "6/6 Intel MLC v3.12（Intel 平台必需）"
    else
        log "6/6 Intel MLC v3.12（非 Intel 平台默认跳过，仅作可选兼容性验证）"
    fi
    MLC_PKG="$ROOT_DIR/workloads/dist/mlc_v3.12.tgz"
    MLC_ACTUAL=$("$BIN/mlc" --version 2>&1 | head -1 || true)
    # Intel 必须安装；AMD 默认完全跳过，只有明确请求兼容性验证才安装，
    # 不因仓库里恰好同步了 Intel 安装包而改变 AMD 的默认环境。
    if (( MLC_REQUIRED )) || [[ "$MLC_REQUESTED" == "1" ]]; then
        if [[ ! -x "$BIN/mlc" || "$MLC_ACTUAL" != *"v3.12"* ]]; then
            cd "$SRC" && mkdir -p mlc && cd mlc
            if [[ -f "$MLC_PKG" ]]; then
                tar xf "$MLC_PKG" -C . 2>/dev/null && ln -sf "$PWD/Linux/mlc" "$BIN/mlc" \
                    || FAIL+=("Intel MLC：$MLC_PKG 解压失败，检查包完整性")
            elif (( MLC_REQUIRED )) || [[ "$MLC_REQUESTED" == "1" ]]; then
                FAIL+=("Intel MLC：从官网下载 mlc_v3.12.tgz 放到 workloads/dist/ 后重跑")
            fi
        fi
        MLC_ACTUAL=$("$BIN/mlc" --version 2>&1 | head -1 || true)
        if { (( MLC_REQUIRED )) || [[ "$MLC_REQUESTED" == "1" ]]; } \
            && [[ "$MLC_ACTUAL" != *"v3.12"* ]]; then
            FAIL+=("Intel MLC 实际版本不是 v3.12")
        elif [[ -x "$BIN/mlc" && "$MLC_ACTUAL" != *"v3.12"* ]]; then
            warn "可选 MLC 实际版本不是 v3.12，AMD 兼容性数据不得用于正式对比"
        fi
    else
        echo "AMD/其他 x86 平台默认跳过 MLC；兼容性验证时设置 ENABLE_MLC_ON_AMD=1。"
    fi
fi
# tinymembench：所有架构都装（MEM-07 cache/TLB 辅助曲线）
log "tinymembench（锁定 commit ${TINYMEMBENCH_COMMIT:0:7}，MEM-07 随机访问）"
if [[ ! -d "$SRC/tinymembench" ]]; then
    cd "$SRC"
    git clone -q "$GH/ssvb/tinymembench.git" || FAIL+=("tinymembench clone")
fi
if [[ -d "$SRC/tinymembench/.git" ]]; then
    TINY_CURRENT=$(git -C "$SRC/tinymembench" rev-parse HEAD 2>/dev/null || true)
    if [[ "$TINY_CURRENT" != "$TINYMEMBENCH_COMMIT" ]]; then
        git -C "$SRC/tinymembench" fetch -q origin "$TINYMEMBENCH_COMMIT" \
            && git -C "$SRC/tinymembench" checkout -q "$TINYMEMBENCH_COMMIT" \
            || FAIL+=("tinymembench 无法切换到锁定 commit（检查源码目录是否有本地修改）")
    fi
    if [[ "$(git -C "$SRC/tinymembench" rev-parse HEAD 2>/dev/null)" == "$TINYMEMBENCH_COMMIT" ]]; then
        make -C "$SRC/tinymembench" -s \
            && printf '%s\n' "$TINYMEMBENCH_COMMIT" > "$SRC/tinymembench/COMMIT.txt" \
            && ln -sf "$SRC/tinymembench/tinymembench" "$BIN/tinymembench" \
            || FAIL+=("tinymembench 编译")
    fi
else
    FAIL+=("tinymembench 目录存在但不是 Git 仓库：$SRC/tinymembench")
fi

# 固定种子大工作集 pointer chase：tinymembench 0.4.9 最大仅 64MiB，
# 在大缓存服务器上不足以越过 LLC，因此 MEM-07 以此程序作为 DRAM 主数据。
log "pointer_chase（项目内固定源码，MEM-07 大工作集主数据）"
POINTER_SRC="$ROOT_DIR/workloads/pointer_chase.c"
if [[ -f "$POINTER_SRC" ]]; then
    gcc -O2 -std=c11 -Wall -Wextra "$POINTER_SRC" -o "$BIN/pointer_chase" \
        || FAIL+=("pointer_chase 编译")
else
    FAIL+=("缺少 $POINTER_SRC")
fi
# 按需再装的可选工具（本脚本不安装）：
#   fs_mark（OS-06 小文件补充测试）:
#     git clone https://github.com/josefbacik/fs_mark && make

# ---------------------------------------------------------------
log "版本清单 → $TOOLS/VERSIONS.txt"
{
    echo "# 生成时间: $(date -Iseconds)  主机: $(hostname)  架构: $ARCH  包管理器: $PKG"
    echo "kernel:    $(uname -r)"
    echo "microcode: $(grep -m1 microcode /proc/cpuinfo | awk '{print $NF}')"
    echo "gcc:       $(gcc --version | head -1)"
    echo "fio:       $(fio --version 2>/dev/null)"
    echo "sysbench:  $(sysbench --version 2>/dev/null)"
    echo "stress-ng: $(stress-ng --version 2>/dev/null)"
    echo "zstd:      $(zstd --version 2>/dev/null)"
    echo "openssl:   $(openssl version 2>/dev/null)"
    echo "memtester: $(command -v memtester >/dev/null && { apt-cache policy memtester 2>/dev/null | awk '/Installed/{print $2}'; rpm -q memtester 2>/dev/null; } | grep -v '^$' | head -1)"
    echo "rt-tests:  $({ apt-cache policy rt-tests 2>/dev/null | awk '/Installed/{print $2}'; rpm -q rt-tests 2>/dev/null; } | grep -v '^$' | head -1)"
    echo "7zz:       $("$BIN/7zz" 2>/dev/null | head -2 | tail -1)"
    echo "perf:      $(perf --version 2>/dev/null)"
    if command -v turbostat >/dev/null 2>&1; then
        echo "turbostat: $(turbostat --version 2>&1 | head -1)"
    else
        echo "turbostat: 未安装"
    fi
    if [[ -x "$BIN/mlc" ]]; then
        MLC_VER=$("$BIN/mlc" --version 2>&1 | head -1)
    else
        MLC_VER="未安装/不适用"
    fi
    echo "mlc:       $MLC_VER"
    echo "tinymembench: $(cat "$SRC/tinymembench/COMMIT.txt" 2>/dev/null || echo '未安装')"
    if [[ -x "$BIN/pointer_chase" && -f "$POINTER_SRC" ]]; then
        echo "pointer_chase: $(sha256sum "$POINTER_SRC" | awk '{print $1}')"
    else
        echo "pointer_chase: 未编译"
    fi
    echo "lmbench:   commit $(cat "$SRC/lmbench/LMBENCH_COMMIT.txt" 2>/dev/null || echo '未安装')"
    [[ -x "$SRC/byte-unixbench-5.1.3/UnixBench/Run" ]] \
        && echo "unixbench: 5.1.3 ($SRC/byte-unixbench-5.1.3)" \
        || echo "unixbench: 未安装"
    echo "stream:    5.10, $(cat "$TOOLS/stream_build.txt" 2>/dev/null || echo '未编译')"
    # c2c 不支持 --version，用 cargo 安装清单取版本号
    C2C_VER=$(CARGO_HOME="$SRC/cargo" cargo install --list --root "$TOOLS" 2>/dev/null \
        | awk '/^core-to-core-latency/{gsub(/:$/, "", $2); print $2; exit}')
    [[ -x "$BIN/core-to-core-latency" ]] \
        && echo "c2c:       已安装 ${C2C_VER}" \
        || echo "c2c:       未安装"
    echo "silesia:   $(cat "$ROOT_DIR/workloads/silesia.tar.sha256" 2>/dev/null || echo '未下载')"
} | tee "$TOOLS/VERSIONS.txt"

echo
if (( ${#FAIL[@]} )); then
    echo -e "\033[1;31m以下项目失败，需要处理：\033[0m"
    printf '  - %s\n' "${FAIL[@]}"
    exit 2
else
    echo -e "\033[1;32m全部工具就绪。下一步：sudo bash 02_prepare_state.sh <platform_id>\033[0m"
fi
