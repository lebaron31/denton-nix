# worker-01 (denton-worker-01, Tailscale 100.102.176.60) — THE NixOS inference test.
#
# Mission: clean-slate, plug-and-play inference SERVER. Brand-new image, fresh flake,
# hardened from boot. Engine = llama.cpp / llama-server (Ollama is banned).
#
# TODAY:  Ubuntu, CPU inference. TARGET: NixOS, gpuCount 0 → 5 (addition) → 12 (cap).
# Cutover is a DESTRUCTIVE reinstall — back up models first (see SECRETS.md / README).
{ config, pkgs, lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/denton-disko.nix       # declarative partitioning (turnkey install)
    ../../modules/denton-base.nix        # flakes, tailscale, ssh, admins
    ../../modules/denton-hardening.nix   # ssh/kernel/net hardening, fail2ban, zram
    ../../modules/denton-inference.nix   # llama-server + ROCm, scales 0→12 GPUs
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 3;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "denton-worker-01";

  # ── Disk: /dev/sda (931.5G, UEFI) confirmed via lsblk. disko ERASES it on install.
  #    Currently Ubuntu-on-LVM (sda1 /boot/efi, sda2 /boot, sda3 LVM root). ──
  denton.disk.device = "/dev/sda";

  # ── RECOMMENDED-BUT-BYO access (the "suggested keys") — replace before cutover ──
  # Paste your real pubkey(s) so SSH works the moment it boots (no console needed).
  denton.access.sshKeys = [
    # "ssh-ed25519 AAAA...your-key... chase@macbook"
  ];
  # Recommended: an EPHEMERAL Tailscale auth key in this file so the box self-joins
  # the tailnet on first boot, unattended. Generate at https://login.tailscale.com/admin/settings/keys
  # denton.access.tailscaleAuthKeyFile = "/var/lib/secrets/tailscale.key";

  # ── Inference role ──
  denton.inference = {
    enable = true;
    # ── THE ONE KNOB ── this rig is the ex-HiveOS miner: 4× RX 570 (Polaris/gfx803,
    # ~4GB) + 1× RX 5700 XT (RDNA1/gfx1010, ~8GB) = 5 AMD GPUs. Vulkan (auto) sees all
    # of them — ROCm dropped gfx803. If fewer are seated, the no-refusal module clamps +
    # warns (never breaks); verify with `vulkaninfo --summary` before raising further.
    gpuCount = 5;
    gpuVendor = "amd";   # this box is AMD; nodes set their own vendor (never hardcoded fleet-wide)
    # gfx803 is DROPPED by modern ROCm → Vulkan is the reliable path. auto = vulkan.
    gpuBackend = "auto";
    rocmGfxVersion = null; # only used if gpuBackend = "rocm"
    # ── CPU is an Intel Celeron G5920 (Comet Lake, AVX FUSED OFF — SSE4.2 only). The stock
    #    AVX2 llama-cpp binary SIGILLs at init (status=4/ILL, dies even on `--version`).
    #    "portable" rebuilds with no AVX so it runs. Compiles from source (slow on 2 cores). ──
    cpuBaseline = "portable";
    # Recommended starter model — drop a GGUF at `model`, or set modelUrl to auto-fetch.
    model = "/var/lib/llama/models/default.gguf";
    # modelUrl = "https://huggingface.co/<repo>/resolve/main/<model>.Q4_K_M.gguf";
    contextSize = 4096;
    parallel = 1;
  };

  system.stateVersion = "24.11";
}
