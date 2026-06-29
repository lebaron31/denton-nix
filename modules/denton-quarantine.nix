# denton-quarantine.nix — network-isolation profile for the most sensitive modules.
#
# CANON (dexta CLAUDE.md §4/§6, DENTON_VICE_SPEC, DENTON_NSFW_SPEC):
#   • Lilith = NETWORK-LESS (canon). Hades + denton-nsfw = HOST-DISCONNECTED QUARANTINE VM
#     (internet only there). denton-vice = the most sensitive data in the whole system.
#   • PRIVACY-ABSOLUTE: local-only, encrypted, NO egress, NO telemetry, NO surveillance, the
#     user's sole control. Never leaves the box.
#   • NO-REFUSAL: this module HARDENS + WARNS. It does NOT itself launch vice/nsfw content
#     services (CC never generates that content; agents/Lilith do, inside these bounds). It
#     provides the network-isolated SANDBOX they must run inside, and warns loudly that nixos
#     systemd-confinement is NOT a full VM — true host-disconnect needs a real VM boundary.
#
# This is a PROFILE: it sets a default-deny posture + a confined slice for the named units.
{ config, lib, pkgs, ... }:
let
  cfg = config.denton.quarantine;
in
{
  options.denton.quarantine = {
    enable = lib.mkEnableOption "DentonOS quarantine profile (network-less sandbox for vice/nsfw/Lilith — privacy-absolute)";

    confinedUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "denton-nsfw.service" "denton-vice.service" ];
      description = "systemd unit names to force into the network-less, egress-denied sandbox. Each gets PrivateNetwork + strict confinement. These units must be defined elsewhere; this only augments them.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str; default = "/var/lib/denton-quarantine";
      description = "Encrypted local store for quarantined module data. 0700. NEVER egressed (excluded from any cloud sync).";
    };

    acknowledgeNotAVm = lib.mkOption {
      type = lib.types.bool; default = false;
      description = "Set true to acknowledge that systemd confinement is NOT a true host-disconnected VM. Until then, a warning fires (no refusal). Real Hades/nsfw internet-isolation wants a dedicated VM boundary.";
    };
  };

  config = lib.mkIf cfg.enable {
    warnings =
      lib.optional (!cfg.acknowledgeNotAVm)
        "denton.quarantine: systemd PrivateNetwork confinement is STRONG isolation but NOT a full VM. Canon wants Hades+denton-nsfw on a host-disconnected QUARANTINE VM and Lilith network-less. Treat this profile as the in-host floor; provision a real VM for true host-disconnect, then set acknowledgeNotAVm=true to silence this."
      ++ lib.optional (cfg.confinedUnits == [ ])
        "denton.quarantine.enable=true but confinedUnits is empty — the profile is armed but isolating nothing yet. Add the vice/nsfw unit names.";

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 root root - -"
    ];

    # Force every named unit into a network-LESS, egress-denied, hardened sandbox.
    # PrivateNetwork=true gives the unit only a loopback in its own netns → NO host network,
    # NO internet, NO telemetry possible (the canon "network-less / host-disconnected" floor).
    systemd.services = lib.genAttrs cfg.confinedUnits (_: {
      serviceConfig = {
        PrivateNetwork = true;          # network-less: own netns, loopback-only, no egress
        IPAddressDeny = "any";          # belt-and-suspenders: deny all IP even if netns leaked
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.dataDir ];
        RestrictAddressFamilies = [ "AF_UNIX" ];  # no AF_INET/AF_INET6 at all
        SystemCallFilter = [ "@system-service" "~@network-io" ];
      };
    });

    # NOTE: cfg.dataDir must be kept OUT of any rclone/cloud-sync job (denton-cloud points
    # RCLONE_CONFIG at an out-of-band file) — this comment is the intent marker; the operator
    # must not add this path to a sync remote.
  };
}
