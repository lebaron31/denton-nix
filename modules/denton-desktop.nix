# denton-desktop.nix — TEMPORARY / OPTIONAL desktop layer (DentonOS)
#
# A headless inference node should NOT run a desktop in steady state — it's bloat + attack
# surface, and denton-hardening disables X by default. This module exists for the BRING-UP
# phase only: a lightweight XFCE + browser so you can do Claude login / OAuth and
# clipboard-paste keys at the console instead of hand-typing them, run Claude Code on the
# box, and (bonus) undervolt the GPUs in CoreCtrl.
#
# TURN IT OFF when remote SSH is solid — it's one line + a rebuild:
#     denton.desktop.enable = false;   # then: sudo nixos-rebuild switch --flake .#worker-01
{ config, pkgs, lib, ... }:
let
  cfg = config.denton.desktop;
in
{
  options.denton.desktop = {
    enable = lib.mkEnableOption "TEMPORARY XFCE desktop + browser for bring-up (disable once SSH is solid)";

    minimal = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Barebones mode: Openbox WM + Firefox only (NO XFCE) — ~200MB less to download, which
        matters on a flaky link. Right-click the desktop for the menu; launch Firefox for OAuth.
        false = full XFCE.
      '';
    };

    autoLoginUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "nvsble";
      description = "User to auto-login at the console (no password typing). null = normal login screen.";
    };

    claudeCode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install Node.js so you can run Claude Code on the box. NixOS can't `npm i -g` into the
        read-only store, so install into a writable home prefix (one time, as the login user):
          mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global
          echo 'export PATH=$HOME/.npm-global/bin:$PATH' >> ~/.zshrc && export PATH=$HOME/.npm-global/bin:$PATH
          npm install -g @anthropic-ai/claude-code   # then: claude
      '';
    };

    coreCtrl = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install CoreCtrl for GUI undervolt/fan curves (pairs with denton.inference.powerCapWatts).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Lightweight desktop. `enable = true` (not mkDefault) overrides hardening's mkDefault-false X.
    services.xserver = {
      enable = true;
      desktopManager.xfce.enable = !cfg.minimal;   # full DE only when not barebones
      windowManager.openbox.enable = cfg.minimal;  # barebones: tiny WM, right-click menu
      displayManager.lightdm.enable = true;
    };
    services.displayManager = {
      defaultSession = if cfg.minimal then "none+openbox" else "xfce";
      autoLogin = lib.mkIf (cfg.autoLoginUser != null) {
        enable = true;
        user = cfg.autoLoginUser;
      };
    };

    # The whole point: a browser for Claude OAuth + clipboard paste (no more hand-typed keys).
    environment.systemPackages = with pkgs; [
      firefox
      xclip                       # terminal <-> browser clipboard (X session)
    ] ++ lib.optionals cfg.claudeCode [ nodejs_22 ]
      ++ lib.optionals cfg.coreCtrl [ corectrl ];

    hardware.graphics.enable = true;
  };
}
