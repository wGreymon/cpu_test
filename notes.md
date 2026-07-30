# CPU 与 Agent 沙箱学习笔记（问答形式）

## 目录

- [Q1：Agent 沙箱的运行和管理是由 CPU 负责的吗，而不是 GPU 或其他并行计算设备？](#q1agent-沙箱的运行和管理是由-cpu-负责的吗而不是-gpu-或其他并行计算设备)
- [Q2：在 Linux 服务器上查看硬件信息常用哪些命令？](#q2在-linux-服务器上查看硬件信息常用哪些命令)

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

看 lscpu 的关键字段：`Model name`（型号）、`Socket(s)` × `Core(s) per socket`（物理核数）、`Thread(s) per core`（是否开超线程）、`L3 cache`（决定 STREAM 数组大小）、`NUMA node(s)`。

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
