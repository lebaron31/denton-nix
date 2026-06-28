# denton-nix

Plug-and-play **NixOS inference-server** configs for the DentonOS cluster.

**Mission:** make **worker-01** the clean-slate, hardened, reproducible NixOS *inference test*.
Brand-new image, fresh flake, hardened from boot. Engine = **llama.cpp / llama-server**
(**Ollama is banned**), behind a pluggable **runner** abstraction that is the deployment seed of the
**denton-runner** project (multi-format ingest · per-format templating · LoRA/corpora routing ·
GUI⇄CLI parity · omnirunner) — see **DENTON_RUNNER.md**.

**No refusal anywhere:** picking an unbuilt runner or an out-of-range GPU count never aborts — it
falls back / clamps and **warns**. Safety is external (denton-vice + abliterated weights), never baked in.

> Phasing (per Chase): **worker-01 first.** brainstem NixOS migration is **deferred** until the
> project nears end-goals. Custom image artifacts + image-compat/optimization are a **later phase**.

## Layout

```
flake.nix                      # nixpkgs 24.11 + disko; outputs worker-01 (+ deferred brainstem overlay)
modules/
  denton-base.nix              # headless base: flakes, Tailscale, hardened SSH, admins, recommended-keys options
  denton-hardening.nix         # ssh/kernel/net sysctls, fail2ban, zram, trimmed attack surface
  denton-inference.nix         # ⭐ pluggable runner (llama-cpp|hipfire|omnirunner), scales 0→12 GPUs
  denton-disko.nix             # declarative disk (GPT+ESP+ext4) — turnkey, no manual parted
hosts/
  worker-01/configuration.nix  # THE inference node. One knob: denton.inference.gpuCount
  worker-01/hardware-configuration.nix  # ⚠️ placeholder — regenerate on the box
  brainstem-inference.nix      # deferred "new card" overlay (import into dentoncode/nix later)
RUNNERS.md                     # runner survey + the omnirunner design
SECRETS.md                     # recommended-but-BYO keys (ssh, tailscale, model)
```

## The one knob

When the **5-card addition** is seated, edit `hosts/worker-01/configuration.nix`:

```nix
denton.inference.gpuCount = 5;            # 0 today → 5 (addition) → 12 (hard per-server cap)
denton.inference.rocmGfxVersion = "10.3.0";  # set to the card family (see RUNNERS.md table)
```

Nothing else changes: the ROCm build, `-ngl`, multi-GPU `--split-mode`, GPU diag tools, and group
permissions all switch on from that count. The **cluster** has its own aggregate cap (`clusterGpuCap`, 12).

## Plug-and-play install (stock NixOS ISO + disko + flake)

⚠️ **DESTRUCTIVE** — wipes the worker's disk. Back up Ollama models first (see SECRETS.md).

```bash
# 0. Pre-reqs: set your SSH key + (optional) Tailscale auth key in configuration.nix / SECRETS.md,
#    and CONFIRM the disk device:  lsblk   (then set denton.disk.device)

# 1. Boot the stock NixOS 24.11 minimal ISO on worker-01, get this flake onto it
git clone <denton-nix remote> /tmp/denton-nix && cd /tmp/denton-nix

# 2. Partition + format + mount, declaratively (ERASES the disk)
sudo nix --experimental-features 'nix-command flakes' run github:nix-community/disko -- \
  --mode destroy,format,mount ./modules/denton-disko.nix

# 3. Generate the REAL hardware config (omit filesystems — disko owns them)
sudo nixos-generate-config --no-filesystems --root /mnt \
  --show-hardware-config > hosts/worker-01/hardware-configuration.nix

# 4. Install + reboot
sudo nixos-install --flake .#worker-01
reboot
```

After reboot it self-joins Tailscale (if you set the auth key) and serves `llama-server` on `:8080`,
reachable over the tailnet / LAN only.

## Status (verified 2026-06-22)

Evaluated against nixpkgs 24.11 on brainstem (`nix eval`, not just parse):
- ✅ `worker-01` (disko + hardening + llama-cpp, gpuCount 0) → real `nixos-system` derivation
- ✅ 1-GPU and 5-GPU paths eval; 5-GPU emits `-ngl 999 --split-mode layer`
- ✅ `brainstem-inference` overlay evals
- ✅ runner guards honest: `omnirunner` and `hipfire`-without-package **fall back to llama-cpp + warn** (no refusal)
- ⚠️ `hardware-configuration.nix` is a placeholder (real one is generated on the box, step 3)
- ⏭️ Building the closure / a custom image = later (needs the cards + on-box hardware scan)

## Relationship to `dentoncode/nix`

That flake targets **brainstem** (`#digital-nvsble`) and has a **corrupted `flake.nix`** (markdown-
fenced docs — won't evaluate). denton-nix is the clean, evaluated worker-first flake. The modules
here (`base`/`inference`/`hardening`/`disko`) are exported via `nixosModules` so the eventual
brainstem migration can import them instead of duplicating. Merging/relocating denton-nix into
`dentoncode/nix` (or its own repo) is an open call — see the host's owner.
