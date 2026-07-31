# CPU 与 Agent 沙箱学习笔记（问答形式）

## 目录

- [Q1：Agent 沙箱的运行和管理是由 CPU 负责的吗，而不是 GPU 或其他并行计算设备？](#q1agent-沙箱的运行和管理是由-cpu-负责的吗而不是-gpu-或其他并行计算设备)
- [Q2：在 Linux 服务器上查看硬件信息常用哪些命令？](#q2在-linux-服务器上查看硬件信息常用哪些命令)
- [Q3：一个 Agent 会做哪些事情，又依赖哪些硬件性能？](#q3一个-agent-会做哪些事情又依赖哪些硬件性能)
- [Q4：针对不同性能指标，应该使用什么测试工具？](#q4针对不同性能指标应该使用什么测试工具)

---

## Q1：Agent 沙箱的运行和管理是由 CPU 负责的吗，而不是 GPU 或其他并行计算设备？

是的。Agent 沙箱的创建、运行管理和安全控制主要由 CPU 和操作系统完成，而不是由 GPU/NPU 负责。

```text
GPU/NPU：大模型推理、并行计算
   │
   ▼ 产生工具调用
Agent 调度程序（CPU）
   │
   ▼
沙箱管理（CPU + 操作系统/虚拟化）
   │
   ├── 创建进程、容器或 microVM
   ├── CPU/内存/进程数限制
   ├── 文件、网络和权限隔离
   ├── 超时、OOM 与资源回收
   └── 运行 Python、Shell、编译器等工具
```

更准确地说，沙箱不是"CPU 单独实现"的，而是以下组件共同实现：

- **CPU**：执行管理程序和沙箱内代码，提供虚拟化指令。
- **操作系统内核**：namespace、cgroup、seccomp、调度和内存管理。
- **容器或虚拟化运行时**：Docker、gVisor、Kata、Firecracker。
- **内存、磁盘和网络**：存放任务数据并提供 I/O。

GPU 只有在沙箱任务需要 CUDA、模型推理或其他并行计算时才参与。例如：

```text
沙箱内 Python 程序
    ├── 普通代码 → CPU
    └── CUDA 计算 → GPU
```

即使沙箱使用 GPU，容器创建、GPU 分配、权限检查、任务调度和销毁仍主要运行在 CPU；GPU 侧还要增加驱动、设备映射、MIG/IOMMU 等隔离机制。

因此测试可以明确分成：

1. **CPU 与操作系统的沙箱管理能力**：启动、调度、系统调用、并发、资源限制和回收。
2. **沙箱内工具任务性能**：Python、编译、检索、压缩等。
3. **可选的加速器任务**：沙箱访问 GPU/NPU 时的计算性能和设备隔离。
4. **大模型推理性能**：单独测试，不与沙箱管理性能混在一起。

---

## Q2：在 Linux 服务器上查看硬件信息常用哪些命令？

按"先看什么、再看什么"的顺序整理（也是测试前环境摸底的顺序）：

### 系统与内核

```bash
cat /etc/os-release      # 发行版名称和版本
uname -a                 # 内核版本、架构（x86_64 / aarch64）
cat /proc/cmdline        # 内核启动参数（含 mitigations、isolcpus 等）
```

### CPU

```bash
lscpu                    # 最常用：型号、插槽数、物理核/逻辑核、频率范围、
                         # 缓存容量、NUMA 划分、指令集 Flags、漏洞缓解状态
lscpu -e                 # 每个逻辑 CPU 一行：核编号、所属 socket/NUMA、在线状态
                         # （用于确定绑核编号，比如区分同一物理核的两个超线程）
cat /proc/cpuinfo        # 每核详细信息（lscpu 的原始数据来源）
lstopo-no-graphics       # 硬件拓扑树：socket → L3 → 核 → 超线程（hwloc 包）
```

看 lscpu 的关键字段：`Model name`（型号）、`Socket(s)` × `Core(s) per socket`（物理核数）、`Thread(s) per core`（是否开超线程）、`L3 cache`（决定 STREAM 的默认数组下限；正式对比取候选平台共同值）、`NUMA node(s)`。

### 内存

```bash
free -h                  # 总量、已用、可用
numactl --hardware       # NUMA 节点数、每节点内存量、节点间距离矩阵
                         # （距离 10=本地，>10=远端，差距越大 NUMA 效应越强）
sudo dmidecode -t memory # 每根内存条的型号、类型（DDR5/MRDIMM）、
                         # 实际运行频率（Speed vs Configured Speed）、厂商
```

### 存储与网络

```bash
lsblk -o NAME,MODEL,SIZE,ROTA,TRAN   # 磁盘型号、容量、ROTA=0 是 SSD、
                                     # TRAN 接口类型（sata/nvme）
df -h                    # 文件系统容量与挂载点
ifconfig 或 ip addr      # 网卡与 IP
ethtool <网卡名>         # 网卡速率（Speed 字段）
```

### 固件与功耗

```bash
sudo dmidecode -t bios   # BIOS/UEFI 版本
sudo ipmitool dcmi power reading   # 整机实时功耗（服务器 BMC，测能效必用）
sudo ipmitool sensor     # 温度、风扇、电压传感器
```

### 运行状态（测试前检查）

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
                         # 频率策略：测试必须是 performance，不能是 powersave
grep -r . /sys/devices/system/cpu/vulnerabilities/
                         # 安全缓解措施（mitigations）状态，跨平台对比必须记录
cat /sys/kernel/mm/transparent_hugepage/enabled   # 透明大页状态
mpstat 1 10              # CPU 空闲率（sysstat 包），确认机器无干扰负载
cat /proc/interrupts     # 每核中断计数，选绑核目标时避开中断最多的核
who; uptime              # 谁在用机器、负载均值
edac-util --report=full  # ECC 内存错误计数（有错说明内存条有硬件问题）
```

### 记忆要点

- `lscpu` + `numactl --hardware` + `free -h` 三条命令就能回答"这台机器什么规格"。
- `dmidecode` 读的是 BIOS 的 SMBIOS 表，能看到"硬件铭牌"信息（内存条型号、频率），这是 `lscpu`/`free` 看不到的。
- 性能测试前必查三样：governor 是否 performance、空闲率是否够高、mitigations 是否与对比机器一致。

---

## Q3：一个 Agent 会做哪些事情，又依赖哪些硬件性能？

### Agent 的基本运行循环

Agent 不是只调用一次大模型，而是一个由大模型驱动、不断调用工具完成任务的程序。典型运行循环如下：

```text
接收目标
  ↓
读取环境和上下文
  ↓
调用大模型进行推理与规划
  ↓
选择并调用工具
  ↓
在沙箱中执行命令或代码
  ↓
读取执行结果
  ↓
判断是否完成
  └── 未完成则继续下一轮
```

模型既可以在本地运行，也可以由远端 API 提供。使用 API 时，本地不承担模型推理，只负责构造请求、网络通信、解析响应、Agent 编排和工具执行。因此，评测 API Agent 的本地硬件时，应将模型 API 等待时间与本地执行时间分开。

### 1. Agent 调度与编排

模型返回工具调用后，Agent 程序需要：

- 解析 JSON 或其他结构化输出。
- 管理上下文、对话历史和任务状态。
- 调度一个或多个工具及子任务。
- 控制重试、超时、取消和错误恢复。
- 记录日志、轨迹和中间结果。

主要硬件依赖：

- 单核性能：影响单个 Agent 的编排响应速度。
- 多核和调度能力：影响多 Agent 并发。
- 缓存和内存延迟：影响大量短操作。
- 进程、线程或协程调度以及上下文切换影响并行子任务。

这一层通常计算量不大，但操作频繁且持续时间短。

### 2. 与模型服务端通信（API Agent）

本地会进行：

- 建立 HTTP/HTTPS 连接。
- TLS 加密与解密。
- 上传 Prompt、上下文和工具结果。
- 接收流式 Token。
- 管理连接池、并发请求、重试和限流。

主要依赖网络延迟、网络稳定性、高并发连接处理能力和 CPU 加密性能。远端模型的推理时间不应算作本地 CPU 性能。

### 3. 文件与代码检索

Coding Agent 经常执行：

```bash
find .
rg "关键字"
git status
git diff
git log
```

还可能遍历代码仓库、读取大量小文件、建立代码索引、解析 AST、搜索符号和计算文件差异。

主要硬件依赖：

- CPU 单核和整数性能。
- 缓存与内存延迟。
- 存储随机读取和小文件性能。
- 文件系统元数据性能。

### 4. 执行 Shell 命令

Agent 可能频繁调用 `ls`、`find`、`grep`、`sed`、`awk`、`git` 和 `curl`。每条命令都可能涉及进程创建、可执行文件和动态库加载、系统调用、管道通信、上下文切换以及 stdout/stderr 收集。

主要硬件依赖：

- `fork/exec` 延迟。
- 系统调用延迟。
- 上下文切换性能。
- 单核性能。
- 小文件和存储 I/O。

这也是 `lmbench`、`hackbench` 和 `perf bench` 与 Agent 场景相关的原因。

### 5. 生成并运行代码

Agent 可能生成并运行 Python、Shell、SQL、C/C++、Rust、Java 或 JavaScript/TypeScript 程序。运行过程可能包含解释器冷启动、依赖导入、json、文本或表格处理、数值计算、图像处理和数据库访问。

| 代码或任务类型 | 主要硬件依赖 |
|---|---|
| Python 启动和导包 | 单核、内存延迟、小文件 I/O |
| JSON、文本和日志处理 | 单核整数、缓存、内存 |
| NumPy、矩阵计算 | SIMD、浮点、多核、内存带宽 |
| 图像处理 | SIMD、多核、内存带宽 |
| 数据库查询 | 单核、内存、存储延迟 |
| 压缩与解压 | 整数性能、多核、内存带宽 |

### 6. 编译和测试代码

Coding Agent 常见操作：

```bash
gcc / clang
cargo build
npm install
pytest
make test
```

具体包括安装依赖、编译项目、运行单元测试、分析错误、修改代码和重复测试。

主要硬件依赖：

- 单核性能：影响串行编译阶段
- 多核性能：影响并行编译
- 进程创建与调度：影响大量编译子进程
- 内存容量与带宽：影响大量编译子进程
- 小文件 I/O、压缩和哈希影响依赖安装以及构建缓存。

这类任务是评价 CPU 对 Coding Agent 支持能力的重点。

### 7. 浏览器和网页操作

Browser Agent 会启动 Chromium、加载网页、执行 JavaScript、解析 DOM、截图、识别页面内容，以及下载或上传文件。

主要依赖 CPU 单核/多核性能、内存容量、网络延迟和图像编解码；部分任务还会使用 GPU 图形加速。浏览器实例的内存占用较高，往往会限制单机 Agent 的并发密度。

### 8. RAG 与数据库操作

知识型 Agent 可能切分文档、生成 Embedding、建立向量索引、搜索向量数据库、查询 SQLite/PostgreSQL/Elasticsearch，并对结果排序。

主要硬件依赖：

- 文本解析：单核和内存延迟。
- 本地 Embedding：CPU SIMD 或 GPU；若使用远端 API，则不消耗本地推理算力。
- 向量搜索：缓存、内存带宽和 SIMD。
- 数据库：内存容量、存储 IOPS、锁和调度。
- 远程数据库：网络延迟。

### 9. 创建和管理沙箱

执行模型生成的代码前，Agent 平台通常需要：

- 创建进程、容器或 microVM。
- 准备根文件系统并挂载工作目录。
- 设置 namespace、cgroup 和 seccomp。
- 限制 CPU、内存、进程数、运行时间和网络。
- 执行命令并收集 stdout、stderr 和退出码。
- 终止超时或 OOM 任务。
- 销毁沙箱并回收进程、挂载点和临时文件。

主要硬件依赖：

- 进程创建、系统调用和上下文切换。
- 页表、缺页处理和内存映射。
- 存储与镜像层读取。
- 内存容量。
- CPU 虚拟化能力。
- 多核调度与并发能力。

如果使用Firecracker、Kata等microVM，还依赖KVM、EPT/NPT和虚拟化切换性能。

### 10. 一个 Coding Agent 的完整实例

假设用户要求“修复某个代码仓库中的 Bug，并运行测试”，Agent 可能执行：

```text
1. 读取用户问题
2. 调用大模型分析问题
3. 创建沙箱
4. 挂载或复制 Git 仓库
5. 执行 rg/find/git 等检索命令
6. 读取相关源码
7. 再次调用大模型生成修改方案
8. 修改文件
9. 安装依赖
10. 编译项目
11. 运行单元测试
12. 读取错误日志
13. 再次调用模型修正代码
14. 重复编译和测试
15. 生成 git diff
16. 销毁沙箱并回收资源
```

对应的硬件路径：

```text
模型推理      → GPU/NPU（本地模型）或网络（远端 API）
Agent 编排    → CPU 单核、缓存、内存
仓库检索      → CPU、缓存、存储
沙箱创建      → CPU、内核、存储
项目编译      → CPU 单核/多核、内存、存储
单元测试      → CPU、进程调度、内存
并行 Agent    → 核数、内存容量、调度、I/O
```

### 11. 不同 Agent 的硬件特征

| Agent 类型 | 典型动作 | 主要硬件瓶颈 |
|---|---|---|
| Coding Agent | 检索、编译、测试 | CPU、内存、小文件 I/O |
| Terminal Agent | 大量短命令、脚本 | 系统调用、进程创建、调度 |
| 数据分析 Agent | Python、SQL、矩阵计算 | CPU SIMD、内存、存储 |
| Browser Agent | 浏览器、JavaScript、截图 | CPU、内存、网络 |
| RAG Agent | 文档解析、向量检索 | 内存带宽、SIMD、存储 |
| 多 Agent 平台 | 大量沙箱并发 | 核数、内存容量、调度、启动开销 |

不存在一种“通用 Agent 负载”可以代表所有场景，测试前必须先明确 Agent 类型。

### 12. Agent 测试的三个层级

#### 第一层：固定动作回放

不使用模型决策，直接运行固定命令序列：

```text
检索 → 修改 → 编译 → 测试
```

这样可以保证所有 CPU 执行完全相同的工作，适合硬件对比。记录总执行时间、各步骤耗时、CPU time、峰值内存、进程创建数和文件读写量。

#### 第二层：沙箱运行测试

在不同执行环境中回放同一组固定动作：

```text
裸机 → Docker/runc → gVisor → Kata/Firecracker
```

用于测量沙箱启动、任务运行和销毁开销。

#### 第三层：完整 Agent 端到端测试

让真实 Agent 自主规划并调用工具，评价任务成功率、端到端时间、模型调用次数、工具调用次数、沙箱运行时间、Token 数量和单任务资源消耗。

由于模型每次可能选择不同步骤，完整 Agent 测试适合评价业务表现，但不应单独用于精确比较 CPU。

### 13. Agent 行为与 CPU 测试的映射

| Agent 行为 | 应测试的 CPU/系统能力 |
|---|---|
| 频繁执行短命令 | 系统调用、`fork/exec`、上下文切换 |
| 代码和文本解析 | 单核、整数、缓存延迟 |
| 编译项目 | 单核、多核扩展、内存带宽、小文件 I/O |
| Python 启动与导包 | 进程创建、单核、小文件读取 |
| 数据处理 | SIMD、内存带宽、缓存 |
| 多 Agent 并发 | 核数、调度、公平性、NUMA |
| 创建沙箱 | 系统调用、文件系统、内存映射、虚拟化 |
| 大量沙箱常驻 | 内存容量、额外 RSS、并发密度 |
| 长时间运行 | 持续频率、温度、功耗、稳定性 |

### 记忆要点

- 对 Agent 平台而言，CPU 的价值不仅是“计算得多快”，还包括任务启动速度、并发调度稳定性、沙箱容量和资源回收效率。
- 使用远端模型 API 时，应分别记录模型 API 等待、Agent 本地编排、沙箱生命周期和工具执行时间。
- 为了制定可复现的 CPU 测试，现阶段可以优先研究 Coding/Terminal Agent，并先用固定动作回放建立基线。

---

## Q4：针对不同性能指标，应该使用什么测试工具？

测试工具应按“一个指标对应一个主要工具，必要时再用辅助工具交叉验证”的原则选择。不要用一个综合跑分代替所有指标，也不要把压力工具当成精确性能基准。

### 1. OS 能力

| 性能指标 | 主要工具 | 辅助工具 | 主要结果 |
|---|---|---|---|
| 系统调用延迟 | lmbench 套件中的 `lat_syscall` | `perf bench syscall` | ns/op、µs/op |
| 进程创建与 `fork/exec` | lmbench 套件中的 `lat_proc` | 固定次数的 `/bin/true` 创建脚本 | µs/次、次/s、P50/P95/P99 |
| 上下文切换 | lmbench 套件中的 `lat_ctx` | `perf bench sched pipe` | µs/次 |
| 高并发调度压力 | `hackbench` | `perf sched` | 完成时间、吞吐、抖动 |
| 系统综合表现 | `UnixBench` | SPEC CPU 子项 | 综合分和各子项分数 |

使用注意：

- lmbench 的 `-N` 表示内部重复轮数，不是原始样本数量，不能为了获得“100个样本”直接设为 `-N 100`。
- 系统调用、进程创建等微基准的正式成绩应在不包裹 `perf stat` 的情况下运行；`perf stat` 单独作为诊断轮次。
- P95/P99 需要足够多的原始样本。只有5次外层运行时，应报告中位数、最小值、最大值和CV。

### 2. CPU 计算能力

| 性能指标 | 主要工具 | 辅助工具 | 主要结果 |
|---|---|---|---|
| 单线程标量/整数密集计算 | `sysbench cpu` | 7-Zip 单线程基准 | events/s、MIPS |
| 多线程吞吐与扩展性 | `sysbench cpu`、7-Zip | SPEC CPU rate | 吞吐、加速比、并行效率 |
| 真实压缩与解压 | `zstd` + 固定 Silesia 数据集 | 7-Zip | 压缩/解压 MB/s、压缩率 |
| 加密与哈希 | `openssl speed` | SPEC CPU 对应负载 | MB/s、sign/s、verify/s |
| 浮点与 SIMD | 固定版本的 BLAS DGEMM 或 HPL | LIKWID Bench、CoreMark-Pro | GFLOPS、向量化效率 |
| 核间通信延迟 | `core-to-core-latency` | 自定义 ping-pong | 核对核延迟矩阵、ns |
| 权威综合计算性能 | SPEC CPU 2017 | Geekbench 6 | 单核/整机分数、rate |

这里的 `sysbench cpu` 主要反映质数计算产生的整数密集型标量负载，不能代表CPU全部计算能力。因此更准确的名称是“标量/通用计算”，并需要结合压缩、加密、编译等真实负载解释。

多核测试不是换一个工具，而是让同一个可并行负载分别使用1、25%、50%、100%物理核和全部逻辑核，绘制吞吐与线程数曲线。

### 3. 数据访问能力

数据访问能力分为两个子组：内存与 NUMA 是平台性能的核心组成部分；存储与文件系统 I/O 主要用于解释 Agent 真实任务的差异，不直接计入纯 CPU 排名。

#### 3.1 内存与 NUMA

| 性能指标 | 主要工具 | 辅助工具 | 主要结果 |
|---|---|---|---|
| 内存正确性 | `memtester` + sysfs EDAC 计数 | `edac-util`、BMC/厂商诊断 | 测试错误数、新增 ECC 错误数 |
| 顺序内存带宽 | STREAM | Intel MLC bandwidth | Copy/Scale/Add/Triad GB/s |
| 缓存与内存延迟阶梯 | lmbench 套件中的 `lat_mem_rd` | Intel MLC idle latency | L1/L2/L3/DRAM 延迟曲线、ns |
| NUMA 本地/远端延迟 | `numactl` + `lat_mem_rd` | MLC latency matrix | 节点间延迟矩阵、远端/本地比值 |
| NUMA 本地/远端带宽 | `numactl` + STREAM | MLC bandwidth matrix | 节点间带宽矩阵、GB/s |
| 带宽压力下的内存延迟 | Intel MLC loaded latency | 厂商等价工具 | 带宽—延迟曲线、拐点带宽 |
| 随机访问/指针追逐 | 固定种子的 `pointer_chase`（工作集大于L3） | tinymembench、sysbench memory | ns/访问、访问次数/s |

跨 Intel、AMD 或 ARM 平台时，共同比较基线应优先使用 `STREAM + lmbench + numactl`。Intel MLC 官方面向 Intel 平台；在 AMD 上只有经过兼容性和结果合理性验证后，才能作为补充数据，不能代替共同基线。

STREAM 不仅要保证每个数组大于缓存，正式横向对比还要保证各平台工作集相同：先取所有候选平台中最大的整机 L3，令每个数组至少为它的4倍，然后在各机器安装时传入同一个 `STREAM_ARRAY_MIB`。只按各机自己的 L3 分别编译，适合冒烟，不适合严格排名。

`sysbench memory --memory-block-size=8` 不适合代表大工作集随机DRAM访问，因为 `memory-total-size` 表示累计传输量，不等于实际随机访问的工作集容量。随机访问应使用真实的大数组指针追逐基准。

tinymembench 0.4.9 的随机延迟工作集最大只有64MiB，在大缓存服务器上可能完全落在LLC内，因此也不能单独作为随机DRAM主成绩。当前脚本使用项目内固定种子的 `pointer_chase`，默认工作集为 `max(2048MiB, 2×整机L3)`；正式跨平台比较时显式设置相同的 `POINTER_CHASE_MIB`，tinymembench保留为cache/TLB辅助曲线。

#### 3.2 存储与文件系统（辅助）

| 性能指标 | 主要工具 | 辅助工具 | 主要结果 |
|---|---|---|---|
| 4K随机读（当前脚本） | `fio` | `iostat` | IOPS、P50/P95/P99延迟 |
| 大块顺序读（当前脚本） | `fio` | `iostat` | MB/s、延迟、磁盘利用率 |
| 小文件创建与删除 | `fs_mark` | 自定义固定文件树 | files/s、延迟 |
| 文件系统元数据 | `fs_mark` 或 `filebench` | 固定仓库的 `find/rg/git` 回放 | files/s、任务完成时间 |

存储硬件不同会显著影响结果，因此存储测试通常只用于解释Agent任务差异，不应直接算进纯CPU排名。测试前必须记录磁盘型号、文件系统、挂载参数、I/O引擎和是否使用Direct I/O。fio 的大文件必须放在同步目录之外，否则 Mutagen/Git 等后台活动会同时污染空间占用和测试成绩；当前脚本默认使用远端 `/var/tmp/cpu_test_fio`。

### 4. 持续性能与能效

| 性能指标 | 主要工具 | 辅助工具 | 主要结果 |
|---|---|---|---|
| 长时间满载稳定性 | `stress-ng` 产生负载 | 固定业务负载持续回放 | 前后吞吐差、性能波动 |
| CPU频率、温度、封装功耗 | `turbostat`（x86） | `sensors`、BMC传感器 | MHz、℃、PkgWatt |
| 整机功耗 | 外置功率计或 PDU | `ipmitool dcmi power reading` | 平均功耗、峰值功耗、W |
| 能效 | 吞吐结果 + 整机功耗 | RAPL封装功耗 | task/s/W、J/task |

`stress-ng` 的主要作用是制造稳定压力和检查系统稳定性，其 bogo-ops 不应作为不同CPU计算性能的核心排名指标。能效对比必须统一使用整机功耗；RAPL只覆盖CPU封装，不能与整机功耗直接混比。

当前脚本用满物理核 `sysbench cpu` 在一小时压力前后各复测一次，以 `post/pre` 表示吞吐保持率；stress-ng 使用全部逻辑 CPU 负责造压。CPU-02 的能效采用独立 30 秒运行窗口，避免把预热、重复轮次和 `perf stat` 混入功耗平均值。MEM-00 日常门槛为每个 NUMA 节点 10GB，100GB/节点留作过夜专项检查。

### 补充：真实负载回放与测量方法

| Agent动作 | 推荐工具或负载 | 测量方式 |
|---|---|---|
| 仓库检索 | 固定版本仓库上的 `rg/find/git` | 完成时间、CPU time、缺页、小文件读取量 |
| Python启动与导包 | 固定Python环境和依赖 | 启动时间、峰值RSS、文件读取量 |
| 编译构建 | 固定源码和编译参数，运行 `make/cargo` | 总时间、单核/多核扩展、峰值RSS |
| 单元测试 | 固定测试集，如 `pytest` | 总时间、成功率、测试数/s |
| JSON/文本处理 | 固定输入文件和脚本 | MB/s、CPU time、峰值RSS |
| SQLite操作 | 固定数据库与查询集合 | queries/s、P95延迟 |
| 多任务并发 | 同一任务按1、2、4……并发运行 | 总吞吐、单任务延迟、公平性、失败率 |

固定动作回放可使用以下测量工具：

- `hyperfine`：预热、重复运行和统计耗时。
- `/usr/bin/time -v`：CPU time、峰值RSS、缺页、文件系统I/O。
- `perf stat`：作为独立诊断轮次采集IPC、cache miss、上下文切换和缺页。
- `pidstat`、`mpstat`、`iostat`：观察运行期间的CPU、调度与I/O状态。

### 选择工具时的记忆要点

- 微基准用于回答“为什么快或慢”，固定真实负载用于回答“实际任务谁更快”。
- 一个工具通常只能说明一个侧面；`sysbench`、UnixBench或Geekbench都不能单独代表CPU整体性能。
- `perf stat`是分析工具，不是主要跑分工具；`stress-ng`是压力工具，不是精确GFLOPS基准。
- 主结果必须使用跨平台共同工具，平台专用工具只作为补充解释。
- 工具版本、输入数据、编译参数、线程数、绑核和NUMA策略必须固定并记录。
- Mutagen 双向同步适合日常开发，但正式跑分前应先 `mutagen sync flush <会话名>`、`mutagen sync pause <会话名>`，跑完后再 `resume`；否则后台扫描和大文件传输会污染小文件、I/O 与调度类结果。
