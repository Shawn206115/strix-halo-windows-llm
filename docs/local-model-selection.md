# Local model selection on this machine (measured, not paper scores)

Everything here was run on the same box (Ryzen AI MAX+ 395, 96 GB carveout, 112 GB pagefile, commit limit 143.6 GB) with the same prompts and the same scripts, `temperature=0`, `enable_thinking=false`.

Two rules that came out of doing this twice:

1. **Paper benchmarks do not transfer to local chat workloads.** Ornith-1.5-122B leads Qwen3.8-Flash-Next on SWE-bench Pro (76.9 vs 43.9) and on HLE-with-tools (48 vs 38). On our own tasks the two models tie on accuracy and Flash is ~2× faster. Agentic-coding scores describe a tool-using loop, not a single-turn answer.
2. **Never mix numbers from different test sets.** Earlier notes compared "hard 4/5" against "hard 3/3" and drew conclusions from it. Same script, same run, or it does not count.

## What is installed

| Model | Quant | Size | Load | Decode | Vision | Notes |
|---|---|---|---|---|---|---|
| Qwen3.8-Flash-Next (176.9B MoE) | UD-IQ4_XS | 87.2 GB | 120 s (with MTP + mmproj) | **41.8 tok/s** (MTP) / 18.8 (no MTP) | ✅ text + image + video | default general model |
| Ornith-1.5-122B (MoE) | Q5_K_M | 88.4 GB | 104.7 s | 20.1 tok/s | ❌ no mmproj in the repo | deleted after these tests |
| Ornith-1.5-122B (MoE) | Q6_K | 101.79 GB | 60 s | 18.3 tok/s | ❌ | deleted earlier; proves the 112 GB ceiling |
| Qwen3.8-27B + MTP | UD-Q4_K_XL | 16.45 GB | ~20 s | 32.5 tok/s | ✅ via mmproj-F16 (0.84 GB) | math / strict-constraint tasks |
| Qwen3-Coder-Next | UD-IQ4_XS | 35.8 GB | ~45 s | 42.6 tok/s | ❌ | code backend, loaded on demand |
| Qwen3.6-35B-A3B | UD-Q4_K_XL | 21.3 GB | ~25 s | 52.1 tok/s | ❌ | light chat |

## Accuracy, same 6-question suite (`tools/bench-acc-ornith.py`)

Trivial math + one logic trap + one code snippet. Everything scores 6/6, so **this suite only proves nothing is broken** — it does not rank models.

| Model | Score | Total time | Avg |
|---|---|---|---|
| Flash-Next | 6/6 | **5.9 s** | 1.0 s |
| Ornith Q5_K_M | 6/6 | 6.3 s | 1.1 s |
| Ornith Q6_K | 6/6 | 6.0 s | 1.0 s |

## Accuracy, same 3-question hard set (`tools/bench-hard3.py`)

Snail-in-well trap, eigenvalue of `[[1,3],[2,2]]`, and merge-intervals code.

| Model | Score | Total | Snail | Eigen | Merge |
|---|---|---|---|---|---|
| Flash-Next | 2/3 | **3.7 s** | ❌ (answered 6) | ✅ 4,1 | ✅ 2.5 s / 103 tok |
| Ornith Q5_K_M | 2/3 | 6.8 s | ❌ (answered 6) | ✅ 4,1 | ✅ 5.3 s / 103 tok |

Both models miss the snail puzzle, so that item discriminates nothing. The eigenvalue item matters: **Qwen3-Coder-Next got it wrong** (`3,3,1` instead of `4,1,1`), which is why Coder-Next is never used for math here.

27B additionally failed a 3×3 linear system in the 5-partcap suite (`2/3, 13/3, -7/3`; correct `2, 3, -1`), so "small model = safer at math" is false in general — check before trusting.

## Multimodal

- Flash-Next: `/v1/models` reports `capabilities: ["completion","multimodal"]` and `input_modalities: ["text","image","video"]`. With `--mmproj mmproj-F16.gguf` it reads a screenshot correctly (numbers and symbols included).
- Ornith (both quants): the GGUF repos ship **no** mmproj. Sending an image returns `HTTP 500 image input is not supported - hint: ... you may need to provide the mmproj`. Qwen3.5-MoE is a text-only base, so there is nothing to attach.

## Reproduce

```powershell
# Flash-Next: MTP + vision, 8090
E:\llama.cpp\halobox-b1049\llama-server.exe `
  -m F:\models\gguf\qwen38-flash-next\Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00004.gguf `
  -md F:\models\gguf\flash-mtp\mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf `
  --mmproj F:\models\gguf\flash-mtp\mmproj-F16.gguf `
  -ngl 999 -fa 1 -ctk q8_0 -ctv q8_0 -ub 1024 -b 4096 -c 8192 -np 1 --port 8090

python tools\bench-acc-ornith.py flash
python tools\bench-hard3.py flash
```

## Selection at the end of the day

- **General conversation / reading screenshots / long context**: Flash-Next.
- **Math and anything that must follow strict constraints**: 27B (+MTP).
- **Code**: Coder-Next, on demand (`local-ask.py code`), never for math.
- **Ornith 122B**: deleted. It tied on accuracy, ran at half the speed, and had no vision.

Result files: `out/acc-flash.json`, `out/acc-ornith-q5.json`, `out/acc-ornith-q6.json`, `out/hard3-flash.json`, `out/hard3-q5.json`, `out/cap-flash.json`, `out/cap-27b.json`.
