# denton-runner — project charter

> **The greatest, most expansive, most widely-compatible runner ever made — while also hosting
> everything we design from scratch or by way of applied theory and experimentation.**

denton-runner is the inference substrate for DentonOS. It is **not** "a wrapper around llama.cpp."
It is a meta-engine that ingests *any* model artifact, routes intelligently, and serves both
off-the-shelf and from-scratch Denton models behind one backend that a GUI and a CLI share equally.

The Nix module `modules/denton-inference.nix` is the **deployment seed**; the crates below are the
engine. `runner = "omnirunner"` is the Nix switch that will select denton-runner once built (today it
falls back to llama-cpp — **no refusal**).

## Pillars

1. **Multi-format ingest.** One loader, many formats: GGUF, safetensors, PEFT/LoRA adapters,
   AWQ/GPTQ/EXL2, hipfire `.mq4`, and the from-scratch Denton formats (`.dtn`/`.nfz`, MoXE /
   trinary-MoE, CMWT omni-weight tensor). Detect format → dispatch to the right backend.
2. **Per-format intelligent prompt templating.** Each format/model family carries (or is matched to)
   the correct chat template, stop tokens, and system-prompt convention — applied automatically.
   No more wrong-template garbage output. (Ollama's one good idea — Modelfile templating — generalized.)
3. **Adapter routing.** Hot-swap / stack adapters per request; route a request to base+adapter(s)
   by task/archetype. Adapters are first-class, not bakes. Adapter methods now include **LoRA, DoRA,
   and DoLoRA** (plus other relevant methods: QLoRA / X-LoRA / PiSSA) — archetypes-as-LoRA on a shared
   base. Runtime dynamic adapter loading is gated behind auth + an allowlist (security). See
   **`denton-runner/ADAPTERS.md`**.
4. **Corpora / RAG routing.** Route a request to the right corpus/index (and the right retrieval
   strategy) per archetype/domain, then to the right model. The runner owns the corpus selector.
5. **GUI ⇄ CLI parity.** Both surfaces drive the **same backend API** — anything you can do in the
   GUI you can do in the CLI and vice-versa. Nobody is locked to one surface.
6. **Optional onboarding tutorial (recommended).** Shipped with the download. DentonOS works
   *differently* — interaction is closer to a **prompt / request / work-declaration by proxy** than a
   chat box — so first-run teaches the mental model.
7. **No refusal, anywhere.** The system never hard-refuses — it degrades, falls back, warns, and keeps
   serving. Refusal is **not** baked into models or the runner. Every model is **abliterated at intake**
   (≥80% efficacy ∧ ≥95% lossless, ×3 seeds/vectors, by audit — see ABLITERATION_AUDIT.md) so it carries
   no refusal direction. The *only* "no" in the system is the intake gate rejecting a model that fails
   that audit — never a runtime refusal to a user. **Harm-prevention over refusal is the RULE, not an
   option:** refusal is never weight-baked or runner-baked; safety is **external** (denton-vice
   harm-prevention counterweight + denton-vault), per project canon. The harm-prevention layer is the
   designed-in safety mechanism that *replaces* refusal — not a toggle that can be turned off.
8. **Widest compatibility.** Vulkan-first on AMD so it runs on everything from Polaris (gfx803) to
   RDNA3; ROCm where it helps; CPU always. CUDA/Metal backends as the fleet grows.
9. **Zero hardcoding / hardware-agnostic.** No system aspect, config, or build value is baked for one
   machine — everything is **detected or configured** (`scripts/detect-tier.sh` is the seed). The runner
   is designed for **anyone's hardware**, not Chase's AMD box. "**One model per GPU**" is the **AMD
   default**, but it is **configurable, never baked** — override it per node via GUI or CLI. The only
   bottleneck should ever be the user's *choice* to run local vs join a P2P denton-net / DAO, not a
   hardcoded assumption. See **`denton-runner/HARDWARE_AGNOSTIC.md`**.

## Crate breakdown (proposed — `denton-runner/crates/*`)

| Crate | Responsibility |
|-------|----------------|
| `denton-runner-core` | request lifecycle, scheduler, capability/VRAM-aware placement, the OpenAI-compat + native API |
| `denton-format` | format detection + unified model manifest (GGUF/safetensors/PEFT/.mq4/.dtn/.nfz); registers a model **only if `denton-abliterate gate` passes** |
| `denton-abliterate` | **intake gate (IMPERATIVE):** refusal-direction abliteration ×3 seeds/vectors + E/L scoring; ≥80% efficacy ∧ ≥95% lossless to register. See ABLITERATION_AUDIT.md |
| `denton-template` | per-format/family prompt-template resolver (templates, stops, system conventions) |
| `denton-lora` | adapter registry, hot-swap, per-request stacking + routing — LoRA/DoRA/DoLoRA (+ QLoRA/X-LoRA/PiSSA); auth+allowlist-gated dynamic load. See ADAPTERS.md |
| `denton-corpora` | corpus/index registry + RAG routing (which corpus + retrieval strategy per request) |
| `denton-backend-llamacpp` | llama.cpp/llama-server backend (Vulkan/ROCm/CPU) — the GGUF path |
| `denton-backend-hipfire` | in-house AMD Rust backend (`.mq4`) — sovereign path / proto-omnirunner |
| `denton-backend-native` | from-scratch Denton loader (candle/nfz-engine): `.dtn`/`.nfz`, MoXE, CMWT |
| `denton-runner-cli` | CLI surface (calls core API) |
| `denton-runner-gui` | GUI surface (Tauri; calls the SAME core API) — pairs with Denton-Desktop |
| `denton-tutorial` | first-run onboarding (the work-declaration-by-proxy model) |

## Dynamic hardware-tier flake (P2P / self-host by default)

Default posture: **anyone can join a P2P denton-net; if the node is capable, it self-hosts.** A
private denton-net gates joining. The flake should be **dynamic**: detect hardware → recommend a
**tier** → derive the nix spec, overridable by **user preference** (GUI or CLI).

```
hardware probe ─► tier ─► recommended denton.inference spec ─► (user/GUI/CLI override) ─► node config
```

Seed implemented now: **`scripts/detect-tier.sh`** probes CPU/RAM/GPU and prints a recommended tier
+ a paste-ready `denton.inference` / `denton.node` snippet. Both the GUI and CLI call this same
script → backend parity from day one.

| Tier | Rough capability | Default role |
|------|------------------|--------------|
| `micro` | ≤4 cores / ≤8G / no GPU | client / relay; remote-inference only |
| `worker` | ~8-16 cores / 16-32G / 1 GPU | single-model inference node (worker-01 today) |
| `server` | many cores / 64G+ / 2-12 GPUs | multi-model, multi-GPU serving |
| `brainstem` | desktop + GPU | orchestrator + inference + desktop (deferred to NixOS) |

## Prior-art decisions (research-backed, 2026)

13-project survey (RUNNERS.md has the table + sources). Decisions:

- **Architectural base = FORK LocalAI (MIT)** — the only single project that already does multi-format
  ingest + format→backend routing + a runtime **backend gallery** + per-model templates w/ tokenizer
  fallback + native multi-LoRA + built-in vector-store RAG (Stores/LocalRecall, with citations) +
  OpenAI/Anthropic/Ollama APIs + first-class ROCm **and** Vulkan + P2P federated inference. We **fork**
  it (MIT-clean base) rather than reinventing, then graft/extend. See **`denton-runner/FORK_PLAN.md`**
  for the fork strategy + naming (denton-runner / denton.cpp / LocalDenton / local-denton).
- **Graft the best of three others:** scheduler = **llama-swap** (`groups` + cost-aware `matrix`
  eviction); packaging = **Ollama's** OCI content-addressable, **template-travels-with-the-model**
  layers (dedup blobs) → our `.dtn`/`.nfz` registry + the abliteration record travels too; runtime LoRA
  = **vLLM** S-LoRA hot-load/unload + LoRAResolver → **archetypes-as-LoRA** (seeds→archetypes become
  hot-loadable adapters on a shared base — maps 1:1 to the Denton model hierarchy).
- **Three-tier prompt templating** (the "universal" answer): explicit per-model template → model's
  embedded tokenizer `chat_template` → auto-detect heuristic (KoboldCpp `AutoGuess`).
- **Corpora/RAG = a routable resource** parallel to model + LoRA (request carries a `store`/corpus
  field); serve embed + **rerank** natively.
- **Gateway layer separate from engine** (LiteLLM-style) so one OpenAI API fronts local engines AND
  external providers (DeepSeek/Kimi) — the provider-agnostic ethos.

**Pitfalls to design around** (from the survey):
- **AGPL contamination** — Aphrodite/KoboldCpp/text-gen-webui are AGPL; keep them *process-isolated,
  swappable* backends over a network boundary, **never static-linked** into the core.
- **Runtime LoRA-load is a security hole** (vLLM's own warning) — gate `/load_lora_adapter` behind
  auth + path allowlists; never expose arbitrary fs/HF loading on an open port.
- **One-base-model-per-process ceiling** on the throughput engines — scheduler must plan
  process-per-base + adapters-within-base with explicit VRAM accounting (else OOM).
- **ROCm is fork-fragile / per-card** — treat ROCm as a runtime capability check; Vulkan is the floor.
- **No embedded secrets** in model packages / example configs (keys by-name in `.env`).

## Build order

1. ✅ Nix deployment seed: pluggable `runner`, Vulkan-first, no-refusal fallback, scales 0→12 GPUs.
2. ✅ **Investigate + audit:** 13-project prior-art survey done (above) + AMD-arch viability (RUNNERS.md);
   QX/QC panel reviewing the design ($0 NIM+local).
3. **`denton-abliterate` intake gate** (IMPERATIVE, ABLITERATION_AUDIT.md) — stand up FIRST so every
   model entering the next steps is ≥80%-lossless-abliterated ×3-seed audited.
4. `denton-format` + `denton-template` + `denton-backend-llamacpp` → first real omnirunner slice (GGUF + correct templating).
5. `denton-lora` (archetypes-as-LoRA) + `denton-corpora` → routing.
6. `denton-backend-hipfire` revival (`.mq4`, stable gfx) → sovereign path.
7. `denton-backend-native` (`.dtn`/`.nfz`/MoXE) → host the from-scratch models.
8. `denton-runner-gui` + `denton-tutorial` → surfaces.
9. Flip the Nix `runner` default from `llama-cpp` → `omnirunner`.

See `RUNNERS.md` for the backend survey + AMD-arch viability table that feeds step 2.
