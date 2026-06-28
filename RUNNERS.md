# Inference Runners — investigation + the omnirunner / denton-runner direction

> Full project vision + crates: **DENTON_RUNNER.md**. This file is the backend **survey** that feeds
> the architecture decision (step 2: investigate → QX/QC audit).

**Directive:** Ollama is **banned**. llama.cpp/llama-server is the working default. hipfire is
the in-house AMD ROCm runner — **VERIFIED working on RDNA1 (gfx1010) AND RDNA2 (gfx1030)** ROCm
(Chase disproved the old segfault/P5-block claim 2026-06-22); it still needs `.mq4` models built.
We keep evaluating alternatives and are designing a new runner —
the **omnirunner** (the engine behind denton-runner) — for Denton's *new* model formats.
**No refusal:** picking an unbuilt runner doesn't error — it falls back to a working engine + warns.

> ⚠️ The hardest constraint is **which AMD GPUs the 5-card addition uses.** ROCm support is
> tiered by architecture, and it dictates which runners are even viable. Decide cards → then runner.

## AMD architecture → runner viability (the gate)

| Arch | Example | gfx | ROCm status | Realistic runners |
|------|---------|-----|-------------|-------------------|
| GCN4 / Polaris | **RX 580 (worker-01 today)** | gfx803 | **dropped** | llama.cpp **Vulkan** (RADV) |
| RDNA1 | RX 5700 XT (brainstem today) | gfx1010 | **unsupported** officially (not even in ROCm 7) | llama.cpp **Vulkan**, MLC-LLM (Vulkan), **hipfire (ROCm — VERIFIED working on gfx1010, 2026-06-22)** |
| RDNA2 | RX 6800/6900 | gfx1030 | works w/ `HSA_OVERRIDE_GFX_VERSION=10.3.0` | llama.cpp ROCm/Vulkan, **hipfire (ROCm — VERIFIED working on gfx1030, 2026-06-22)**, (vLLM partial) |
| RDNA3 | RX 7900 XTX | gfx1100 | **good** | llama.cpp ROCm, vLLM, SGLang, TGI |
| CDNA | MI210/MI300 | gfx90a/942 | **first-class** | vLLM, SGLang, TGI, llama.cpp |

**Takeaway:** if the 5 cards are RDNA1/2, the realistic stack is **llama.cpp (Vulkan or ROCm) +
hipfire** — and **hipfire is now a viable in-house AMD ROCm backend on both** (gfx1010 RDNA1 AND
gfx1030 RDNA2 — Chase disproved the old segfault/P5-block claim on 2026-06-22; it still needs `.mq4`
models built). vLLM/SGLang/TGI only pay off at **RDNA3+/CDNA**. Tell me the cards and I'll set
`rocmGfxVersion` + pick the backend.

### Verified field findings (2026 research) — applied to the module

worker-01's actual card is an **RX 580 (Polaris, gfx803)**. Confirmed by sourced research:

- **ROCm dropped gfx803 (and gfx1010); ROCm 7 officially supports only RDNA2+.** → **Vulkan is the
  fleet-wide standard backend** — one build runs Polaris→RDNA3 and tolerates mixed-arch boxes. *(now the `auto` default.)*
- **Real throughput:** RX 580, 7B Q4 via Vulkan ≈ **258 t/s prompt, ~39 t/s generation** — usable.
- **Use Mesa RADV, not AMDVLK:** RADV allows **4GB** single allocations vs AMDVLK's **2GB**; old AMD+Vulkan
  only addresses ~4GB of the 8GB anyway. *(module forces `AMD_VULKAN_ICD=RADV`.)*
- **Flash attention (`-fa`)** shrinks KV to fit that window. *(module sets `flashAttention=true`.)*
- **Multi-GPU on x1 risers = VRAM pooling, NOT throughput.** Always `--split-mode layer` *(default)*; for
  aggregate throughput prefer **one model per GPU** (`GGML_VK_VISIBLE_DEVICES`) over one N-way split.
- **Many-GPU physical:** enable **Above-4G Decoding + ReBAR** in BIOS; ~185W/card (12× ≈ 2.2kW); test
  output **coherence at real context length** (layer-split has long-context garbage bugs on non-P2P PCIe).
- For any **RDNA2+** cards added later, build a **separate HIP binary** and run them as their own workers —
  don't pool a fast HIP card into a Vulkan layer-split with slow RX 580s.

Sources: [llama.cpp Vulkan scoreboard #10879](https://github.com/ggml-org/llama.cpp/discussions/10879) ·
[dadhacks RX 580 + Vulkan](http://dadhacks.org/2025/08/04/running-large-language-models-on-cheap-old-rx-580-gpus-with-llama-cpp-and-vulkan/) ·
[SitePoint RX 580 cluster](https://www.sitepoint.com/poverty-spec-ai-cluster-rx-580-local-llm/) ·
[llm-tracker AMD GPUs](https://llm-tracker.info/howto/AMD-GPUs) · [llama.cpp multi-gpu.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md)

## Candidates surveyed (all options, some recommended)

| Runner | What it's good at | AMD fit | Verdict for Denton |
|--------|-------------------|---------|--------------------|
| **llama.cpp / llama-server** | GGUF, every quant, Vulkan+ROCm, OpenAI API, runs on *anything* | RDNA1→CDNA (Vulkan fallback) | ✅ **DEFAULT.** Most portable; survives RDNA1. Wired now. |
| **hipfire** (in-house) | Rust-native AMD ROCm, `.mq4` quant, sovereign, :11435 | RDNA1 gfx1010 **+** RDNA2 gfx1030 (VERIFIED 2026-06-22) | ✅ **Viable in-house AMD ROCm backend** + seed of the omnirunner. **CORRECTION (2026-06-22):** Chase disproved the old "segfault / P5-blocked on gfx1030" claim — hipfire WORKS on gfx1010 AND gfx1030 ROCm. Remaining work is just building the `.mq4` models (empty `~/.hipfire/models`), not a runner block. |
| **MLC-LLM (TVM)** | Compiles to Vulkan/ROCm/Metal; genuinely runs on RDNA1 | RDNA1+ via Vulkan | 🔎 **Watch** — best non-llama.cpp option for old AMD; own compile/quant flow. |
| **vLLM** | Throughput king: PagedAttention, continuous batching | RDNA3+/CDNA | 🔭 **Later** — adopt when server cards are RDNA3+/CDNA; ideal for the multi-card box then. |
| **SGLang** | RadixAttention, structured/agentic decoding, fast | CDNA-focused | 🔭 **Later** — strong for agent workloads at RDNA3+/CDNA. |
| **TGI** | Production serving, tensor-parallel | CDNA-tilted | 🔭 Heavy; only at CDNA scale. |
| **ktransformers** | MoE expert-offload (GPU+CPU), RAM-frugal | CUDA-first, ROCm WIP | 🔎 **Watch for MoXE** — its expert-offload maps onto Denton's MoE + RAM-limited nodes. |
| **candle** (HF Rust) | Rust-native tensors; `denton-candle` already exists | backend-dependent | 🔎 **omnirunner substrate** — Rust path for native Denton formats. |
| **ExLlamaV2** | Fast EXL2 on NVIDIA | **CUDA only** | ❌ No AMD. Skip for this fleet. |

## The omnirunner — what we're designing

A **format-dispatch meta-runner**: one OpenAI-compatible endpoint + cluster-aware scheduler that
routes by *model format* to the right backend, so new Denton model types don't need a new server.

```
            ┌─────────────── omnirunner (one API, capability/VRAM-aware) ───────────────┐
 request →  │  detect format → route                                                     │
            │     .gguf  →  llama.cpp / llama-server   (portable, Vulkan/ROCm)            │
            │     .mq4   →  hipfire                     (sovereign AMD, Rust)             │
            │     .dtn / .nfz / MoXE  →  native Denton loader (nfz-engine / candle):      │
            │                            trinary MoE, CMWT omni-weight tensor, expert     │
            │                            offload à la ktransformers                       │
            └────────────────────────────────────────────────────────────────────────────┘
```

Why it's the right shape:
- Denton is **designing new model formats** (`.dtn`/`.nfz`, MoXE/trinary-MoE, CMWT) that **no
  off-the-shelf runner understands** — so we need our own loader anyway.
- hipfire is already a custom-format Rust AMD runner → it's the **proto-omnirunner**; the `.mq4`
  path becomes one branch.
- Folds into the existing inference-routing charter (fast→quality→council→workers→OpenRouter),
  minus Ollama.

**Status:** reserved in the Nix module. `denton.inference.runner = "omnirunner"` **falls back to
llama-cpp + warns** today (no refusal — it just isn't built yet). Build order: (1) build hipfire's
`.mq4` models (the runner itself is VERIFIED working on gfx1010 + gfx1030 ROCm as of 2026-06-22) →
(2) native `.dtn`/`.nfz` loader (candle/nfz-engine) → (3) the dispatcher +
scheduler → (4) flip the Nix default from `llama-cpp` to `omnirunner`. See DENTON_RUNNER.md.

## How this maps to the Nix module (`modules/denton-inference.nix`)

`denton.inference.runner` is the switch (no-refusal — unbuilt choices degrade, not error):
- `"llama-cpp"` — wired, default, works at gpuCount 0→12; Vulkan/ROCm/CPU via `gpuBackend`.
- `"hipfire"` — service hook ready; runner VERIFIED on gfx1010 + gfx1030 ROCm (2026-06-22); needs `denton.inference.hipfire.package` + a built `.mq4` model. **Falls back to llama-cpp + warns** until the `.mq4` is supplied.
- `"omnirunner"` — reserved; **falls back to llama-cpp + warns**, with a pointer here.
