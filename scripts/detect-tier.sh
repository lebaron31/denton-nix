#!/usr/bin/env bash
# detect-tier.sh — DentonOS dynamic hardware-tier detector (denton-runner seed).
#
# Probes CPU/RAM/GPU, recommends a node TIER, and prints a paste-ready `denton.*` nix snippet.
# This is the SHARED BACKEND for both the GUI and the CLI — both call this, so the two surfaces
# agree by construction. User preference can override the recommendation afterwards.
#
# Usage:
#   ./detect-tier.sh            # human-readable + nix snippet
#   ./detect-tier.sh --json     # machine-readable (for the GUI)
set -euo pipefail

cores=$(nproc 2>/dev/null || echo 1)
ram_gib=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)

# Count AMD/NVIDIA display/3D controllers as candidate GPUs.
gpu_lines=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' || true)
gpu_count=$(printf '%s\n' "$gpu_lines" | grep -ciE 'amd|ati|nvidia' || true)
gpu_count=${gpu_count:-0}

# Best-effort AMD arch → recommended backend (Vulkan is the safe default for old AMD).
gpu_backend="cpu"
arch_note="no discrete GPU detected"
if printf '%s' "$gpu_lines" | grep -qiE 'ellesmere|polaris|RX 4[78]0|RX 5[78]0'; then
  gpu_backend="vulkan"; arch_note="AMD Polaris (gfx803) — ROCm dropped → Vulkan"
elif printf '%s' "$gpu_lines" | grep -qiE 'navi 1[04]|RX 5[67]00'; then
  gpu_backend="vulkan"; arch_note="AMD RDNA1 (gfx1010) — Vulkan recommended"
elif printf '%s' "$gpu_lines" | grep -qiE 'navi 2|RX 6[6789]00'; then
  gpu_backend="rocm"; arch_note="AMD RDNA2 (gfx1030) — ROCm w/ HSA_OVERRIDE=10.3.0"
elif printf '%s' "$gpu_lines" | grep -qiE 'navi 3|RX 7[6789]00'; then
  gpu_backend="rocm"; arch_note="AMD RDNA3 (gfx1100) — ROCm"
elif printf '%s' "$gpu_lines" | grep -qiE 'nvidia'; then
  gpu_backend="cpu"; arch_note="NVIDIA detected — CUDA backend TBD (denton-runner roadmap)"
elif [ "$gpu_count" -gt 0 ]; then
  gpu_backend="vulkan"; arch_note="discrete GPU detected — defaulting to Vulkan"
fi

# Tier heuristic.
if   [ "$gpu_count" -ge 2 ] && [ "$ram_gib" -ge 48 ]; then tier="server"
elif [ "$gpu_count" -ge 1 ] && [ "$cores" -ge 6 ];    then tier="worker"
elif [ "$cores" -le 4 ] || [ "$ram_gib" -le 8 ];      then tier="micro"
else tier="worker"; fi

# Recommended inference defaults by tier.
case "$tier" in
  micro)  enable=false; parallel=1; ctx=2048 ;;
  worker) enable=true;  parallel=1; ctx=4096 ;;
  server) enable=true;  parallel=4; ctx=8192 ;;
  *)      enable=true;  parallel=1; ctx=4096 ;;
esac
[ "$gpu_count" -gt 12 ] && gpu_count=12   # per-server cap (the module clamps too)

if [ "${1:-}" = "--json" ]; then
  printf '{"tier":"%s","cores":%s,"ram_gib":%s,"gpu_count":%s,"gpu_backend":"%s","arch":"%s","inference_enable":%s,"parallel":%s,"context":%s}\n' \
    "$tier" "$cores" "$ram_gib" "$gpu_count" "$gpu_backend" "$arch_note" "$enable" "$parallel" "$ctx"
  exit 0
fi

cat <<EOF
DentonOS node probe
  cores ........ $cores
  ram .......... ${ram_gib} GiB
  gpus ......... $gpu_count  ($arch_note)
  → tier ....... $tier

Recommended nix (override per preference):

  denton.node.tier = "$tier";              # informational
  denton.inference = {
    enable = $enable;
    gpuCount = $gpu_count;
    gpuBackend = "$( [ "$gpu_backend" = cpu ] && echo auto || echo "$gpu_backend" )";
    parallel = $parallel;
    contextSize = $ctx;
  };
EOF
