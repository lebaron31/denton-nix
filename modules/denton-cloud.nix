# denton-cloud.nix — declarative Hetzner object-storage (rclone) for EVERY node.
#
# Chase directive: Hetzner must be added to all nix configs + installed on worker, brainstem,
# and any future node — the cross-node shared-storage substrate (pairs with Tailscale, which
# denton-base already provides for cross-node networking).
#
# Installs rclone and points RCLONE_CONFIG at an OUT-OF-BAND secret config file, so the
# `denton-obj:` remote (and the gdrive remotes) work system-wide WITHOUT baking the Hetzner
# access key / OAuth tokens into the world-readable nix store. The config file is deployed
# the same way the Tailscale auth key is (see SECRETS.md) — e.g. one-time scp from brainstem,
# or sops/agenix later.
#
# Imported by denton-base.nix → automatic on every node that uses the baseline.
{ config, lib, pkgs, ... }:
let
  cfg = config.denton.cloud;
in
{
  options.denton.cloud = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install rclone + wire the denton-obj Hetzner remote on this node.";
    };
    rcloneConfigFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/secrets/rclone.conf";
      description = ''
        Path to the rclone config (holds denton-obj + the gdrive remotes). Deployed OUT-OF-BAND
        so secrets stay out of the nix store. RCLONE_CONFIG points here for all rclone use.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.rclone ];

    # Every rclone invocation (interactive shells + scripts like cloud_rebase.sh) finds the
    # deployed config via this env var — no per-user ~/.config/rclone copying needed.
    environment.variables.RCLONE_CONFIG = cfg.rcloneConfigFile;

    # Hold the deployed secret config (the file itself is placed out-of-band).
    systemd.tmpfiles.rules = [ "d /var/lib/secrets 0700 root root - -" ];
  };
}
