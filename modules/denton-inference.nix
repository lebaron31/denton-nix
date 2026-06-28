# denton-inference.nix — pluggable inference-runner module (DentonOS / denton-runner seed)
#
# RUNNER ABSTRACTION (denton.inference.runner):
#   "llama-cpp"  — DEFAULT, wired. GGUF via llama-server (OpenAI-compat API).
#   "hipfire"    — in-house Rust AMD-GPU backend (.mq4, :11435). Hook ready; needs a package.
#   "omnirunner" — FUTURE denton-runner meta-engine: multi-format ingest (GGUF/PEFT/safetensors),
#                  per-format prompt templating, LoRA routing, corpora/RAG routing. See RUNNERS.md.
#
# NO-REFUSAL PRINCIPLE (Chase directive): nothing here hard-aborts. Selecting a runner that
# isn't built yet → it WARNS and gracefully falls back to a working engine. gpuCount out of
# range → clamped with a warning. The system never refuses; it degrades and tells you.
# (Model-level safety is EXTERNAL — denton-vice counterweight + abliterated weights — never baked in.)
#
# OLLAMA IS BANNED — do not reintroduce services.ollama.
{ config, lib, pkgs, ... }:
let
  cfg = config.denton.inference;

  # ── No-refusal clamp: keep within the 0..12 per-server window instead of erroring ──
  effGpu = lib.min 12 (lib.max 0 cfg.gpuCount);
  hasGpu = effGpu > 0;
  multiGpu = effGpu > 1;

  # ── No-refusal runner fallback: unbuilt runner → llama-cpp, with a warning ──
  runnerReady = r:
    if r == "llama-cpp" then true
    else if r == "hipfire" then (cfg.hipfire.package != null)
    else false; # omnirunner: not built yet
  effRunner = if runnerReady cfg.runner then cfg.runner else "llama-cpp";
  isLlama = effRunner == "llama-cpp";
  isHipfire = effRunner == "hipfire";

  # ── Vendor-aware backend (HARDWARE-AGNOSTIC — no AMD lock). Vulkan is the cross-vendor
  #    floor (AMD Polaris→RDNA3, NVIDIA, Intel); rocm=AMD, cuda=NVIDIA when explicitly chosen. ──
  isAmd = cfg.gpuVendor == "amd";
  isNvidia = cfg.gpuVendor == "nvidia";
  resolvedBackend =
    if !hasGpu then "cpu"
    else if cfg.gpuBackend != "auto" then cfg.gpuBackend
    else if isNvidia then "cuda"   # NVIDIA auto → CUDA
    else "vulkan";                 # AMD/Intel/Apple/auto → Vulkan (most compatible)
  useRocm = resolvedBackend == "rocm";
  useVulkan = resolvedBackend == "vulkan";
  useCuda = resolvedBackend == "cuda";

  llamaBase =
    if useRocm then cfg.package.override { rocmSupport = true; }
    else if useCuda then cfg.package.override { cudaSupport = true; }
    else if useVulkan then cfg.package.override { vulkanSupport = true; }
    else cfg.package;

  # ── CPU codegen baseline (no-refusal: works on ANY x86, incl. AVX-less mining-rig CPUs) ──
  # The nixpkgs binary defaults to AVX2. On a CPU without AVX (Intel Celeron/Pentium — Comet
  # Lake fuses AVX off; tops out at SSE4.2) it SIGILLs at static-init (status=4/ILL, even on
  # `--version`). "portable" rebuilds with NO AVX/FMA/F16C so the same flake boots on junk CPUs.
  cpuOffFlags = map (n: lib.cmakeBool n false)
    [ "GGML_NATIVE" "GGML_AVX" "GGML_AVX2" "GGML_AVX512" "GGML_FMA" "GGML_F16C" "GGML_AVX_VNNI" ];
  cpuFlags =
    if cfg.cpuBaseline == "portable" then cpuOffFlags
    else if cfg.cpuBaseline == "native" then [ (lib.cmakeBool "GGML_NATIVE" true) ]
    else [];  # auto = nixpkgs default (AVX2 — fine on most CPUs)

  llamaPkg =
    if cpuFlags == [] then llamaBase
    else llamaBase.overrideAttrs (old: { cmakeFlags = (old.cmakeFlags or []) ++ cpuFlags; });

  gpuFlags = lib.optionals hasGpu
    ([ "-ngl" (toString cfg.gpuLayers) ] ++ lib.optionals multiGpu [ "--split-mode" cfg.splitMode ]);
  faFlag = lib.optional cfg.flashAttention "-fa";

  # Vulkan: force Mesa RADV (4GB single-alloc) over AMDVLK (2GB) — verified RX 580 OOM-avoidance.
  llamaEnv =
    (lib.optionalAttrs useVulkan { AMD_VULKAN_ICD = "RADV"; })
    // (lib.optionalAttrs (useRocm && cfg.rocmGfxVersion != null) { HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfxVersion; });

  activePort = if isHipfire then cfg.hipfire.port else cfg.port;
in
{
  options.denton.inference = {
    enable = lib.mkEnableOption "DentonOS inference node (pluggable runner + AMD GPU)";

    runner = lib.mkOption {
      type = lib.types.enum [ "llama-cpp" "hipfire" "omnirunner" ];
      default = "llama-cpp";
      description = "Engine. llama-cpp=working default; hipfire=in-house AMD; omnirunner=future denton-runner meta-engine. Unbuilt choices fall back (no refusal).";
    };

    gpuCount = lib.mkOption {
      type = lib.types.int; # NOT bounded-type: we clamp + warn rather than refuse
      default = 0;
      description = "AMD GPUs in THIS server. Clamped to 0..12 (per-server cap). 5 = the addition; 12 = ceiling. Cluster has clusterGpuCap.";
    };
    clusterGpuCap = lib.mkOption {
      type = lib.types.int; default = 12;
      description = "Doc-only: cluster-wide aggregate GPU budget for capacity planning.";
    };

    gpuVendor = lib.mkOption {
      type = lib.types.enum [ "auto" "amd" "nvidia" "intel" "apple" "cpu" ];
      default = "auto";
      description = "GPU vendor for THIS node — set per node (detect-tier.sh), NEVER hardcoded to one box. 'auto' forces no vendor kernel module + uses Vulkan (cross-vendor). amd→amdgpu/rocm-capable; nvidia→cuda-capable (host must add hardware.nvidia).";
    };
    gpuBackend = lib.mkOption {
      type = lib.types.enum [ "auto" "vulkan" "rocm" "cuda" "cpu" ];
      default = "auto";
      description = "Compute path. auto→vulkan (cross-vendor floor: AMD Polaris→RDNA3, NVIDIA, Intel) or cuda when gpuVendor=nvidia. rocm=AMD ROCm; cuda=NVIDIA.";
    };
    lanSubnets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.1.0/24" ];
      description = "LAN subnets allowed to reach the runner port (besides Tailscale). Per-node — not hardcoded; set [] for Tailscale-only.";
    };

    package = lib.mkOption {
      type = lib.types.package; default = pkgs.llama-cpp;
      description = "Base llama.cpp package; vulkan/rocm support layered via .override per gpuBackend.";
    };

    cpuBaseline = lib.mkOption {
      type = lib.types.enum [ "auto" "portable" "native" ];
      default = "auto";
      description = ''
        CPU codegen baseline for llama.cpp.
          auto     = nixpkgs default (AVX2) — fine on most CPUs, uses the binary cache.
          portable = NO AVX/AVX2/FMA/F16C (SSE4.2 only). REQUIRED on AVX-less CPUs such as
                     Intel Celeron/Pentium (Comet Lake fuses AVX off) — otherwise the binary
                     SIGILLs at static-init (status=4/ILL, fails even on `--version`).
                     NOTE: forces a from-source rebuild (slow on weak CPUs; not cached).
          native   = -march=native (single-host only, non-reproducible).
      '';
    };

    model = lib.mkOption {
      type = lib.types.str; default = "/var/lib/llama/models/default.gguf";
      description = "GGUF served by llama-server. Drop one here or set modelUrl.";
    };
    modelUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str; default = null;
      description = "Recommended-but-optional: fetch `model` once on first boot if absent.";
    };

    host = lib.mkOption { type = lib.types.str; default = "0.0.0.0"; description = "Bind address (Tailscale-reachable)."; };
    port = lib.mkOption { type = lib.types.port; default = 8080; description = "llama-server port (NOT 11434 — banned Ollama)."; };
    contextSize = lib.mkOption { type = lib.types.int; default = 4096; description = "Context window (-c)."; };
    parallel = lib.mkOption { type = lib.types.int; default = 1; description = "llama-server --parallel slots."; };
    gpuLayers = lib.mkOption { type = lib.types.int; default = 999; description = "-ngl GPU-offloaded layers (999=all)."; };
    flashAttention = lib.mkOption {
      type = lib.types.bool; default = true;
      description = "Flash attention (-fa). Shrinks KV cache — important for the RX 580's ~4GB usable Vulkan window (verified field finding).";
    };
    splitMode = lib.mkOption {
      type = lib.types.enum [ "layer" "row" "none" ]; default = "layer";
      description = "Multi-GPU --split-mode (effGpu>1). KEEP 'layer' on x1 risers (least interconnect). NOTE: multi-GPU here = VRAM pooling for bigger models, NOT more tok/s — for throughput run one model per GPU instead.";
    };
    rocmGfxVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str; default = null; example = "10.3.0";
      description = "HSA_OVERRIDE_GFX_VERSION (rocm backend only). RX 580=gfx803, RX 5700 XT=gfx1010.";
    };
    powerCapWatts = lib.mkOption {
      type = lib.types.nullOr lib.types.int; default = null; example = 150;
      description = ''
        Per-GPU power cap in WATTS via amdgpu sysfs power1_cap (clamped to each card's hardware
        max). null = stock. PSU PROTECTION: total draw ≈ powerCapWatts × cards + ~70W (board/CPU/
        risers). 4×150W = 600W GPU ≈ 670W system on a 750W PSU (~89% — high for 24/7; Navi10 has
        transient spikes above the cap that can trip OCP). For continuous load consider 130-135W
        (≈ 600W system, ~80% — the PSU efficiency/safety sweet spot). Cap is workload-independent,
        so it bounds draw whether a card is serving OR mining.
      '';
    };
    openFirewall = lib.mkOption { type = lib.types.bool; default = true; description = "Open the active runner port to Tailscale + LAN only."; };

    hipfire = {
      package = lib.mkOption { type = lib.types.nullOr lib.types.package; default = null; description = "Built denton-inference/hipfire bridge package. Enables runner=hipfire."; };
      port = lib.mkOption { type = lib.types.port; default = 11435; description = "hipfire bridge port."; };
      modelDir = lib.mkOption { type = lib.types.str; default = "/var/lib/hipfire/models"; description = "Where .mq4 models live."; };
    };
  };

  config = lib.mkIf cfg.enable {
    # ── Warnings instead of refusals ──
    warnings =
      lib.optional (cfg.gpuCount != effGpu)
        "denton.inference.gpuCount ${toString cfg.gpuCount} clamped to ${toString effGpu} (0..12 per-server cap; see clusterGpuCap)."
      ++ lib.optional (cfg.runner != effRunner)
        "denton.inference.runner=\"${cfg.runner}\" isn't built yet (omnirunner unbuilt / hipfire needs a package + .mq4) — falling back to \"${effRunner}\". No refusal; see RUNNERS.md."
      ++ lib.optional (useRocm && !isAmd)
        "denton.inference: gpuBackend=rocm but gpuVendor!=amd — ROCm is AMD-only; set gpuVendor=\"amd\" or use vulkan."
      ++ lib.optional (useCuda && !isNvidia)
        "denton.inference: cuda backend selected but gpuVendor!=nvidia — set gpuVendor=\"nvidia\" (+ hardware.nvidia in the host).";

    # ── GPU stack (VENDOR-AWARE — amdgpu only on AMD nodes; never forced on NVIDIA/Intel/CPU) ──
    boot.initrd.kernelModules = lib.mkIf (hasGpu && isAmd) [ "amdgpu" ];
    hardware.amdgpu.opencl.enable = isAmd && useRocm;
    hardware.graphics = {
      enable = true;
      enable32Bit = lib.mkDefault false;
      extraPackages = lib.mkIf useRocm (with pkgs; [ rocmPackages.clr rocmPackages.clr.icd ]);
    };
    services.udev.extraRules = lib.mkIf hasGpu ''
      SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660"
      SUBSYSTEM=="drm", KERNEL=="card*",    GROUP="video",  MODE="0660"
    '';
    systemd.tmpfiles.rules = [
      "d /var/lib/llama/models 0750 root root - -"
      "d ${cfg.hipfire.modelDir} 0750 root root - -"
    ];

    # ── GPU power cap (PSU protection) — declarative sysfs power1_cap, no rocm-smi needed.
    #    Bounds draw regardless of workload (inference OR mining), clamped per-card to hw max. ──
    systemd.services.denton-gpu-powercap = lib.mkIf (hasGpu && cfg.powerCapWatts != null) {
      description = "DentonOS AMD GPU power cap (${toString cfg.powerCapWatts}W/card via sysfs)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      path = [ pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        set -u
        CAP_UW=$(( ${toString cfg.powerCapWatts} * 1000000 ))
        shopt -s nullglob
        for cap in /sys/class/drm/card*/device/hwmon/hwmon*/power1_cap; do
          dir=$(dirname "$cap")
          max=$(cat "$dir/power1_cap_max" 2>/dev/null || echo 0)
          want=$CAP_UW
          if [ "$max" -gt 0 ] && [ "$want" -gt "$max" ]; then want=$max; fi
          if echo "$want" > "$cap" 2>/dev/null; then
            echo "capped $cap -> $((want / 1000000))W"
          else
            echo "WARN: could not write $cap (card may not support power cap)"
          fi
        done
      '';
    };

    # ── Runner: llama-cpp (default / fallback) ──
    services.llama-cpp = lib.mkIf isLlama {
      enable = true;
      package = llamaPkg;
      host = cfg.host;
      port = cfg.port;
      model = cfg.model;
      openFirewall = false;
      extraFlags = [ "-c" (toString cfg.contextSize) "--parallel" (toString cfg.parallel) ] ++ faFlag ++ gpuFlags;
    };
    systemd.services.llama-cpp.serviceConfig.SupplementaryGroups = lib.mkIf (isLlama && hasGpu) [ "render" "video" ];
    systemd.services.llama-cpp.environment = lib.mkIf isLlama llamaEnv;
    systemd.services.denton-model-fetch = lib.mkIf (isLlama && cfg.modelUrl != null) {
      description = "Fetch llama.cpp GGUF model if absent (DentonOS)";
      wantedBy = [ "multi-user.target" ];
      before = [ "llama-cpp.service" ];
      path = [ pkgs.curl ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        if [ ! -s "${cfg.model}" ]; then
          echo "fetching ${cfg.modelUrl} -> ${cfg.model}"
          curl -fL --retry 3 -o "${cfg.model}" "${cfg.modelUrl}"
        fi
      '';
    };

    # ── Runner: hipfire (materializes only when a package is supplied) ──
    systemd.services.denton-hipfire = lib.mkIf (isHipfire && cfg.hipfire.package != null) {
      description = "DentonOS hipfire AMD-GPU inference bridge (.mq4)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${cfg.hipfire.package}/bin/denton-hipfire-bridge --port ${toString cfg.hipfire.port} --models ${cfg.hipfire.modelDir}";
        Restart = "on-failure";
        DynamicUser = true;
        SupplementaryGroups = lib.mkIf hasGpu [ "render" "video" ];
        Environment = lib.mkIf (cfg.rocmGfxVersion != null) [ "HSA_OVERRIDE_GFX_VERSION=${cfg.rocmGfxVersion}" ];
      };
    };

    # ── Tooling (CPU-safe; GPU diag by backend) ──
    environment.systemPackages = lib.optional isLlama llamaPkg
      ++ lib.optional (isHipfire && cfg.hipfire.package != null) cfg.hipfire.package
      ++ lib.optionals hasGpu (with pkgs; [ nvtopPackages.amd ])
      ++ lib.optionals (hasGpu && useVulkan) (with pkgs; [ vulkan-tools ])
      ++ lib.optionals (hasGpu && useRocm) (with pkgs; [ rocmPackages.rocm-smi rocmPackages.rocminfo rocmPackages.rocm-runtime clinfo ]);

    # ── Firewall: active runner port over Tailscale + LAN, dropped publicly ──
    networking.firewall = lib.mkIf cfg.openFirewall {
      enable = lib.mkDefault true;
      trustedInterfaces = [ "tailscale0" ];
      extraCommands = lib.concatMapStrings (net: ''
        iptables -A nixos-fw -p tcp --dport ${toString activePort} -s ${net} -j nixos-fw-accept || true
      '') cfg.lanSubnets;
    };
  };
}
