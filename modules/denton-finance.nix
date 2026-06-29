# denton-finance.nix — LOCAL-ONLY finance ledger + (optional) denton-fish finance mode.
#
# CANON (load-bearing, from DENTON_FINANCE_ENGINE_SPEC.md + dexta CLAUDE.md):
#   • CC/Denton NEVER moves money, never trades, never advises. This module runs the LEDGER
#     (records income as fact; STAGES outflows — there is no 'executed' state) and, optionally,
#     points the dentonfish engine at finance mode. The ONLY automatable flow is a pre-authorized,
#     one-way, earnings-only CONSOLIDATION — and even that is STAGED here, not executed.
#   • PRIVACY-ABSOLUTE: finance DATA is local-only, encrypted, NO egress, NO telemetry. Loopback
#     bind only, NO WAN firewall opening, secrets by-name from .env (never the store).
#   • NO MAGIC: denton-fish = divergence detector + abstention, not a predictor.
#   • NO-REFUSAL: missing ledger code → WARN + degrade (a no-op timer), never abort eval.
{ config, lib, pkgs, ... }:
let
  cfg = config.denton.finance;
  hasLedger = cfg.ledgerScript != null;
in
{
  options.denton.finance = {
    enable = lib.mkEnableOption "DentonOS finance ledger (LOCAL-ONLY; records income, STAGES outflows, NEVER executes)";

    ledgerScript = lib.mkOption {
      type = lib.types.nullOr lib.types.str; default = null;
      example = "/var/lib/denton-finance/ledger.py";
      description = "Path to the append-only ledger script (ops/hermes/finance/ledger.py or denton_finance/ledger.py). null → degraded no-op + warning.";
    };

    # Local-only data — the source of truth. 0700, encrypted-at-rest is the operator's disk choice.
    dataDir = lib.mkOption {
      type = lib.types.str; default = "/var/lib/denton-finance";
      description = "Local ledger SQLite/JSONL dir. 0700. NEVER egressed (no rclone/cloud sync of this path).";
    };

    envFile = lib.mkOption {
      type = lib.types.str; default = "/var/lib/secrets/denton-finance.env";
      description = "Out-of-band secrets (connector keys BY NAME). Never in the nix store. Absent-is-OK (no refusal).";
    };

    # Optional analytics/digest timer (read-only; produces the Pareto view locally).
    digestInterval = lib.mkOption {
      type = lib.types.str; default = "daily";
      description = "systemd OnCalendar for the local analytics digest (read-only; no money movement).";
    };

    # Wire the dentonfish finance fork (divergence detector) if desired — pure analysis, abstains.
    enableFishMode = lib.mkOption {
      type = lib.types.bool; default = false;
      description = "If true, also enable denton.dentonfish in finance mode (divergence detector + abstention; NOT a predictor).";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      warnings =
        lib.optional (!hasLedger)
          "denton.finance.enable=true but ledgerScript is null — running a DEGRADED no-op digest (no ledger present). No refusal; set denton.finance.ledgerScript to the built ledger.py."
        # Loud, permanent reminder of the money guardrail at the infra layer.
        ++ [ "denton.finance: this module RECORDS income + STAGES outflows ONLY. It cannot and must not execute transfers/trades. One-way earnings-consolidation is staged, never auto-run here." ];

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0700 root root - -"
        "d /var/lib/secrets 0700 root root - -"
      ];

      # Read-only local analytics digest — surfaces the Pareto view, moves no money.
      systemd.services.denton-finance-digest = {
        description = "DentonOS finance ledger digest (read-only, LOCAL-ONLY, no money movement)";
        after = [ "network.target" ];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = [ "-${cfg.envFile}" ];
          WorkingDirectory = cfg.dataDir;
          DynamicUser = lib.mkDefault true;
          StateDirectory = "denton-finance";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateNetwork = true;   # digest is purely local — deny ALL network (privacy-absolute).
          ReadWritePaths = [ cfg.dataDir ];
          ExecStart =
            if hasLedger
            then "${pkgs.python3}/bin/python3 ${cfg.ledgerScript} digest"
            else "${pkgs.coreutils}/bin/true";  # degraded no-op (no-refusal)
        };
      };
      systemd.timers.denton-finance-digest = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = cfg.digestInterval; Persistent = true; };
      };

      environment.systemPackages = lib.optional hasLedger pkgs.python3;

      # ── FIREWALL: nothing opened. Finance data never accepts inbound; the digest has
      #    PrivateNetwork=true so it cannot egress even if a connector key were present. ──
    }

    # Optional: turn on the dentonfish finance fork alongside the ledger.
    (lib.mkIf cfg.enableFishMode {
      denton.dentonfish.enable = true;
      denton.dentonfish.mode = "finance";
      # host stays loopback (module default) — PII canon.
    })
  ]);
}
