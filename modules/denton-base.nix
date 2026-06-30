# denton-base.nix — headless host baseline (DentonOS)
#
# Everything a non-desktop cluster node needs and nothing it doesn't:
# flakes, Tailscale, hardened SSH, the denton/nvsble admins, core CLI.
# Desktop hosts (brainstem) layer their own desktop.nix ON TOP of this.
{ config, pkgs, lib, ... }:
let
  acc = config.denton.access;
in
{
  imports = [ ./denton-cloud.nix ]; # rclone + denton-obj Hetzner remote on every node

  options.denton.access = {
    sshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Authorized SSH public keys for the admin users (the recommended-but-BYO 'suggested keys').";
    };
    tailscaleAuthKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to a file holding an ephemeral Tailscale auth key, for unattended first-boot tailnet join.";
    };
  };

  options.denton.node.tier = lib.mkOption {
    type = lib.types.enum [ "micro" "worker" "server" "brainstem" ];
    default = "worker";
    description = "Informational node tier (recommended by scripts/detect-tier.sh; may drive defaults later). See DENTON_RUNNER.md.";
  };

  config = {
    # ── Nix / flakes ──
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "nvsble" "denton" ];
      # Flaky-link resilience: bigger download buffer + patient timeouts so large substitutes /
      # tarballs don't truncate-corrupt mid-stream on a poor connection (the worker's reality).
      download-buffer-size = 536870912;   # 512 MiB (default 64 MiB warns "increase download-buffer-size")
      connect-timeout = 10;
      stalled-download-timeout = 90;
    };
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    nixpkgs.config.allowUnfree = true;

    # ── Locale / time (match the fleet: Phoenix, per digital-nvsble) ──
    time.timeZone = lib.mkDefault "America/Phoenix";
    i18n.defaultLocale = "en_US.UTF-8";

    # ── Admins (mirror dentoncode/nix host UIDs so file ownership stays stable) ──
    users.users.nvsble = {
      isNormalUser = true;
      uid = 1001;
      description = "Brainstem administrator";
      extraGroups = [ "wheel" "networkmanager" "video" "render" "audio" "input" ];
      shell = pkgs.zsh;
      openssh.authorizedKeys.keys = acc.sshKeys;
    };
    users.users.denton = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [ "wheel" "networkmanager" "video" "render" ];
      shell = pkgs.zsh;
      openssh.authorizedKeys.keys = acc.sshKeys;
    };
    security.sudo.wheelNeedsPassword = lib.mkDefault true;

    programs.zsh.enable = true;

    # ── Networking + remote access ──
    networking.networkmanager.enable = true;
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "client";
      authKeyFile = acc.tailscaleAuthKeyFile;
    };

    # SSH: key-only, and (unlike the current Ubuntu box) actually reachable so
    # brainstem can drive deploys instead of relying on a human at the console.
    services.openssh = {
      enable = true;
      openFirewall = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    networking.firewall.enable = lib.mkDefault true;

    # ── Core CLI (headless-appropriate) ──
    environment.systemPackages = with pkgs; [
      git curl wget tmux htop btop neovim
      ripgrep fd bat eza fzf
      pciutils usbutils nvme-cli lm_sensors
      rsync rclone
    ];
  };
}
