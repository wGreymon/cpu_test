#!/usr/bin/env bash
# 01_setup_tools.sh — 测试工具安装脚本
# 目标机器：Ubuntu 24.04 x86_64（Intel Xeon 6966P-C，2 路 192 核，3TB MRDIMM）
# 用法：sudo bash 01_setup_tools.sh
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

# GitHub 加速：网络慢时用镜像前缀重跑，例如
#   sudo GITHUB_MIRROR="https://ghfast.top/https://github.com" bash 01_setup_tools.sh
GH="${GITHUB_MIRROR:-https://github.com}"
WGET="wget --timeout=30 --tries=2 --show-progress -q"

[[ "$(uname -s)" == "Linux" ]] || { echo "只能在 Linux 测试机上运行"; exit 1; }
[[ "$(id -u)" == "0" ]] || { echo "需要 root（sudo bash $0）"; exit 1; }

# ---------------------------------------------------------------
log "1/6 apt 基础包（编译环境 + 系统工具 + 发行版版本可用的基准工具）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
    build-essential git wget curl jq unzip xz-utils \
    automake autoconf libtool pkg-config \
    libnuma-dev libaio-dev libtirpc-dev \
    numactl hwloc sysstat dmidecode ipmitool \
    linux-tools-common "linux-tools-$(uname -r)" \
    fio sysbench stress-ng rt-tests memtester zstd \
    edac-utils \
    cargo \
    || FAIL+=("apt 基础包（检查上面报错的具体包名）")

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
    # 产物在 lmbench/bin/x86_64-linux-gnu*/ 下：lat_syscall lat_proc lat_ctx lat_mem_rd
    LMBIN=$(ls -d "$SRC"/lmbench/bin/*/ 2>/dev/null | head -1)
    [[ -n "${LMBIN:-}" ]] && for f in lat_syscall lat_proc lat_ctx lat_mem_rd bw_mem; do
        [[ -x "$LMBIN/$f" ]] && ln -sf "$LMBIN/$f" "$BIN/$f"
    done
else echo "已存在，跳过"; fi

# ---------------------------------------------------------------
log "4/6 fs_mark / 7-Zip 24.08 官方版 / core-to-core-latency"
if [[ ! -x "$BIN/fs_mark" ]]; then
    cd "$SRC"
    git clone -q "$GH/josefbacik/fs_mark.git" \
        && make -C fs_mark -s && ln -sf "$SRC/fs_mark/fs_mark" "$BIN/fs_mark" \
        || FAIL+=("fs_mark")
fi
if [[ ! -x "$BIN/7zz" ]]; then
    cd "$SRC" && mkdir -p 7zip && cd 7zip
    $WGET https://www.7-zip.org/a/7z2408-linux-x64.tar.xz \
        && tar xf 7z2408-linux-x64.tar.xz && ln -sf "$PWD/7zz" "$BIN/7zz" \
        || FAIL+=("7-Zip 24.08")
fi
if [[ ! -x "$BIN/core-to-core-latency" ]]; then
    export CARGO_HOME="$SRC/cargo"
    cargo install -q core-to-core-latency --root "$TOOLS" 2>/dev/null \
        || FAIL+=("core-to-core-latency（cargo install 失败，可 git clone 后 cargo build --release）")
fi

# ---------------------------------------------------------------
log "5/6 STREAM 5.10（按本机 L3=864MiB 定制编译）+ Silesia 数据集"
if [[ ! -x "$BIN/stream" ]]; then
    cd "$SRC"
    $WGET https://www.cs.virginia.edu/stream/FTP/Code/stream.c -O stream.c \
        || FAIL+=("stream.c 下载")
    # L3 总量 864MiB，数组 ≥4×L3：4*864MiB/8B ≈ 4.53 亿元素，取 4.6 亿（单数组 3.68GB，共 ~11GB）
    # 静态数组 >2GB 必须 -mcmodel=medium
    gcc -O3 -fopenmp -mcmodel=medium \
        -DSTREAM_ARRAY_SIZE=460000000 -DNTIMES=20 \
        stream.c -o "$BIN/stream" \
        || FAIL+=("STREAM 编译")
fi
if [[ ! -f "$ROOT_DIR/workloads/silesia.tar" ]]; then
    cd "$ROOT_DIR/workloads"
    $WGET https://sun.aei.polsl.pl/~sdeor/corpus/silesia.zip \
        && unzip -q silesia.zip -d silesia && tar cf silesia.tar silesia \
        && sha256sum silesia.tar > silesia.tar.sha256 && rm -rf silesia silesia.zip \
        || FAIL+=("Silesia 数据集（官网慢/挂时改用镜像后自行校验）")
fi

# ---------------------------------------------------------------
log "6/6 Intel MLC v3.11（尝试自动下载，失败则手动）"
if [[ ! -x "$BIN/mlc" ]]; then
    cd "$SRC" && mkdir -p mlc && cd mlc
    $WGET https://downloadmirror.intel.com/793041/mlc_v3.11.tgz \
        && tar xf mlc_v3.11.tgz && ln -sf "$PWD/Linux/mlc" "$BIN/mlc" \
        || FAIL+=("Intel MLC：请到 intel.com 搜索 'Memory Latency Checker' 手动下载 mlc_v3.11.tgz，解压后把 Linux/mlc 链接到 $BIN/")
fi
# Geekbench 6.3（CPU-07 备选，SPEC 无授权时用）
if [[ ! -x "$BIN/geekbench6" ]]; then
    cd "$SRC"
    $WGET https://cdn.geekbench.com/Geekbench-6.3.0-Linux.tar.gz \
        && tar xf Geekbench-6.3.0-Linux.tar.gz \
        && ln -sf "$SRC/Geekbench-6.3.0-Linux/geekbench6" "$BIN/geekbench6" \
        || warn "Geekbench 下载失败（可选项，不影响其他测试）"
fi

# ---------------------------------------------------------------
log "版本清单 → $TOOLS/VERSIONS.txt"
{
    echo "# 生成时间: $(date -Iseconds)  主机: $(hostname)"
    echo "kernel:    $(uname -r)"
    echo "gcc:       $(gcc --version | head -1)"
    echo "fio:       $(fio --version 2>/dev/null)"
    echo "sysbench:  $(sysbench --version 2>/dev/null)"
    echo "stress-ng: $(stress-ng --version 2>/dev/null)"
    echo "zstd:      $(zstd --version 2>/dev/null)"
    echo "openssl:   $(openssl version 2>/dev/null)"
    echo "memtester: $(apt-cache policy memtester 2>/dev/null | awk '/Installed/{print $2}')"
    echo "rt-tests:  $(apt-cache policy rt-tests 2>/dev/null | awk '/Installed/{print $2}')"
    echo "7zz:       $("$BIN/7zz" 2>/dev/null | head -2 | tail -1)"
    echo "perf:      $(perf --version 2>/dev/null)"
    echo "turbostat: $(turbostat --version 2>&1 | head -1)"
    echo "mlc:       $("$BIN/mlc" --version 2>&1 | head -1 || echo '未安装')"
    echo "lmbench:   commit $(cat "$SRC/lmbench/LMBENCH_COMMIT.txt" 2>/dev/null || echo '未安装')"
    echo "unixbench: 5.1.3 ($SRC/byte-unixbench-5.1.3)"
    echo "stream:    5.10, ARRAY_SIZE=460000000, NTIMES=20, gcc -O3 -fopenmp -mcmodel=medium"
    echo "c2c:       $("$BIN/core-to-core-latency" --version 2>/dev/null || echo '未安装')"
    echo "geekbench: $("$BIN/geekbench6" --version 2>/dev/null | head -1 || echo '未安装（可选）')"
    echo "silesia:   $(cat "$ROOT_DIR/workloads/silesia.tar.sha256" 2>/dev/null || echo '未下载')"
} | tee "$TOOLS/VERSIONS.txt"

echo
if (( ${#FAIL[@]} )); then
    echo -e "\033[1;31m以下项目失败，需要处理：\033[0m"
    printf '  - %s\n' "${FAIL[@]}"
    exit 2
else
    echo -e "\033[1;32m全部工具就绪。下一步：sudo bash 02_prepare_state.sh\033[0m"
fi
