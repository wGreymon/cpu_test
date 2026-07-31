#!/usr/bin/env bash
# 01_setup_tools.sh — 测试工具安装脚本（平台通用版）
# 支持：Ubuntu/Debian(apt) 与 RHEL/CentOS/Fedora(dnf)，x86_64 与 aarch64
# 自动探测：包管理器、CPU 架构、L3 容量（决定 STREAM 数组大小）
# 用法：sudo bash 01_setup_tools.sh
#       网络慢时: sudo GITHUB_MIRROR="https://ghfast.top/https://github.com" bash 01_setup_tools.sh
# 幂等：已装好的工具跳过；结束时打印版本清单到 tools/VERSIONS.txt
set -uo pipefail

ROOT_DIR="${ROOT_DIR:-$HOME/cpu_test}"
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

[[ "$(uname -s)" == "Linux" ]] || { echo "只能在 Linux 测试机上运行"; exit 1; }
[[ "$(id -u)" == "0" ]] || { echo "需要 root（sudo bash $0）"; exit 1; }

# ---------------- 平台探测 ----------------
ARCH="$(uname -m)"                       # x86_64 / aarch64
if command -v apt-get >/dev/null; then PKG=apt
elif command -v dnf  >/dev/null; then PKG=dnf
else echo "不支持的包管理器（需要 apt 或 dnf）"; exit 1; fi

# L3 总量（MiB）→ STREAM 数组大小：每数组 ≥ 4×L3 总量（规范 MEM-01）
L3_MIB=$(lscpu | awk -F: '/L3 cache/{gsub(/[^0-9. ]/,"",$2); split($2,a," "); print a[1]; exit}')
L3_MIB=${L3_MIB:-32}   # 读不到时按 32MiB 保守值
STREAM_SIZE=$(( L3_MIB * 1024 * 1024 * 4 / 8 ))          # 元素数（double=8B）
STREAM_SIZE=$(( (STREAM_SIZE / 10000000 + 1) * 10000000 )) # 向上取整到千万
STREAM_BYTES_TOTAL=$(( STREAM_SIZE * 8 * 3 ))
# 静态数组超 2GB 需要更大的代码模型（x86 用 medium，aarch64 用 large）
MCMODEL=""
if (( STREAM_BYTES_TOTAL > 2147483648 )); then
    [[ "$ARCH" == "x86_64" ]] && MCMODEL="-mcmodel=medium" || MCMODEL="-mcmodel=large"
fi

echo "平台探测: ARCH=$ARCH  PKG=$PKG  L3=${L3_MIB}MiB  STREAM_ARRAY_SIZE=$STREAM_SIZE ($((STREAM_BYTES_TOTAL/1024/1024/1024))GB/3数组) $MCMODEL"

# ---------------------------------------------------------------
log "1/6 基础包（编译环境 + 系统工具 + 发行版版本可用的基准工具）"
if [[ "$PKG" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q \
        build-essential git wget jq unzip xz-utils \
        libtirpc-dev \
        numactl hwloc sysstat dmidecode ipmitool \
        linux-tools-common "linux-tools-$(uname -r)" \
        fio sysbench stress-ng rt-tests memtester zstd \
        edac-utils cargo \
        || FAIL+=("apt 基础包（检查上面报错的具体包名）")
else
    dnf groupinstall -y -q "Development Tools" 2>/dev/null || true
    dnf install -y -q \
        git wget jq unzip xz \
        libtirpc-devel \
        numactl hwloc sysstat dmidecode ipmitool \
        perf kernel-tools \
        fio sysbench stress-ng rt-tests memtester zstd \
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
log "3/6 lmbench（intel fork，记录 commit）"
if [[ ! -d "$SRC/lmbench" ]]; then
    cd "$SRC"
    git clone -q "$GH/intel/lmbench.git" \
        && cd lmbench \
        && git rev-parse HEAD > LMBENCH_COMMIT.txt \
        && make -s build CFLAGS="-O2 -I/usr/include/tirpc" LDFLAGS="-ltirpc" 2>build.log \
        || FAIL+=("lmbench（看 $SRC/lmbench/build.log）")
fi
LMBIN=$(ls -d "$SRC"/lmbench/bin/*/ 2>/dev/null | head -1)
[[ -n "${LMBIN:-}" ]] && for f in lat_syscall lat_proc lat_ctx lat_mem_rd bw_mem; do
    [[ -x "$LMBIN/$f" ]] && ln -sf "$LMBIN/$f" "$BIN/$f"
done

# ---------------------------------------------------------------
log "4/6 7-Zip 24.08 官方版 / core-to-core-latency"
if [[ ! -x "$BIN/7zz" ]]; then
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
if [[ ! -x "$TOOLS/bin/core-to-core-latency" ]]; then
    export CARGO_HOME="$SRC/cargo"
    cargo install -q core-to-core-latency --root "$TOOLS" 2>/dev/null \
        || FAIL+=("core-to-core-latency（cargo install 失败，可 git clone 后 cargo build --release）")
fi

# ---------------------------------------------------------------
log "5/6 STREAM 5.10（按本机 L3=${L3_MIB}MiB 定制编译）+ Silesia 数据集"
if [[ ! -x "$BIN/stream" ]]; then
    cd "$SRC"
    # 校验内容而非仅存在性：下载失败会留下空文件
    if ! grep -q "STREAM" stream.c 2>/dev/null; then
        rm -f stream.c
        $WGET https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c -O stream.c \
            && grep -q "STREAM" stream.c \
            || { rm -f stream.c; FAIL+=("stream.c 下载"); }
    fi
    if [[ -s stream.c ]]; then
        gcc -O3 -fopenmp $MCMODEL \
            -DSTREAM_ARRAY_SIZE=$STREAM_SIZE -DNTIMES=20 \
            stream.c -o "$BIN/stream" \
            && echo "STREAM_ARRAY_SIZE=$STREAM_SIZE NTIMES=20 MCMODEL=$MCMODEL L3_MIB=$L3_MIB" > "$TOOLS/stream_build.txt" \
            || FAIL+=("STREAM 编译")
    fi
fi
if [[ ! -f "$ROOT_DIR/workloads/silesia.tar" ]]; then
    cd "$ROOT_DIR/workloads"
    # 优先使用已放置的本地 zip（scp/同步过来的），完整性校验通过才解压；
    # 没有或损坏才从原站下载（慢，约 68MB @ 数十KB/s）
    unzip -tq silesia.zip >/dev/null 2>&1 || {
        rm -f silesia.zip silesia.zip.*
        $WGET https://sun.aei.polsl.pl/~sdeor/corpus/silesia.zip -O silesia.zip
    }
    unzip -tq silesia.zip >/dev/null 2>&1 \
        && rm -rf silesia && unzip -q silesia.zip -d silesia && tar cf silesia.tar silesia \
        && sha256sum silesia.tar > silesia.tar.sha256 && rm -rf silesia \
        || FAIL+=("Silesia 数据集：在网络快的机器下载 https://sun.aei.polsl.pl/~sdeor/corpus/silesia.zip 后放到 workloads/ 重跑")
fi

# ---------------------------------------------------------------
if [[ "$ARCH" == "x86_64" ]]; then
    log "6/6 Intel MLC v3.11（x86 专用；尝试自动下载，失败则手动）"
    if [[ ! -x "$BIN/mlc" ]]; then
        cd "$SRC" && mkdir -p mlc && cd mlc
        # 使用仓库自带的安装包（workloads/dist/mlc_v*.tgz，版本以实际文件为准）
        # Intel 直链编号每版失效，不提供自动下载；获取方式见
        # https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html
        MLC_PKG=$(ls "$ROOT_DIR"/workloads/dist/mlc_v*.tgz 2>/dev/null | head -1)
        if [[ -n "$MLC_PKG" ]]; then
            tar xf "$MLC_PKG" -C . 2>/dev/null && ln -sf "$PWD/Linux/mlc" "$BIN/mlc" \
                || FAIL+=("Intel MLC：$MLC_PKG 解压失败，检查包完整性")
        else
            FAIL+=("Intel MLC：从官网下载 mlc_v*.tgz 放到 workloads/dist/ 后重跑（浏览器访问上面注释里的页面）")
        fi
    fi
else
    log "6/6 tinymembench（ARM 平台的 MLC 替代）"
    if [[ ! -x "$BIN/tinymembench" ]]; then
        cd "$SRC"
        git clone -q "$GH/ssvb/tinymembench.git" \
            && make -C tinymembench -s \
            && git -C tinymembench rev-parse HEAD > tinymembench/COMMIT.txt \
            && ln -sf "$SRC/tinymembench/tinymembench" "$BIN/tinymembench" \
            || FAIL+=("tinymembench")
    fi
fi
# 按需再装的可选工具（本脚本不安装）：
#   Geekbench 6（CPU-07 备选，确认无 SPEC 授权后再装）:
#     wget https://cdn.geekbench.com/Geekbench-6.3.0-Linux.tar.gz && tar xf ... （ARM 用 LinuxARMPreview 包）
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
    echo "turbostat: $(turbostat --version 2>&1 | head -1)"
    MLC_VER=$("$BIN/mlc" --version 2>&1 | head -1); echo "mlc:       ${MLC_VER:-未安装/非x86}"
    echo "tinymembench: $(cat "$SRC/tinymembench/COMMIT.txt" 2>/dev/null || echo '未安装/非ARM')"
    echo "lmbench:   commit $(cat "$SRC/lmbench/LMBENCH_COMMIT.txt" 2>/dev/null || echo '未安装')"
    echo "unixbench: 5.1.3 ($SRC/byte-unixbench-5.1.3)"
    echo "stream:    5.10, $(cat "$TOOLS/stream_build.txt" 2>/dev/null || echo '未编译')"
    # c2c 不支持 --version，用 cargo 安装清单取版本号
    C2C_VER=$(CARGO_HOME="$SRC/cargo" cargo install --list --root "$TOOLS" 2>/dev/null | awk '/^core-to-core-latency/{print $2}')
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
