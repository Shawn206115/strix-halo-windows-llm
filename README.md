# Running large local LLMs on Windows with a 96 GB VRAM carveout (Strix Halo / Ryzen AI Max+ 395)

**The problem:** on a 128 GB Strix Halo machine you can carve out 96 GB of VRAM, and still fail to load an 87 GB model — because Windows' *commit limit* (RAM + pagefile) is smaller than the model. Carve out less (GTT-only, ~60 GB) and you can't use the 96 GB at all. This repo is a short, copy-paste-able procedure for that, plus measurements on 2026 models.

> **Prior work — read this first.** We independently hit and solved this, and later found that
> [rahulrevolution06-design/strix-halo-windows-memory-fix](https://github.com/rahulrevolution06-design/strix-halo-windows-memory-fix)
> documented the same mechanism in August 2026, with a more formal analysis: the commit-ratio
> measurement (`k ≈ 1.02`), a sizing model, a forecast tool, and a fully reversible PowerShell
> implementation. **If you want the deep treatment, go there.** What this repo adds:
>
> - measurements on newer models (Qwen3.8-Flash-Next 87 GB, Ornith-1.5 122B) including MTP;
> - **three models resident at once** (commit 109.8 GB);
> - full-GPU-offload vs partial-offload throughput on the same model (4.5×);
> - an independent second report of the secondary-volume pagefile defect they list as open
>   issue #1 (we reproduced it on two partitions);
> - a three-step quickstart with a single `.cmd`, for people who just want it to load.
>
> One adjacent Chinese write-up is worth knowing:
> [MSHAVL, "Strix Halo 本地部署 Qwen3.8 Flash Next"](https://lcz.me/topic/1453/2) (2026-09-01).
> Its subject is **prefill/decode tuning** (`-lm dio` vs `mmap`, MTP draft depth, thread split),
> not the load failure — but it hits the same Windows mechanism in passing and gives a concrete
> pagefile number (`32768 → 98304 MB`) as a prerequisite. Same wall, different door.
>
> The underlying mechanism is AMD/Microsoft behaviour, not anyone's discovery. AMD already
> documents pagefile sizing for large carveouts.

---

## TL;DR — the working configuration

| Item | Value |
|---|---|
| Hardware | ASUS laptop, AMD Ryzen AI Max+ 395 (Radeon 8060S), 128 GB LPDDR5X |
| OS | Windows 11 Home, build 26200 |
| Driver | AMD 32.0.32015.16001 (2026-11-11) |
| BIOS UMA / VRAM carveout | **96 GB** |
| Addressable GPU memory | 96 GB dedicated + 16 GB shared = **112 GB** |
| Physical RAM visible to Windows | 31.6 GB |
| Pagefile | **112 GB fixed on C:** |
| **Commit limit** | **143.6 GB** |

Result: an 87 GB MoE model runs at **41.8 tok/s** (with MTP), and **three models stay resident at once** (27B + 80B-A3B + 35B-A3B, commit 109.8 GB).

---

## 1. Two different limits (this is the whole point)

- **VRAM limit** — set in BIOS/UEFI (`UMA Frame Buffer Size` / VGM). 96 GB dedicated + 16 GB shared.
- **Commit limit** — `physical RAM + pagefile`. Windows/WDDM requires every GPU allocation to have a committed backing store, so it can be evicted.

A model that fits in VRAM can still fail to load:

```
weights 87 GB < VRAM 96 GB          -> fits
commit limit 55.6 GB (32 + 24)      -> loading fails
```

Raising the pagefile raises the commit limit. That is the missing step.

Upstream references:

- [AMD — Windows OS Guidelines for Ryzen AI Max PRO 400 series](https://docs.amd.com/v/u/en-US/73342_1.00_AMD_Ryzen_AI_Max_PRO_400_Series_Windows_OS_Guidelines): for a 144 GB carveout, set the pagefile to 192 GB; for 160 GB, 256 GB. ("sufficient committable memory")
- [llama.cpp #30406](https://github.com/ggml-org/llama.cpp/issues/30406): the scheduler's reservation counts toward the Windows commit charge.
- [unsloth PR #16046](https://github.com/unslothai/unsloth/pull/16046): a fully offloaded GGUF still makes `llama-server` hold system commit of roughly its GPU buffers.
- [NVIDIA forum thread](https://forums.developer.nvidia.com/t/rtx-spark-on-windows-cuda-allocations-consume-system-commit-even-with-96-gib-dedicated-gpu-memory/386453/7): same WDDM behaviour on a different vendor.

## 2. Steps

### 2.1 Update the GPU driver first

Old Adrenalin builds cap the carveout far below 96 GB. Update to a driver that supports the large VGM (we are on `32.0.32015.16001`).

### 2.2 Set the UMA carveout in BIOS

`UMA Frame Buffer Size` = **96 GB**. This leaves Windows 31.6 GB of RAM — that is expected and fine.

### 2.3 Set the pagefile **on the system drive**

GUI: System Properties → Advanced → Performance → Advanced → Virtual memory → Change → uncheck "Automatically manage" → C: custom size **114688 / 114688 MB** → **Set** → OK → reboot.

Or registry (admin):

```
HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management
  AutomaticManagedPagefile = 0
  PagingFiles = c:\pagefile.sys 114688 114688
```

Both values matter. If `AutomaticManagedPagefile` is missing, Windows treats the settings as "automatic", creates a default file, and silently deletes yours at next boot.

**Use the system drive.** On our machine a pagefile configured on D: or F: was silently dropped at every boot (`ExistingPageFiles` listed it, but no file appeared and the commit limit never moved). We tried twice, on two different partitions, before giving up.

Reboot. The pagefile only activates at boot.

### 2.4 Verify

```powershell
(Get-CimInstance Win32_OperatingSystem).TotalVirtualMemorySize / 1MB   # commit limit, GB
Get-CimInstance Win32_PageFileUsage | Select Name, AllocatedBaseSize   # MB
cmd /c dir C:\pagefile.sys /a
```

Expected: `pagefile.sys` ≈ 112 GB, commit limit ≈ 143.6 GB.

## 3. Measured numbers (this machine)

### Commit / VRAM

| Scenario | Commit used | GPU dedicated |
|---|---|---|
| Idle | 16.9 / 143.6 GB | — |
| 27B only | 42.7 GB | — |
| 27B + Coder-Next + 35B-A3B (three at once) | **109.8 / 143.6 GB** | — |
| 87 GB Flash-Next + MTP | **116.6 / 143.6 GB** | 69.4 GB |

Peak pagefile usage stayed at **27.6 GB** — the weights live in the Vulkan pool; the pagefile only backs the commit charge.

### Generation speed (400 tokens, temperature 0, thinking off)

| Model | Size | tok/s |
|---|---|---|
| Qwen3.8-27B + MTP | 16.45 GB | 32.5 |
| Qwen3-Coder-Next 80B-A3B | 35.8 GB | 43.7 |
| Qwen3.6-35B-A3B | 21.3 GB | 52.1 |
| Qwen3.8-Flash-Next, no MTP | 87.2 GB | 18.8 |
| Qwen3.8-Flash-Next + MTP | 87.2 GB | **41.8** |

### Full GPU offload vs. mixed CPU/GPU (same model, same context)

| 27B, `-c 8192`, 400 tokens | tok/s |
|---|---|
| `-ngl 999` (all layers on GPU) | **32.5** |
| `-ngl 10` (10 layers on GPU, rest CPU) | **7.3** |

**4.5× difference.** If a model does not fit in VRAM, partial offload is a correctness fallback, not a usable speed tier.

### Vision

With `--mmproj`, the 87 GB model read a generated 4-line test card (mixed Chinese/English, a matrix, a date) **with zero errors**, including `[[2, 1], [1, 3]]`.

## 4. Traps we hit

1. **Pagefile on a non-system drive is silently ignored.** Two partitions, two reboots, never worked. Keep it on C:.
2. **Pagefile only activates at boot.** Right after setting it, the file exists but `Win32_PageFileUsage` does not list it and the commit limit is unchanged.
3. **`AutomaticManagedPagefile` must be 0**, otherwise Windows removes the custom file on the next boot.
4. **Write scripts as pure ASCII.** `cmd.exe` and PowerShell 5.1 read scripts in the system ANSI codepage; UTF-8 Chinese breaks parsing with nonsense errors. If you must include non-ASCII in `.ps1`, save with a BOM.
5. **`--mmproj` and `-md` (MTP) files are separate downloads.** Without them: no vision, and half the speed.
6. **`.part` preallocation eats disk instantly.** Check free space before starting a 100 GB download.
7. **Never run two downloaders on the same shard.** We corrupted a 38 GB file this way; the header was not `GGUF`.
8. **Do not hot-swap two 20 GB+ models repeatedly** — we bluescreened with `0x19C` (dxgkrnl). Stop, wait for VRAM release, then start the next one.
9. **A 2-bit quant of last year's flagship is still last year's model.** We checked the benchmarks before downloading 80 GB this time.

## 5. How far Windows can go

- **Theoretical ceiling here: ~112 GB of addressable GPU memory** (96 dedicated + 16 shared). We are testing whether a ~109 GB model loads; this section will be updated with the result.
- Commit limit can be pushed further (e.g. 128 GB pagefile → 159.6 GB commit), but VRAM does not grow with it.
- Linux still wins on flexibility (no commit limit, larger GTT, mmap), but both are limited by the same ~120 GB/s LPDDR5X bandwidth: 100 GB-class models decode in the tens of tok/s on either OS.

## 6. Community numbers for reference

| Machine | Model | tok/s |
|---|---|---|
| GMKtec EVO-X2, 128 GB | GPT-OSS 120B Q4_K_M | 53.4 |
| GMKtec EVO-X2, 128 GB | MiniMax M2.5 Q3_K_M (228.7B) | 32.8 |
| GMKtec EVO-X2, 128 GB | Qwen3-Coder-Next 80B-A3B Q4 | 42.7 |
| **This machine** | **Qwen3.8-Flash-Next 87 GB + MTP** | **41.8** |

(from [visorcraft/strix-halo-llm-perf](https://github.com/visorcraft/strix-halo-llm-perf))

## 7. Scripts

`scripts/set-pagefile-windows.cmd` — sets 112 GB pagefile on C: (ASCII, run as administrator, reboot after).

## License

MIT. Numbers are from one machine; your mileage will vary, but the commit-limit mechanism will not.
