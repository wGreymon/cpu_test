# 第一部分测试规范：工具、命令与判定标准

> 版本：V0.1（草稿）
> 配套文档：`CPU_AGENT_SANDBOX_TEST_PLAN.md` V1.2 第一部分
> 适用对象：Linux x86_64 / ARM64 服务器
> 本文档回答三个问题：每项能力**用什么工具（含版本）**、**以什么方式运行（具体命令与流程）**、**按什么标准判定和对比结果**。

## 0. 通用规范（所有用例必须遵守）

### 0.1 工具版本固定表

所有平台使用同一版本，从源码编译的工具统一编译参数（`-O2 -march=<各架构对应值>`，STREAM 除外，见 MEM-01）。

| 工具 | 固定版本 | 获取方式 | 用于 |
|---|---|---|---|
| UnixBench | 5.1.3 | github.com/kdlucas/byte-unixbench | OS-01 |
| lmbench | 3.0-a9 | sourceforge / 发行版源码包 | OS-02/03/04、MEM-02 |
| perf | 与内核同版本 | linux-tools | OS-02/04、辅助剖析 |
| hackbench | rt-tests 2.6 | git.kernel.org/pub/scm/utils/rt-tests | OS-05 |
| fio | 3.36 | github.com/axboe/fio | OS-06 |
| fs_mark | 3.3 | github.com/josefbacik/fs_mark | OS-06 |
| sysbench | 1.0.20 | github.com/akopytov/sysbench | CPU-01/02、MEM-07 |
| 7-Zip | 24.08 | 7-zip.org（p7zip 或官方 Linux 版） | CPU-01/02 |
| zstd | 1.5.6 | github.com/facebook/zstd | CPU-04 |
| OpenSSL | 3.0.x（各平台同小版本） | 发行版或源码 | CPU-05 |
| core-to-core-latency | 最新 release（记录 commit） | github.com/nviennot/core-to-core-latency | CPU-06 |
| Geekbench | 6.3（Pro 版可离线） | geekbench.com | CPU-07 |
| SPEC CPU | 2017 v1.1.9（如有授权） | SPEC | CPU-07 |
| stress-ng | 0.17.x | github.com/ColinIanKing/stress-ng | CPU-08 |
| turbostat | 与内核同版本 | linux-tools | CPU-08/09（x86） |
| ipmitool | 1.8.19 | 发行版 | CPU-09（整机功耗） |
| STREAM | 5.10 | cs.virginia.edu/stream | MEM-01/06 |
| Intel MLC | v3.11 | intel.com（仅 x86） | MEM-02~05 |
| tinymembench | 最新 commit（记录哈希） | github.com/ssvb/tinymembench | MEM-02/07（ARM 替代） |
| memtester | 4.6.0 | pyropus.ca/software/memtester | MEM-00 |

### 0.2 运行协议

1. **预热 ≥2 次，正式运行 ≥5 次**；耗时超过 10 分钟的用例（OS-01 全量、CPU-07、CPU-08、MEM-00）正式运行可减为 3 次，需在报告注明。
2. **延迟类**用例保存全部样本，报告 P50/P95/P99；**吞吐类**报告 5 次的中位数和 CV。
3. **绑核规范**：单线程用例用 `taskset -c <core>` 绑定到固定物理核（避开处理中断最多的核，用 `cat /proc/interrupts` 确认）；多线程扩展性用例按"1、25%、50%、100% 物理核、全部逻辑核"梯度，配 `numactl` 控制内存局部性。
4. **系统状态**：`cpupower frequency-set -g performance`；关闭其他负载；每个用例前记录 1 分钟空闲基线（mpstat）确认 CPU 空闲率 >98%。
5. **结果记录**：每次运行输出一条 JSON（字段见方案 §9），原始 stdout 一并存入 `results/raw/<run_id>/`。

### 0.3 有效性与对比标准（"什么样算测好了、什么样算有差异"）

| 标准 | 规则 |
|---|---|
| 单机有效性 | 计算类 CV ≤ 3%，系统/存储类 CV ≤ 5%；超出则排查干扰源并整组重测 |
| 报告口径 | 每项同时给出**整机结果**和**每核结果**（整机值 ÷ 物理核数），跨容量平台不比总分 |
| 差异判定 | 两平台差异 < 2 × 合并 CV 时视为**持平**，不得写成"A 优于 B" |
| 环境一致 | 内核大版本、mitigations、governor、SMT 状态必须一致，否则结果标记为不可比 |
| 异常处理 | 任何删除的离群值必须保留原始数据并注明原因 |

---

## 1. 系统能力层（OS-01 ~ OS-06）

### OS-01 系统综合基准（UnixBench）

- **方式**：完整套件跑两遍——单副本（单核视角）与 N 副本（N=逻辑核数）。
  ```bash
  ./Run -c 1        # 单副本
  ./Run -c $(nproc) # 满逻辑核副本
  ```
- **输出与判定**：记录 System Benchmarks Index Score 及各子项分数。综合分仅作参考，跨架构对比以子项（syscall、pipe、process creation）为准。有效性按 CV ≤ 5%。

### OS-02 系统调用延迟（lmbench + perf）

- **方式**：
  ```bash
  taskset -c <core> lat_syscall -N 100 null   # 最小系统调用（getppid）
  taskset -c <core> lat_syscall -N 100 read
  taskset -c <core> lat_syscall -N 100 write
  perf bench syscall basic                     # 交叉验证
  ```
- **输出与判定**：ns/op（lmbench 输出 µs，换算）。两工具结果差异 >20% 时排查后以 lmbench 为准。**必须同时记录 mitigations 状态**，不一致则本项跨平台不可比。

### OS-03 进程/线程创建（lmbench + 定制脚本）

- **方式**：
  ```bash
  taskset -c <core> lat_proc -N 100 fork   # fork+exit
  taskset -c <core> lat_proc -N 100 exec   # fork+exec
  taskset -c <core> lat_proc -N 100 shell  # fork+exec+/bin/sh
  ```
  另用定制脚本连续创建 1000 个短进程（`/bin/true`），逐个记录耗时，得到 P50/P95/P99。
- **输出与判定**：µs/次、次/s、P95。此项是第二部分沙箱启动结果的解释基线，报告中必须与 SBX-01 并列展示。

### OS-04 上下文切换（lmbench + perf）

- **方式**：
  ```bash
  lat_ctx -N 100 -s 0 2 4 8 16 32          # 不同进程数、0KB 工作集
  lat_ctx -N 100 -s 16 2 8                 # 16KB 工作集（含缓存污染效应）
  perf bench sched pipe -l 1000000          # 交叉验证
  ```
- **输出与判定**：µs/切换。报告 0KB 与 16KB 两组（分别代表纯调度开销与真实负载开销）。

### OS-05 调度器压力（hackbench）

- **方式**：
  ```bash
  hackbench -g 10 -l 2000    # 400 任务
  hackbench -g 40 -l 2000    # 1600 任务（过载压力）
  ```
- **输出与判定**：完成时间（s）。两档并发分别报告中位数与 CV；CV > 5% 说明调度抖动大，本身即是有价值的对比结果，需注明而非重测掩盖。

### OS-06 存储 I/O（fio + fs_mark，辅助项）

- **方式**（`--direct=1`，测试文件 ≥ 2 倍内存以避开页缓存，或明确标记为缓存内测试）：
  ```bash
  fio --name=randread --rw=randread --bs=4k --iodepth=32 --ioengine=io_uring \
      --direct=1 --size=8G --runtime=60 --time_based --numjobs=4 --group_reporting
  fio --name=seqread --rw=read --bs=1M --iodepth=8 --direct=1 --size=8G \
      --runtime=60 --time_based
  fs_mark -d /mnt/test -n 10000 -s 4096 -t 8    # 小文件创建
  ```
- **输出与判定**：IOPS、MB/s、P95/P99 延迟（fio 的 clat 百分位）、files/s。**本项不参与平台排名**，仅用于解释 Agent 端到端差异；若两平台存储硬件不同，必须在报告显著位置注明。

---

## 2. CPU 核心能力层（CPU-01 ~ CPU-09）

### CPU-01 单线程整数（sysbench + 7-Zip）

- **方式**：
  ```bash
  taskset -c <core> sysbench cpu --cpu-max-prime=20000 --threads=1 --time=30 run
  taskset -c <core> 7z b -mmt1
  ```
- **输出与判定**：sysbench events/s；7z 压缩/解压 MIPS。两工具都报，不合成单一分数。

### CPU-02 多线程整数与扩展性

- **方式**：线程数取 1、25%、50%、100% 物理核、全部逻辑核：
  ```bash
  sysbench cpu --cpu-max-prime=20000 --threads=<N> --time=30 run
  7z b -mmt<N>
  ```
- **输出与判定**：各档吞吐 + 扩展效率曲线（`N 线程吞吐 / (单线程吞吐 × N)`）。判定参考：满物理核扩展效率 <70% 时必须结合 CPU-06/MEM-06 解释原因（核间通信或带宽瓶颈）。异构核平台按方案 §3 说明分 P 核/E 核/默认三组。

### CPU-03 浮点/SIMD（可选，优先级低）

- **方式**：CoreMark-Pro（记录 commit 与编译参数）或 `stress-ng --matrix`。Agent 场景相关性低，只在候选平台声称有 SIMD 优势时测。
- **输出与判定**：分数/GFLOPS。仅作参考，不进入选型权重。

### CPU-04 压缩/解压（zstd，固定数据集）

- **方式**：数据集固定为 Silesia corpus（silesia.tar，记录 SHA-256）：
  ```bash
  zstd -b3 -T1 silesia.tar      # 单线程，level 3（Agent 常用快速档）
  zstd -b3 -T0 silesia.tar      # 全核
  zstd -b19 -T1 silesia.tar     # 重压缩档（可选）
  ```
- **输出与判定**：压缩/解压 MB/s、压缩率。压缩率各平台应完全一致（同版本同参数），不一致说明环境有误，测试作废重查。

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
  core-to-core-latency 5000 --csv > c2c_matrix.csv
  ```
- **输出与判定**：N×N 延迟矩阵（ns），绘制热力图。判定要点：识别拓扑分界（同簇/跨 CCD/跨 socket 的延迟台阶），并给出"最差核对/最优核对"比值——该比值大的平台，沙箱高并发时任务迁核代价更大。

### CPU-07 权威综合基准（SPEC CPU 2017 或 Geekbench 6）

- **方式**：有授权则跑 SPECrate 2017 Integer（base 档，统一 `-O2` 级编译配置，禁用激进调优）；无授权用 Geekbench 6（`geekbench6 --no-upload`，Pro 版离线）。
- **输出与判定**：SPECrate int base 分（整机+每核）或 GB6 单核/多核分。GB6 结果只用于跨架构粗对比，正式报告注明其负载偏桌面场景的局限。

### CPU-08 持续性能与降频（stress-ng + turbostat）

- **方式**：满物理核持续 60 分钟，每 10 秒采样一次频率/温度/功耗：
  ```bash
  turbostat --interval 10 --out turbostat.log &        # x86；ARM 用 hwmon/BMC 轮询脚本
  stress-ng --cpu $(nproc) --cpu-method matrixprod --metrics-brief -t 60m
  ```
- **输出与判定**：bogo-ops/s（前 5 分钟均值 vs 后 5 分钟均值）、频率与温度曲线。**判定标准：持续吞吐下降 ≤5% 为通过**（方案 V1.1 沿用值）；下降 >5% 的平台必须在选型报告中单独标注降频行为。

### CPU-09 能耗与能效

- **方式**：在 CPU-02（满核 sysbench）和 CPU-08 运行期间同步采集功耗——x86 用 turbostat RAPL（PkgWatt），整机功耗统一用 `ipmitool dcmi power reading`（每 5 秒），有外置功率计则优先。空闲功耗单独采 5 分钟。
- **输出与判定**：task/s/W（吞吐 ÷ 整机平均功耗）、J/task。**对比口径必须统一为整机功耗**；RAPL 只覆盖 CPU 封装，仅作辅助，不得与整机口径混比。

---

## 3. 内存能力层（MEM-00 ~ MEM-07）

### MEM-00 内存正确性检查（memtester，测前门槛）

- **方式**：`memtester <可用内存的 80%> 1`（1 轮全模式）。
- **判定标准**：0 错误为通过；任何错误 → 该机器停止一切性能测试，报修或换机。

### MEM-01 顺序读写带宽（STREAM）

- **方式**：编译参数各平台统一，数组大小 ≥ 4 倍 L3：
  ```bash
  gcc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=<元素数> -DNTIMES=20 stream.c -o stream
  OMP_NUM_THREADS=1 OMP_PROC_BIND=true ./stream     # 单线程
  ```
  （STREAM 是唯一允许 `-O3` 的用例，因为其结果定义即依赖向量化；所有平台一致即可。）
- **输出与判定**：Copy/Scale/Add/Triad 四项 GB/s，**跨平台对比以 Triad 为准**。STREAM 自带的校验必须通过，否则该次作废。

### MEM-02 缓存/内存延迟阶梯

- **方式**：
  ```bash
  mlc --idle_latency                          # x86
  taskset -c <core> lat_mem_rd 2048 128       # 通用，工作集到 2GB，步长 128B
  ```
- **输出与判定**：延迟—工作集曲线，标出 L1/L2/L3/DRAM 四个平台段的数值（ns）。跨架构对比时两平台必须用同一工具（lat_mem_rd），MLC 结果只在 x86 内部使用。

### MEM-03 / MEM-04 NUMA 延迟与带宽矩阵（多路平台必测）

- **方式**：
  ```bash
  mlc --latency_matrix
  mlc --bandwidth_matrix
  mlc --peak_injection_bandwidth
  # ARM 替代：for i in nodes; for j in nodes:
  numactl --cpunodebind=$i --membind=$j ./stream   # 及 lat_mem_rd
  ```
- **输出与判定**：节点×节点矩阵。报告"远端/本地"比值：延迟比 >1.5 或带宽比 <0.7 的平台，第二部分测试必须增加 NUMA 绑定实验组。

### MEM-05 负载下延迟（loaded latency，x86）

- **方式**：`mlc --loaded_latency`（默认注入梯度）。ARM 平台暂无等价标准工具，注明缺项。
- **输出与判定**：带宽—延迟曲线。关注两点：拐点带宽（延迟开始陡增的位置）和满注入延迟。拐点带宽 ÷ 峰值带宽 <60% 的平台，高并发场景要预期更早的性能劣化。

### MEM-06 多线程带宽扩展（STREAM 多线程）

- **方式**：`OMP_NUM_THREADS` 取 1、2、4…至全部物理核，`OMP_PROC_BIND=spread`。
- **输出与判定**：GB/s—线程数曲线，记录达到 90% 峰值带宽所需线程数（该值小说明少数任务即可吃满带宽，并发密度受限于内存而非核数）。

### MEM-07 随机访问

- **方式**：
  ```bash
  sysbench memory --memory-access-mode=rnd --memory-block-size=8 \
      --memory-total-size=8G --threads=1 run
  tinymembench    # 含随机延迟项，作为交叉验证（ARM 主用）
  ```
- **输出与判定**：ops/s、ns/访问。与 MEM-02 的 DRAM 段延迟互为印证，差异 >30% 时排查配置。

---

## 4. 执行顺序与产出

建议单平台执行顺序（总计约 1.5 个工作日，不含 SPEC）：

```text
环境采集 → MEM-00（门槛） → OS-02/03/04/05（系统微基准，机器最"干净"时测）
→ CPU-01/02/04/05/06 → MEM-01/02/06/07（→ MEM-03/04/05 多路平台）
→ OS-01 → OS-06 → CPU-07 → CPU-08+09（持续 1 小时，放最后）
```

每平台产出一份 `results/processed/<platform_id>_part1.json`（全部指标）和对应图表（延迟阶梯、扩展效率曲线、核间矩阵热力图、loaded latency 曲线、持续性能曲线）。

## 5. 待定事项

- SPEC CPU 2017 授权是否可用（影响 CPU-07 取哪个工具）。
- 整机功耗读取方式需按实际机器确认（IPMI / PDU / 功率计）。
- ARM 平台 loaded latency 缺标准工具，若 ARM 为主力候选需调研厂商工具（如 NVIDIA/Ampere 提供的内存工具）。
