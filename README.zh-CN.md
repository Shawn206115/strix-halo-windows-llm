# 在 Windows 上跑 100 GB 级本地大模型：96 GB 显存切分的正确打开方式（Strix Halo / Ryzen AI Max+ 395）

**问题**：128 GB 的 Strix Halo 机器可以把 96 GB 划成显存，但你还是加载不了 87 GB 的模型——因为 Windows 的**提交上限**（物理内存 + 页面文件）比模型还小。反过来把显存切小（只走 GTT，约 60 GB），那 96 GB 又白瞎了。这个仓库是这套问题的短流程说明，外加 2026 年新模型的实测数据。

> **先看前人的工作。** 我们是自己撞上、自己摸通的，后来才发现
> [rahulrevolution06-design/strix-halo-windows-memory-fix](https://github.com/rahulrevolution06-design/strix-halo-windows-memory-fix)
> 在 2026 年 8 月就写清楚了这个机制，而且更严谨：commit 比例实测（`k ≈ 1.02`）、容量推算模型、
> 预测工具，以及一套可完整回滚的 PowerShell 实现。**想要深入分析，请看它。** 这个仓库补充的是：
>
> - 更新一代模型的实测（Qwen3.8-Flash-Next 87 GB、Ornith-1.5 122B），含 MTP 加速；
> - **三个模型同时驻留**（提交 109.8 GB）；
> - 同一模型「全量 offload」与「部分 offload」的速度对比（4.5 倍）；
> - 对它列为 open issue #1 的「非系统卷页面文件不创建」的一次独立复现（我们在两个分区上都失败过）；
> - 一份三步走的快速上手，配一个 `.cmd`，给只想“先让它跑起来”的人。
>
> 还有一篇中文写法值得知道：[MSHAVL《Strix Halo 本地部署 Qwen3.8 Flash Next》](https://lcz.me/topic/1453/2)（2026-09-01）。
> 它的主题是 **prefill/decode 调优**（`-lm dio` 换 `mmap`、MTP 草稿深度、线程分配），**不是**加载失败；
> 但它顺带撞上了同一个 Windows 机制，并给出了一个具体数字：页面文件初始值 `32768 → 98304 MB`，否则 `-lm dio` 的 commit 需求（约 119 GiB）会被边跑边扩的页面文件拖慢。**同一堵墙，不同的门。**
>
> 底层机制是 AMD / 微软的行为，不是谁的发现；AMD 官方文档里本来就写了页面文件要跟着显存切分放大。

---

## TL;DR — 能跑起来的配置

| 项目 | 数值 |
|---|---|
| 硬件 | ASUS 笔记本，AMD Ryzen AI Max+ 395（Radeon 8060S），128 GB LPDDR5X |
| 系统 | Windows 11 家庭版，build 26200 |
| 驱动 | AMD 32.0.32015.16001（2026-11-11） |
| BIOS UMA 切分 | **96 GB** |
| 可寻址显存 | 96 GB 专用 + 16 GB 共享 = **112 GB**（实测峰值 105.6 GB，101.79 GB 的模型） |
| Windows 可见物理内存 | 31.6 GB |
| 页面文件 | **C 盘固定 112 GB** |
| **提交上限** | **143.6 GB** |

结果：87 GB 的 MoE 模型，接上 MTP 后 **41.8 t/s**；**三个模型同时驻留**（27B + 80B-A3B + 35B-A3B，提交 109.8 GB）。

---

## 1. 两个不同的「上限」，这是全部症结

- **显存上限**：BIOS/UEFI 里的 `UMA Frame Buffer Size`（也叫 VGM）。96 GB 专用 + 16 GB 共享。
- **提交上限**：`物理内存 + 页面文件`。Windows/WDDM 要求每笔 GPU 分配都有提交后备，好在显存不够时换出去。

所以会出现「装得下却加载不了」：

```
权重 87 GB < 显存 96 GB       → 放得下
提交上限 55.6 GB（32 + 24）   → 加载失败
```

把页面文件放大，就是把提交上限抬起来。这是缺的那一步。

上游依据：

- [AMD 官方 Windows 指南](https://docs.amd.com/v/u/en-US/73342_1.00_AMD_Ryzen_AI_Max_PRO_400_Series_Windows_OS_Guidelines)：144 GB 显存切分配 192 GB 页面文件，160 GB 配 256 GB，理由写明「提供足够的可提交内存」。
- [llama.cpp #30406](https://github.com/ggml-org/llama.cpp/issues/30406)：调度器按图容量预留的缓冲也计入 Windows 提交量。
- [unsloth PR #16046](https://github.com/unslothai/unsloth/pull/16046)：模型全在显存里，`llama-server` 仍要占掉约等于 GPU 缓冲的系统提交。
- [NVIDIA 论坛](https://forums.developer.nvidia.com/t/rtx-spark-on-windows-cuda-allocations-consume-system-commit-even-with-96-gib-dedicated-gpu-memory/386453/7)：WDDM 的行为，不分厂商。

## 2. 步骤

### 2.1 先更新显卡驱动

旧版 Adrenalin 会把显存切分卡在远低于 96 GB。升到支持大 VGM 的版本（我们用的是 `32.0.32015.16001`）。

### 2.2 BIOS 里切显存

`UMA Frame Buffer Size` = **96 GB**。此时 Windows 只剩 31.6 GB 物理内存，这是正常的。

### 2.3 页面文件必须放在**系统盘**

图形界面：系统属性 → 高级 → 性能 设置 → 高级 → 虚拟内存 更改 → 取消「自动管理」→ 选 C: → 自定义 初始/最大 **114688 MB** → **点「设置」** → 确定 → 重启。

或注册表（管理员）：

```
HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management
  AutomaticManagedPagefile = 0
  PagingFiles = c:\pagefile.sys 114688 114688
```

两个值必须一起写。`AutomaticManagedPagefile` 缺省时 Windows 按「自动管理」处理：当场给你建一个文件，下次开机再删掉。

**只放系统盘。** 我们实测把页面文件配在 D 盘、F 盘两次，每次开机都被静默丢弃：`ExistingPageFiles` 里能看到，文件却不存在，提交上限也不动。

改完**重启**，页面文件只在开机时激活。

### 2.4 验证

```powershell
(Get-CimInstance Win32_OperatingSystem).TotalVirtualMemorySize / 1MB   # 提交上限（GB）
Get-CimInstance Win32_PageFileUsage | Select Name, AllocatedBaseSize   # 单位 MB
cmd /c dir C:\pagefile.sys /a
```

预期：`pagefile.sys` 约 112 GB，提交上限约 143.6 GB。

## 3. 实测数据（本机）

### 提交与显存

| 场景 | 提交占用 | GPU 专用 |
|---|---|---|
| 空载 | 16.9 / 143.6 GB | — |
| 仅 27B | 42.7 GB | — |
| 27B + Coder-Next + 35B-A3B 三同载 | **109.8 / 143.6 GB** | — |
| 87 GB Flash-Next + MTP | **116.6 / 143.6 GB** | 69.4 GB |

页面文件峰值只有 **27.6 GB**——权重压在 Vulkan 显存池里，页面文件只撑提交账面。

### 生成速度（400 token，temperature 0，关闭 thinking）

| 模型 | 大小 | tok/s |
|---|---|---|
| Qwen3.8-27B + MTP | 16.45 GB | 32.5 |
| Qwen3-Coder-Next 80B-A3B | 35.8 GB | 43.7 |
| Qwen3.6-35B-A3B | 21.3 GB | 52.1 |
| Qwen3.8-Flash-Next（无 MTP） | 87.2 GB | 18.8 |
| Qwen3.8-Flash-Next + MTP | 87.2 GB | **41.8** |

### 全量 GPU vs 混合 CPU/GPU（同模型、同上下文）

| 27B，`-c 8192`，400 token | tok/s |
|---|---|
| `-ngl 999`（全部层在 GPU） | **32.5** |
| `-ngl 10`（10 层在 GPU，其余 CPU） | **7.3** |

**差 4.5 倍。** 模型塞不进显存时，部分 offload 只能算「能跑」，不能算「能用」。

### 视觉

挂上 `--mmproj` 后，87 GB 的模型读一张自制测试卡（中英混排、矩阵、日期）**四行全对**，包括 `[[2, 1], [1, 3]]` 的符号。

## 4. 我们踩过的坑

1. **页面文件放非系统盘会被静默忽略**：两个分区、两次重启，从未生效。放 C 盘。
2. **页面文件只在开机激活**：刚设置完文件已存在，但 `Win32_PageFileUsage` 不列它，提交上限不变。
3. **`AutomaticManagedPagefile` 必须置 0**，否则下次开机会删掉自定义文件。
4. **脚本一律写纯 ASCII**：`cmd.exe` 与 PowerShell 5.1 都按系统 ANSI 读脚本，UTF-8 中文会解析成乱码报错；`.ps1` 必须含中文就存 UTF-8 BOM。
5. **`--mmproj` 和 MTP（`-md`）是单独文件**：不下载就没有视觉，速度也少一半。
6. **`.part` 会立刻预分配**：开 100 GB 下载前先看可用空间。
7. **同一个分片永远只开一个下载进程**：我们曾把 38 GB 的分片写坏，文件头不是 `GGUF`。
8. **别反复热切两个 20 GB 以上的模型**：我们蓝屏过一次 `0x19C`（dxgkrnl）。先停、等显存释放、再起。
9. **上一代旗舰压到 2 bit 还是上一代**：这次我们看完 benchmark 才决定不下那个 80 GB。

## 5. Windows 的天花板在哪

- 这台机器的**可寻址显存约 112 GB**（96 专用 + 16 共享）——**已实测，不再停留在理论**：Ornith-1.5-122B `Q6_K`（101.79 GB，3 个分片）加载 60 秒、生成 **18.3 tok/s**，峰值占用 **95.3 GB 专用 + 10.3 GB 共享 = 105.6 GB**，落在 112 GB 以内。细节见 [`docs/ornith-122b-q5k-96gb.md`](docs/ornith-122b-q5k-96gb.md)。
- 提交上限还能往上抬（比如页面文件 128 GB → 提交 159.6 GB），但**显存不会跟着长**。
- Linux 在灵活性上仍占优（无提交限制、GTT 更大、mmap），但两边都被同一块 LPDDR5X（约 120 GB/s）卡着：100 GB 级模型的 decode 都在几十 t/s 这一档。

## 6. 社区对照

| 机器 | 模型 | tok/s |
|---|---|---|
| GMKtec EVO-X2，128 GB | GPT-OSS 120B Q4_K_M | 53.4 |
| GMKtec EVO-X2，128 GB | MiniMax M2.5 Q3_K_M（228.7B） | 32.8 |
| GMKtec EVO-X2，128 GB | Qwen3-Coder-Next 80B-A3B Q4 | 42.7 |
| **本机** | **Qwen3.8-Flash-Next 87 GB + MTP** | **41.8** |

（来源：[visorcraft/strix-halo-llm-perf](https://github.com/visorcraft/strix-halo-llm-perf)）

## 7. 脚本

`scripts/set-pagefile-windows.cmd`：把 C 盘页面文件设为 112 GB（纯 ASCII，右键以管理员运行，改完重启）。

## 许可

MIT。数据来自一台机器，你的数字会不同，但提交上限这套机制不会变。
