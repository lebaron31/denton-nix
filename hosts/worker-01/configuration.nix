# worker-01 (denton-worker-01) — THE NixOS inference test.
#
# TAILSCALE IDENTITY IS DYNAMIC — do NOT hardcode the IP anywhere. A reinstall re-registers
# the node under a NEW key/IP (it moved 100.102.176.60 → 100.68.82.99 on the NixOS cutover; the
# old .60 is now a stale "offline" ghost — delete it in the admin console). Address the node by
# its MagicDNS name `denton-worker-01` (from networking.hostName below), never the raw IP.
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
    ../../modules/denton-desktop.nix     # TEMPORARY desktop for bring-up — disable below when SSH is solid
  ];

  # ── Desktop DISABLED (2026-06-29) ── SSH-over-tailnet works + kimi runs on the API key, so the
  #    browser-for-OAuth reason is gone. Crucially this drops corectrl/qt/xfce/firefox — the big
  #    cache.nixos.org downloads that CORRUPT on the worker's flaky link and failed the rebuild
  #    (lzma "Corrupted input data" on corectrl). With it off, the only thing left to build is the
  #    no-AVX llama.cpp (from source, zero network). Re-enable later only if a local GUI is needed.
  denton.desktop.enable = false;
  denton.desktop.minimal = true;     # (moot while disabled) Openbox + Firefox only, no XFCE
  denton.desktop.coreCtrl = false;   # skip the GPU GUI for now (smaller download)

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
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXs83OLDeb3weEg85+A8Cit6a6AizfRQrsqMFaBsQv1 denton-hop"
  ];
  # Recommended: an EPHEMERAL Tailscale auth key in this file so the box self-joins
  # the tailnet on first boot, unattended. Generate at https://login.tailscale.com/admin/settings/keys
  # denton.access.tailscaleAuthKeyFile = "/var/lib/secrets/tailscale.key";

  # ── Inference role ──
  denton.inference = {
    enable = true;
    # ── THE ONE KNOB ── ex-HiveOS miner, ALL 8GB cards: Polaris (gfx803, 8GB) + RX 5700 XT
    # (RDNA1/gfx1010, 8GB). 4 currently seated (a 5th is pending recovery). 8GB/card means a
    # 7B Q4_K_M fits hot on EVERY card. Vulkan (auto) sees them — ROCm dropped gfx803. Fewer
    # seated → the no-refusal module clamps + warns (never breaks); check `vulkaninfo --summary`.
    # NOTE: at 150W/card the 750W PSU realistically powers ~4 cards; a returning 5th needs a
    # lower cap (5×115≈575W) or more PSU.
    gpuCount = 5;
    gpuVendor = "amd";   # this box is AMD; nodes set their own vendor (never hardcoded fleet-wide)
    # gfx803 is DROPPED by modern ROCm → Vulkan is the reliable path. auto = vulkan.
    gpuBackend = "auto";
    rocmGfxVersion = null; # only used if gpuBackend = "rocm"
    # ── CPU is an Intel Celeron G5920 (Comet Lake, AVX FUSED OFF — SSE4.2 only). The stock
    #    AVX2 llama-cpp binary SIGILLs at init (status=4/ILL, dies even on `--version`).
    #    "portable" rebuilds with no AVX so it runs. Compiles from source (slow on 2 cores). ──
    cpuBaseline = "portable";
    # ── PSU protection: 4 cards on a 750W PSU, keep total under ~600W. 150W/card = 600W GPU
    #    (~670W system, ~89% — see note in the module; drop to 135 if you see load reboots). ──
    powerCapWatts = 150;
    # Recommended starter model — drop a GGUF at `model`, or set modelUrl to auto-fetch.
    model = "/var/lib/llama/models/default.gguf";
    # modelUrl = "https://huggingface.co/<repo>/resolve/main/<model>.Q4_K_M.gguf";
    contextSize = 4096;
    parallel = 1;
  };

  system.stateVersion = "24.11";
}
