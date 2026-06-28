# denton-hardening.nix — baseline hardening for a headless, internet-exposed-only-
# via-Tailscale inference node. Tuned to NOT fight the GPU/inference role:
#   • no security.lockKernelModules (amdgpu must load late)
#   • no MAC/AppArmor lockdown that blocks Ollama's dlopen of ROCm libs
# It hardens the network edge, SSH, and kernel info-leaks — the things that matter
# for a box whose only jobs are "join Tailscale" and "serve :11434".
{ config, pkgs, lib, ... }:
{
  # ── SSH edge (reinforces denton-base; safe to co-exist via mkDefault there) ──
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "no";
    X11Forwarding = false;
    MaxAuthTries = 3;
    AllowTcpForwarding = "yes"; # keep: useful for tunneling to :11434 if ever needed
    LoginGraceTime = "30s";
  };

  # ── fail2ban on sshd (cheap insurance even behind Tailscale, for LAN exposure) ──
  services.fail2ban = {
    enable = true;
    maxretry = 4;
    bantime = "1h";
    # never ban loopback, Tailscale CGNAT, or any RFC1918 LAN (generic — no per-box subnet hardcode)
    ignoreIP = [ "127.0.0.1/8" "::1" "100.64.0.0/10" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
  };

  # ── Kernel / network sysctl hardening (does not touch Ollama's 0.0.0.0:11434) ──
  boot.kernel.sysctl = {
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 2;
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv6.conf.all.accept_redirects" = 0;
  };

  # ── Firewall posture: deny inbound by default, Tailscale is the trusted door ──
  networking.firewall = {
    enable = true;
    allowPing = true;
    logRefusedConnections = false;
    trustedInterfaces = [ "tailscale0" ];
  };

  # ── zram swap: an inference box with big models benefits more from compressed
  #    RAM swap than slow SSD swap (worker-01 is RAM-limited at ~15G today) ──
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  # ── Trim attack surface: no docs, no X, restrict who may talk to the nix daemon ──
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;
  services.xserver.enable = lib.mkDefault false;
  nix.settings.allowed-users = [ "root" "nvsble" "denton" ];

  # ── Auto GC stays on (base); auto-upgrade is OPT-IN — an inference node should
  #    not silently rebuild mid-job. Flip on per-deployment when desired. ──
  system.autoUpgrade = {
    enable = lib.mkDefault false;
    allowReboot = false;
  };
}
