# 第一部分测试规范：工具、命令与判定标准

> 版本：V0.8
> 配套文档：`CPU_AGENT_SANDBOX_TEST_PLAN.md` 第一部分；执行脚本：`scripts/`（10/20/30 三个执行脚本 + run_part1.sh 总控）
> 适用对象：Linux x86_64 / ARM64 服务器
>
> **V0.2 变更**（按 Intel Xeon 6966P-C 首测实际执行修订）：工具版本表对齐实测（MLC v3.12、rt-tests 2.5、zstd 1.5.5、lmbench 改用 intel fork 记录 commit；fs_mark 改为按需）；MEM-00 适配 TB 级内存改为按 NUMA 节点抽样 + EDAC 对比；OS-06 明确 direct=1 下的测试文件大小规则；固定 Silesia 数据集 SHA-256；UnixBench 整套只跑 1 遍的例外说明。
>
> **V0.3 变更**（评审修订，开跑全量前）：结果目录按批次（session_id）隔离防覆盖；主成绩不带 perf 包裹、改为独立 profiling 轮；lmbench `-N` 参数修正（100→5，-N 为内部重复轮数）；百分位报告口径收紧（外层 5 次只报中位数/极差/CV）；每核归一化仅适用于整机吞吐类；mitigations 跨厂商改为"生产默认+记录+解释差异"；MEM-00 升为硬门槛（解析 ECC 计数、失败即中止）；MEM-07 曾暂定 tinymembench 为主数据（该口径已在 V0.4 被大工作集 pointer_chase 取代）；MLC 在 AMD 需实机验证的说明。二轮复查补充：profiling 轮对长耗时/自带 perf/产出覆盖类用例跳过（NO_PROFILE）；环境基线随 session 存放；run_case 汇总失败状态、解析缺值显式告警；EDAC 不可用显式标记为缺项而非 0 错误。
>
> **V0.4 变更**（Intel 冒烟后）：正式结构统一为 OS 能力、CPU 计算能力、数据访问能力、持续性能与能效四类；修复 OpenSSL/stress-ng 指标解析和失败传播；同一 session 固定绑核；MEM-00 常规门槛改为每节点 10GB；功耗使用独立测量窗口并校验采集器；STREAM、lmbench、tinymembench、core-to-core-latency 和 MLC 均验证锁定版本；MEM-07 改用固定种子大工作集 pointer_chase，避免 64MiB 的 tinymembench 落在服务器 LLC 内。
>
> **V0.5 变更**（完整性复查）：全 CPU governor 改为硬门槛并记录 perf/NMI/EPP 状态；修正 GiB 级 L3 容量解析；正式跨平台对比要求 STREAM 每数组使用相同容量；AMD 默认不要求安装 Intel MLC；支持非连续 NUMA 节点编号；单线程 STREAM 固定绑核；JSON 补齐 NUMA、框架版本及暂缺资源字段。
>
> **V0.6 变更**：删除 CPU-07 SPEC CPU/Geekbench 综合基准。其通用计算内容与 CPU-01～05 重合，且不能代表 OS、内存、NUMA 与真实 Agent 工具负载；后续以固定 Agent 行为回放补充真实性验证。
>
> **V0.7 变更**（正式测试前定标）：CPU-06 仅选择每个物理核的一个硬件线程，显式使用 5000 次迭代×30 个样本，避免在 192C/384T 服务器上因遍历 SMT sibling 和工具默认 300 样本导致运行时间失控。
>
> **V0.8 变更**（Intel/AMD 首轮全量后）：UnixBench 5.1.3 的 system 类内置 `maxCopies=16`，将 OS-01 并行档由全部逻辑 CPU 改为两平台统一的 16 副本，避免高核数服务器静默跳过全部子项。
> 本文档回答三个问题：每项能力**用什么工具（含版本）**、**以什么方式运行（具体命令与流程）**、**按什么标准判定和对比结果**。

## 0. 通用规范（所有用例必须遵守）

### 0.1 工具版本固定表

所有平台使用同一工具版本和该工具约定的固定编译参数；分别使用架构原生二进制，不使用仿真。禁止一台机器额外启用激进的 `-march=native`/PGO 而另一台不用。STREAM 的参数见 MEM-01。

| 工具 | 固定版本 | 获取方式 | 用于 |
|---|---|---|---|
| UnixBench | 5.1.3 | github.com/kdlucas/byte-unixbench（源码编译） | OS-01 |
| lmbench | intel fork，锁定 commit a337164 | github.com/intel/lmbench（源码编译） | OS-02/03/04、MEM-02/03 |
| perf | 与内核同版本 | linux-tools | OS-02/04、辅助剖析 |
| hackbench | rt-tests 2.5 | 发行版包（Ubuntu 24.04） | OS-05 |
| fio | 3.36 | 发行版包 | OS-06 |
| sysbench | 1.0.20 | 发行版包 | CPU-01/02/08；MEM-07 参考项 |
| 7-Zip | 24.08 官方 Linux 二进制 | 仓库内置 workloads/dist/ | CPU-01/02 |
| zstd | 1.5.5（发行版包，两平台一致即可） | 发行版包 | CPU-04 |
| OpenSSL | 3.0.13（各平台同小版本） | 发行版包 | CPU-05 |
| core-to-core-latency | v1.2.0 | cargo install（crates.io） | CPU-06 |
| stress-ng | 0.17.x | 发行版包 | CPU-08 |
| turbostat | 与内核同版本 | linux-tools | CPU-08/09（x86） |
| ipmitool | 发行版包版本 | 发行版包 | CPU-09（整机功耗） |
| STREAM | 5.10，commit `6703f75`（正式对比固定相同数组容量） | github.com/jeffhammond/STREAM | MEM-01/04/06 |
| Intel MLC | v3.12（官方面向 Intel；AMD 仅兼容性验证） | 仓库内置 workloads/dist/ | MEM-02~05 补充项 |
| pointer_chase | 项目内固定源码（SHA-256 记入 versions.txt） | workloads/pointer_chase.c | MEM-07 大工作集主数据 |
| tinymembench | commit `a2cf6d7` | github.com/ssvb/tinymembench | MEM-07 cache/TLB 辅助曲线 |
| memtester | 4.6.0 | 发行版包 | MEM-00 |
| fs_mark | 按需（默认不装） | github.com/josefbacik/fs_mark | OS-06 补充 |

版本核对以各平台 `results/raw/<platform_id>/<session_id>/env/versions.txt`（安装脚本生成 `tools/VERSIONS.txt`，环境准备脚本复制到当批目录）为准。锁定工具必须与本表一致；发行版工具至少保证两平台同小版本，出现偏差时需注明并判断能否比较。

### 0.2 运行协议

1. **常规微基准预热 ≥2 次、正式运行 ≥5 次**。明确例外：UnixBench 与 CPU-06 套件各跑 1 遍；MEM-00 每节点跑 1 轮全模式；STREAM 每次自身执行 20 轮且工作集远超缓存，因此不再做外层预热、仍正式执行 5 次；CPU-08 跑 1 次 60 分钟压力并在压力前后各做 1 次短负载；超过 10 分钟的延迟/矩阵补充项可正式运行 3 次。所有例外都保留原始输出。
2. **延迟类**：只有工具内部产生大量样本时（如 proc_spawn 1000 次逐个计时、fio 的 clat 分布）才报告 P50/P95/P99；外层 5 次重复只报告**中位数、极差与 CV**——5 个样本不足以支撑百分位统计。**吞吐类**报告 5 次的中位数和 CV。
3. **绑核规范**：同一 session 只选择一次固定 CPU，并写入 `env/pin_core.txt`。自动选择只考虑每个物理核的第一个在线硬件线程，再从中选择累计中断较少的 CPU；单线程用例均复用它。多线程扩展性按"1、25%、50%、100% 物理核、全部逻辑核"梯度。
4. **系统状态**：`cpupower frequency-set -g performance`，并验证所有在线 CPU 的 governor；若平台不暴露 cpufreq，则明确记为 unavailable 并人工确认。关闭其他负载；每批开始用 `mpstat` 检查 1 分钟平均空闲率 ≥98%，敏感微基准组或长测试前快速复查 10 秒。无需在每个用例前重复等待 1 分钟。记录 EPP、`perf_event_paranoid` 与 `nmi_watchdog`，对比平台保持同一策略。
5. **结果记录**：每次运行输出一条 JSON（字段见方案 §10），原始 stdout 一并存入按批次隔离的目录 `results/raw/<platform_id>/<session_id>/<test_id>/`——同日补测生成新 session_id，不覆盖、不混入旧记录。数值指标解析失败时 `metric_valid=false`、`correctness=incomplete`，不能当作通过。
6. **微架构计数器**：**主成绩运行不带任何包裹**；常规测试在正式轮之外另跑一次 profiling 轮（`PROFILE=1`，`perf stat` 结果存 `profile_*.perfstat`）。长时、内存阶梯、套件型、自带 perf 或会覆盖产物的项目设置 `NO_PROFILE=1`，不额外执行。计数器只用于解释差异，不参与成绩。
7. **同步冻结**：Mutagen 用于部署与取回结果，不在正式跑分期间实时扫描/传输。开始前在 Mac 执行 `mutagen sync flush <会话名>`、`mutagen sync pause <会话名>`，测试结束后再执行 `mutagen sync resume <会话名>`；测试期间也不要修改远端脚本和负载。

### 0.3 有效性与对比标准（"什么样算测好了、什么样算有差异"）

| 标准 | 规则 |
|---|---|
| 单机有效性 | 计算类 CV ≤ 3%，系统/存储类 CV ≤ 5%；超出则排查干扰源并整组重测 |
| 报告口径 | **整机吞吐类**指标同时给出整机结果和每核结果（整机值 ÷ 物理核数）；**延迟、单线程、内存带宽类不做每核归一化**。跨容量平台不比总分 |
| 差异判定 | 两平台差异 < 2 × 合并 CV 时视为**持平**，不得写成"A 优于 B" |
| 环境一致 | 内核大版本、governor、SMT 状态必须一致。mitigations：**同厂商平台必须一致**；**跨厂商（Intel vs AMD）漏洞集合天然不同，不要求逐项一致**——各平台采用生产默认安全策略，完整记录并在报告中解释差异对系统调用类结果的可能影响 |
| 异常处理 | 任何删除的离群值必须保留原始数据并注明原因 |

---

## 1. OS 能力（OS-01 ~ OS-05）

### OS-01 系统综合基准（UnixBench）

- **方式**：完整套件跑两组配置——单副本（单核视角）与 16 副本（套件 system 类支持的上限）。每组由 UnixBench 自身完成内部迭代，外层各执行 1 遍。UnixBench 不用于评价高核数服务器的整机扩展性，整机扩展以 CPU-02 和 MEM-06 为准。
  ```bash
  ./Run -c 1        # 单副本
  ./Run -c 16       # 两平台统一的并行副本档
  ```
- **输出与判定**：记录 System Benchmarks Index Score 及各子项分数。综合分仅作参考，跨架构对比以子项（syscall、pipe、process creation）为准。由于外层只执行 1 遍，不对总分计算外层 CV；以套件退出码、内部迭代和各子项原始输出检查有效性。

### OS-02 系统调用延迟（lmbench + perf）

- **方式**：
  ```bash
  taskset -c <core> lat_syscall -N 5 null   # 最小系统调用（getppid）
  taskset -c <core> lat_syscall -N 5 read
  taskset -c <core> lat_syscall -N 5 write
  perf bench syscall basic                   # 交叉验证
  ```
  （`-N` 是 lmbench **内部重复轮数**而非样本数，V0.3 从 100 修正为 5——原值导致单次约 100 秒且对稳定性无益，实测 -N 5 + 外层 5 次 CV <1%。）
- **输出与判定**：ns/op（lmbench 输出 µs，换算）。两工具结果差异 >20% 时排查后以 lmbench 为准。**必须同时记录 mitigations 状态**：同厂商不一致则不可比；跨厂商记录并解释差异（见 §0.3）。

### OS-03 进程创建（lmbench + 定制脚本）

- **方式**：
  ```bash
  taskset -c <core> lat_proc -N 5 fork   # fork+exit
  taskset -c <core> lat_proc -N 5 exec   # fork+exec
  taskset -c <core> lat_proc -N 5 shell  # fork+exec+/bin/sh
  ```
  另用定制脚本连续创建 1000 个短进程（`/bin/true`），逐个记录耗时，得到 P50/P95/P99。
- **输出与判定**：µs/次、次/s、P95。此项是第二部分沙箱启动结果的解释基线，报告中必须与 SBX-01 并列展示。

### OS-04 上下文切换（lmbench + perf）

- **方式**：
  ```bash
  lat_ctx -N 5 -s 0 2 8 32                 # 不同进程数、0KB 工作集
  lat_ctx -N 5 -s 16 2 8 32                # 16KB 工作集（含缓存污染效应）
  perf bench sched pipe -l 1000000          # 交叉验证
  ```
- **输出与判定**：µs/切换。报告 0KB 与 16KB 两组（分别代表纯调度开销与真实负载开销）。

### OS-05 调度器压力（hackbench）

- **方式**：
  ```bash
  hackbench -g 10 -l 2000    # 400 任务
  hackbench -g 40 -l 2000    # 1600 任务（过载压力）
  ```
- **输出与判定**：完成时间（s）。两档并发分别报告中位数与 CV；首次 CV >5% 时按协议排查干扰并用新 session 重测，若在干净环境中仍稳定复现高 CV，则将其作为调度抖动结果报告，不能删掉波动轮次来“美化”数据。

## 2. CPU 计算能力（CPU-01 ~ CPU-06）

### CPU-01 单线程标量计算（sysbench + 7-Zip）

- **方式**：
  ```bash
  taskset -c <core> sysbench cpu --cpu-max-prime=20000 --threads=1 --time=30 run
  taskset -c <core> 7z b -mmt1
  ```
- **输出与判定**：sysbench events/s；7z 压缩/解压 MIPS。两工具都报，不合成单一分数。

### CPU-02 多线程通用计算与扩展性

- **方式**：线程数取 1、25%、50%、100% 物理核、全部逻辑核：
  ```bash
  sysbench cpu --cpu-max-prime=20000 --threads=<N> --time=30 run
  7z b -mmt<N>
  ```
- **输出与判定**：各档吞吐 + 扩展效率曲线（`N 线程吞吐 / (单线程吞吐 × N)`）。判定参考：满物理核扩展效率 <70% 时必须结合 CPU-06/MEM-06 解释原因（核间通信或带宽瓶颈）。异构核平台按方案 §3 说明分 P 核/E 核/默认三组。

### CPU-03 浮点/SIMD（可选，优先级低，**本轮不执行**）

- **方式**：如需执行再选定正式工具（CoreMark-Pro 或 OpenBLAS DGEMM；`stress-ng --matrix` 不作为正式 GFLOPS 基准）。Agent 场景相关性低，只在候选平台声称有 SIMD 优势时测。
- **输出与判定**：分数/GFLOPS。仅作参考，不进入选型权重。本轮 Intel/AMD 对比不执行，脚本未实现。

### CPU-04 压缩/解压（zstd，固定数据集）

- **方式**：数据集固定为 Silesia corpus，silesia.tar 锁定 SHA-256 = `5f6103f1cff22287f378f52c36c4ba9fb1fc2865edf6e0ab4206913dee65a6d6`（AMD 平台解压构建后必须先核对此值）：
  ```bash
  zstd -b3 -T1 silesia.tar      # 单线程，level 3（Agent 常用快速档）
  zstd -b3 -T<物理核数> silesia.tar  # 满物理核
  zstd -b19 -T1 silesia.tar     # 重压缩档（可选）
  ```
- **输出与判定**：压缩/解压 MB/s、压缩率。单线程同版本同参数的压缩率应一致，不一致说明输入或环境有误。多线程压缩会因工作线程数和分块边界产生轻微压缩率差异，必须连同实际线程数一起报告，不能要求不同物理核数的平台压缩率逐字相同。

### CPU-05 加密/哈希（OpenSSL）

- **方式**：
  ```bash
  openssl speed -evp sha256
  openssl speed -evp aes-256-gcm
  openssl speed rsa2048
  openssl speed -multi $(nproc) -evp aes-256-gcm   # 多核
  ```
- **输出与判定**：MB/s（对称/哈希）、sign/s 与 verify/s（RSA）。注意记录是否启用硬件加密指令（AES-NI / ARMv8 Crypto Extension），无硬件指令的结果单独标注。

### CPU-06 核间通信延迟（core-to-core-latency）

- **方式**：
  ```bash
  core-to-core-latency 5000 30 --cores <每个物理核的一个逻辑CPU> --csv > c2c_matrix.csv
  ```
- **输出与判定**：N×N 延迟矩阵（ns，N 为物理核数），绘制热力图。不把 SMT sibling 当作独立物理核；如需专门研究 SMT 通信，另设辅助用例。判定要点：识别拓扑分界（同簇/跨 CCD/跨 socket 的延迟台阶），并给出"最差核对/最优核对"比值——该比值大的平台，沙箱高并发时任务迁核代价更大。

## 3. 数据访问能力

### 3.1 内存与 NUMA（MEM-00 ~ MEM-07）

#### MEM-00 内存正确性检查（memtester + EDAC，测前门槛）

- **方式**：每个 NUMA 节点常规抽样 `numactl --membind=<n> memtester 10G 1`（可用 `MEMTEST_GB` 覆盖），同时比较 sysfs EDAC CE/UE 总计数；`edac-util --report=full` 保存为辅助证据。100GB/节点或更大规模作为过夜专项检查，不作为每批测试的默认门槛。
- **判定标准**：memtester 0 错误、EDAC 计数无新增为通过；任何错误 → 该机器停止一切性能测试，报修或换机。若内核未暴露 EDAC，则必须显式记录“ECC 检查缺项”，只能判定 memtester 抽样通过，不能写成“ECC 0 错误”。

#### MEM-01 顺序读写带宽（STREAM）

- **方式**：编译参数各平台统一，每个数组的容量至少为所有候选平台最大整机 L3 的 4 倍，并在正式对比时取相同值。安装脚本默认按本机 L3 自动计算，正式部署时应在所有机器显式传入相同的 `STREAM_ARRAY_MIB`：
  ```bash
  sudo STREAM_ARRAY_MIB=<相同的每数组MiB> bash scripts/01_setup_tools.sh
  gcc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=<元素数> -DNTIMES=20 stream.c -o stream
  taskset -c <core> env OMP_NUM_THREADS=1 OMP_PROC_BIND=true OMP_PLACES=cores ./stream
  ```
  （STREAM 是唯一允许 `-O3` 的用例，因为其结果定义即依赖向量化。数组容量可不同只适合冒烟，不作为正式横向对比口径。）
- **输出与判定**：Copy/Scale/Add/Triad 四项 GB/s，**跨平台对比以 Triad 为准**。STREAM 自带的校验必须通过，否则该次作废。

#### MEM-02 缓存/内存延迟阶梯

- **方式**：
  ```bash
  mlc --idle_latency                          # x86
  taskset -c <core> lat_mem_rd 2048 128       # 通用，工作集到 2GB，步长 128B
  ```
- **输出与判定**：延迟—工作集曲线，标出 L1/L2/L3/DRAM 四个平台段的数值（ns）。跨架构对比时两平台必须用同一工具（lat_mem_rd）。**MLC 官方面向 Intel 平台**：AMD 默认跳过；只有先人工验证功能可运行且输出合理，才设置 `ENABLE_MLC_ON_AMD=1` 采集补充数据。跨厂商共同基线 = STREAM + lmbench + numactl。

#### MEM-03 / MEM-04 NUMA 延迟与带宽矩阵（多路平台必测）

- **方式**：
  ```bash
  mlc --latency_matrix
  mlc --bandwidth_matrix
  mlc --peak_injection_bandwidth
  # 通用交叉验证：for i in nodes; for j in nodes:
  OMP_NUM_THREADS=<源节点物理核数> OMP_PROC_BIND=spread OMP_PLACES=cores \
      numactl --cpunodebind=$i --membind=$j ./stream   # 带宽矩阵
  numactl --physcpubind=<源节点固定物理核> --membind=$j \
      lat_mem_rd 2048 128                                   # 延迟矩阵
  ```
  （STREAM 使用源节点全部物理核，才代表节点级带宽；lat_mem_rd 是跨厂商共同延迟基线，每组合只跑 1 遍并取 DRAM 段——单次 2GB 阶梯耗时较长；MLC 矩阵只作 Intel 或已验证 AMD 平台的补充。）
- **输出与判定**：节点×节点矩阵。报告"远端/本地"比值：延迟比 >1.5 或带宽比 <0.7 的平台，第二部分测试必须增加 NUMA 绑定实验组。

#### MEM-05 负载下延迟（loaded latency，x86）

- **方式**：`mlc --loaded_latency`（默认注入梯度）。ARM 平台暂无等价标准工具，注明缺项。本轮：Intel 侧可用；**AMD 侧须先验证 MLC 输出合理性（见 MEM-02 说明），若验证不通过则 AMD 缺项并在报告注明**。
- **输出与判定**：带宽—延迟曲线。关注两点：拐点带宽（延迟开始陡增的位置）和满注入延迟。拐点带宽 ÷ 峰值带宽 <60% 的平台，高并发场景要预期更早的性能劣化。

#### MEM-06 多线程带宽扩展（STREAM 多线程）

- **方式**：`OMP_NUM_THREADS` 取 1、2、4…至全部物理核，`OMP_PROC_BIND=spread`，`OMP_PLACES=cores`。
- **输出与判定**：GB/s—线程数曲线，记录达到 90% 峰值带宽所需线程数（该值小说明少数任务即可吃满带宽，并发密度受限于内存而非核数）。

#### MEM-07 随机访问

- **方式**（V0.4 修订：主次对调）：
  ```bash
  pointer_chase <工作集MiB> 20  # 主数据；默认工作集=max(2048MiB, 2×整机L3)
  tinymembench                  # 辅助：最大工作集仅64MiB
  sysbench memory --memory-access-mode=rnd --memory-block-size=8 \
      --memory-total-size=8G --threads=1 run   # 参考数据
  ```
  说明：pointer_chase 使用固定种子的 Sattolo 单循环随机链，依赖访问无法被并行化或规则步长预取；正式运行 3 次。tinymembench 0.4.9 最大只到 64MiB，在本次大缓存服务器上不能代表 DRAM。sysbench 的 `memory-total-size` 是累计传输量而非工作集大小，也只作参考。
- **输出与判定**：主指标为 pointer_chase 的 ns/访问；同时保留 tinymembench 曲线和 sysbench ops/s。正式对比前应显式设置同一个 `POINTER_CHASE_MIB`，且该值至少为所有候选平台最大整机 L3 的 2 倍，保证工作集相同并越过 LLC。

---

### 3.2 存储与文件系统（OS-06，辅助项）

OS-06 沿用历史编号，但能力归类属于数据访问。`--direct=1` 绕过页缓存，测试文件无需大于 TB 级内存。
临时文件默认写入远端 `/var/tmp/cpu_test_fio`，不要放在 Mutagen/Git 同步目录内；若要测试独立数据盘，显式设置 `FIO_DIR=<挂载点>`，并确保两平台存储介质和文件系统口径一致。脚本只删除自己用 `mktemp` 创建的子目录。

```bash
fio --name=randread --rw=randread --bs=4k --iodepth=32 --ioengine=io_uring \
    --direct=1 --size=8G --runtime=60 --time_based --numjobs=4 --group_reporting
fio --name=seqread --rw=read --bs=1M --iodepth=8 --ioengine=io_uring \
    --direct=1 --size=8G --runtime=60 --time_based
```

- **输出与判定**：排名主指标记录在 JSON（随机读 IOPS、顺序读带宽），fio 原始 JSON 保留带宽与 clat P95/P99 等完整字段。fs_mark/固定仓库小文件回放为后续可选项。
- **归因规则**：本项不参与纯 CPU 排名；若存储型号、文件系统或挂载参数不同，只用于解释 Agent 端到端差异。

---

## 4. 持续性能与能效（CPU-08 ~ CPU-09）

### CPU-08 持续性能与降频（stress-ng + sysbench + turbostat）

- **方式**：压力前后分别用满物理核 sysbench 跑 30 秒；中间用全部逻辑 CPU 的 stress-ng 持续 60 分钟，并由 turbostat 每 10 秒采样频率、温度、封装功耗：
  ```bash
  sysbench cpu --threads=<物理核数> --time=30 run       # pre
  turbostat --Summary --interval 10 --out turbostat.log &
  stress-ng --cpu $(nproc) --cpu-method matrixprod --metrics-brief -t 60m
  sysbench cpu --threads=<物理核数> --time=30 run       # post
  ```
- **输出与判定**：`post/pre` 吞吐保持率、turbostat 的频率/温度曲线，以及 stress-ng 汇总 bogo-ops/s。持续吞吐下降 ≤5% 为通过；超过 5% 必须标注降频。stress-ng 的 bogo-ops 不参与跨 CPU 核心性能排名。x86 平台缺失或空的 turbostat 曲线会使本项不完整。

### CPU-09 能耗与能效

- **方式**：CPU-02 满物理核档额外执行一次独立 30 秒能效轮，避免把预热、重复测试和 profiling 混入功耗窗口；CPU-08 压力窗口同步采样。整机功耗每 5 秒读取一次 `ipmitool dcmi power reading`。空闲功耗先静置 300 秒、再采 300 秒，避免前序负载造成温度和风扇滞后（冒烟可用 `IDLE_SETTLE_SECONDS` / `IDLE_POWER_SECONDS` 缩短）。外置功率计或 PDU 优先。
- **输出与判定**：CSV 必须含 `epoch,power_w` 表头和足够的有效数值；负载功耗按窗口时间过滤并丢弃启动前的首个过渡样本，再计算平均/峰值功耗、task/s/W 和 J/task。CPU-02/08 任一约定的功耗窗口采集失败时，相关能效结果记为不完整，不能用缺失值代替 0。对比统一使用整机功耗；turbostat/RAPL 的 PkgWatt 仅作辅助。

---

## 5. 执行顺序与产出

已实现为 `scripts/run_part1.sh`（10/20/30 是按实现职责拆分的三个脚本，报告按上述四类组织）。单项补测需使用新的批次，并让环境准备与测试复用同一 `SESSION_ID`，例如依次执行 `sudo SESSION_ID=retry01 bash scripts/02_prepare_state.sh intel-6966p` 和 `sudo PLATFORM_ID=intel-6966p SESSION_ID=retry01 bash scripts/10_os_tests.sh OS-02`。单平台总计约 1~1.5 个工作日：

```text
环境采集 → MEM-00（门槛） → OS-02/03/04/05（系统微基准，机器最"干净"时测）
→ CPU-01/02/04/05/06 → MEM-01/02/06/07（→ MEM-03/04/05 多路平台）
→ OS-01 → OS-06 → CPU-09 → CPU-08（持续 1 小时，放最后）
```

MEM-00 或环境门槛失败时立即中止；普通测试组失败时继续收集其余结果，但总控最终返回退出码 2，整批状态为“不完整”。

当前执行脚本直接产出 `results/raw/<platform_id>/<session_id>/` 下的 JSONL、每项 `command.txt`、原始输出、环境快照和功耗/监控文件。`results/processed/` 汇总文件与图表属于后处理阶段产物，生成脚本尚未实现；在实现前不得把它们写成当前批次已自动产出。

## 6. 待定事项

- ~~整机功耗读取方式~~ 已确认：`ipmitool dcmi power reading`（Intel 机实测空闲约 554W）；AMD 机器接入后需验证其 BMC 同样可用。
- ARM 平台 loaded latency 缺标准工具——本轮两平台均为 x86，暂不适用；未来引入 ARM 候选时再调研。
