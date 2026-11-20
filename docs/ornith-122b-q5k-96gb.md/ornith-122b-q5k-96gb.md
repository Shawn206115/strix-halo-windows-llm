# Ornith-1.5-122B on Ryzen AI MAX+ 395 (96 GB): measurements and what does not help

Measured 2026-11-20 on a single Ryzen AI MAX+ 395 box, Windows 11, Vulkan backend
(llama.cpp build `b12359`, `v1.0.0-dev`, `ggml-vulkan.dll`), all layers offloaded (`-ngl 99`),
MTP/KV on GPU, model files byte-verified against ModelScope.

## Model

- `Ornith-1.5-122B` — 122B total MoE, **10B active**, MIT, `arch = qwen35moe`
- 48 trunk layers + **1 MTP layer** (`blk.48`), 256 experts / 8 active, KV heads = 2
- Quant tested: **Q5_K_M = 88.42 GB** (3 shards), Q6_K = 101.79 GB — **Q5_K_M is the better pick**: same score, 10% faster, 13 GB smaller.

## Baseline numbers

| Config | prompt (tok/s) | decode (tok/s) |
|---|---|---|
| `b1049`, `-c 4096 -ub 512 -b 2048` | — | 18.3 |
| `b12359`, `-c 4096 -ub 512 -b 2048 -fa on` | 392 | 20.4 |
| **`b12359`, `-c 8192 -ub 1024 -b 4096 -fa on`** | **531 (+35%)** | **20.5** |

- Load time: 48–60 s from a PCIe 4.0 NVMe (mmap).
- GPU memory: 95.3 GB dedicated + 10.3 GB shared for Q6_K; Q5_K_M similar.
- System: commit 123/143.6 GB with a 112 GB pagefile; physical RAM is only 31.6 GB visible (UMA split).

**Tuning only helps prefill.** Decode is bandwidth-bound, so `-ub/-b` changes affect prompt processing (+35%), not tok/s.

## MTP: supported, enabled, and *slower* here

`llama.cpp` b12359 exposes `--spec-type draft-mtp` and `qwen35moe.cpp` implements
`graph_mtp` (the GGUF carries `qwen35moe.nextn_predict_layers = 1`).
With `--spec-type draft-mtp`:

- MTP draft context is created; measured **draft acceptance 31–44%** (150/438 and 129/414 tokens)
- decode: **17.6–18.1 tok/s** vs **20.4–20.5** without MTP → **≈10% slower**
- prompt processing: 490 vs 531 tok/s → also slower

Root cause: the MTP block is a full attention + MoE block; on an iGPU/APU the extra forward pass
costs more than the accepted tokens save. Unlike the Flash-Next case (+122%), MTP here is a net loss.

**Do not enable MTP for qwen35moe on this hardware.** Avoid `--spec-type draft-dflash` on this APU too
(llama.cpp issue #25117 reports ~2× regression on AMD APU + quantized MoE).

## Same-size / same-class alternatives

| Model | Total / active | Q4-ish size | Notes |
|---|---|---|---|
| **Qwen3.5-122B-A10B** (upstream of Ornith) | 122B / 10B | ~71.7 GB (UD-Q4_K_XL) | MIT; DGX Spark users report ~24 tok/s at 87 GB RAM |
| Ornith-1.5-122B i1-Q4_K_M (mradermacher) | 122B / 10B | 71.1 GB | same family, smaller quant ⇒ expect ~25 tok/s, quality drop unmeasured here |
| **Qwen3-Next-80B-A3B** | 80B / 3B | ~45–48 GB | community: **53–54 tok/s** gen, ~800 tok/s prompt — fastest by far; weaker than 122B-A10B |
| **GLM-4.5-Air 106B-A12B** | 106B / 12B | 68 GB (UD-Q4_K_XL) | llama.cpp has GLM-Air **MTP support** (v0.3.0, PR #26534) — the one architecture where MTP is proven |
| Llama-4-Scout 109B-A17B | 109B / 17B | ~65 GB @ Q4 | needs ~80 GB at Q5_K_M; M2 Ultra reports ~19 tok/s |

Reference point: a Ryzen AI MAX 395 (96 GB) benchmark of Qwen3.5-122B-A10B reports **22.9 tok/s** —
our 20.4 on Ornith Q5_K_M is the same ballpark, so this box is not underperforming.

## Reproduce

```powershell
llama-server.exe -m Ornith-1.5-122B-Q5_K_M-00001-of-00003.gguf `
  --host 127.0.0.1 --port 8090 -ngl 99 -c 8192 -ub 1024 -b 4096 --jinja -fa on
```

Set `chat_template_kwargs: {"enable_thinking": false}` in the request body, otherwise `content`
comes back empty and the answer sits in `reasoning_content`.
