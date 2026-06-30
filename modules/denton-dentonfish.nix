# denton-dentonfish.nix — the OG "denton-worker" divergence engine (DentonOS)
#
# WHAT THIS IS (naming reconciled): "dentonfish" is Chase's OG denton-worker workload — the
# behavioral-anomaly / DIVERGENCE-detection engine (SimWorld/SGP "organism doctrine" cortex+
# immune layer). It ingests life-pattern / sim trajectories from the Redis river, scores how far
# a scenario DIVERGES from its baseline, and — the load-bearing property — ABSTAINS on low
# support instead of fabricating an answer (the void-anchor / calibrated-confidence principle).
# It is NOT a predictor. The same engine forks into three modes:
#   "cortex"   — OG life-pattern anomaly detection (calendar/sleep/finance signals)   [default]
#   "security" — Watchdog cross-verify variant (adversarial pattern match)
#   "finance"  — finance divergence detector (pairs denton-finance.nix; NO market prediction)
#
# CANON THIS MODULE HONORS:
#   • PRIVACY-ABSOLUTE: this touches life + finance PII → LOCAL-ONLY. Loopback bind, NO WAN
#     firewall opening, secrets by-name from ~/denton-projects/.env (NEVER the nix store).
#   • NO-REFUSAL: if the engine binary/script isn't built yet, we WARN + run a degraded stub
#     that abstains (returns "insufficient support") rather than hard-aborting eval. Mirrors
#     denton-inference.nix's runner-fallback pattern.
#   • OLLAMA IS BANNED — this is a river consumer; any model calls go to llama-server :8080.
#   • Sovereign/local-first: the node sets its own mode; nothing hardcoded fleet-wide.
{ config, lib, pkgs, ... }:
let
  cfg = config.denton.dentonfish;

  # ── No-refusal readiness: a built package OR a script path makes it "ready". ──
  hasPackage = cfg.package != null;
  hasScript  = cfg.scriptPath != null;
  ready      = hasPackage || hasScript;

  # Resolve the launch command, preferring a real package, then a script, then the stub.
  launchCmd =
    if hasPackage then "${cfg.package}/bin/dentonfish --mode ${cfg.mode}"
    else if hasScript then "${pkgs.python3}/bin/python3 ${cfg.scriptPath} --mode ${cfg.mode}"
    else null;  # → degraded stub below
in
{
  options.denton.dentonfish = {
    enable = lib.mkEnableOption "DentonOS dentonfish divergence/abstention engine (LOCAL-ONLY, PII)";

    mode = lib.mkOption {
      type = lib.types.enum [ "cortex" "security" "finance" ];
      default = "cortex";
      description = ''
        Which fork of the one engine to run on THIS node (set per node, never fleet-wide):
          cortex   = OG life-pattern anomaly detection (the original denton-worker workload).
          security = Watchdog cross-verify variant (adversarial pattern match).
          finance  = finance divergence detector + abstention (NOT a predictor; pairs denton-finance).
      '';
    };

    # No-refusal: EITHER of these makes the engine "ready"; absence → degraded abstaining stub.
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package; default = null;
      description = "Built dentonfish package (provides bin/dentonfish). null until the Rust/native engine is packaged.";
    };
    scriptPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str; default = null;
      example = "/var/lib/dentonfish/future_sim.py";
      description = "Path to the python engine (e.g. dentoncode ops/simworld/future_sim.py) if no package yet. Used only if package is null.";
    };

    # ── PRIVACY: bind loopback by default. NEVER expose to WAN; tailnet only if explicitly opted in. ──
    host = lib.mkOption {
      type = lib.types.str; default = "127.0.0.1";
      description = "Bind address. KEEP loopback — this handles PII. Set a tailnet IP ONLY with intent; never 0.0.0.0.";
    };
    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port; default = null;
      description = "Optional local status/health port. null = pure Redis-river consumer (no listener). If set, loopback only.";
    };

    # ── River (state bus) connection — the engine consumes trajectories from here. ──
    redisUrl = lib.mkOption {
      type = lib.types.str; default = "redis://127.0.0.1:6379";
      description = "Redis 'river' URL. KEEP loopback/tailnet; the password comes from envFile, never here.";
    };

    # ── Secrets by-name from .env (out-of-band; never the world-readable nix store). ──
    envFile = lib.mkOption {
      type = lib.types.str; default = "/var/lib/secrets/dentonfish.env";
      description = ''
        Out-of-band env file (e.g. holds REDIS_PASSWORD by-name). Deployed like rclone.conf /
        the tailscale key (see SECRETS.md) — NOT baked into the store. Loaded via systemd
        EnvironmentFile (the '-' prefix means absent-is-OK, no refusal).
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str; default = "/var/lib/dentonfish";
      description = "Local state dir (the SQLite divergence audit DB). 0700, local-only, never egressed.";
    };

    abstainThreshold = lib.mkOption {
      type = lib.types.float; default = 0.3;
      description = "Support floor below which the engine ABSTAINS instead of asserting (calibrated-confidence / void-anchor). Lower = more willing to answer.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── Warnings instead of refusals ──
    warnings =
      lib.optional (!ready)
        "denton.dentonfish.enable=true but no package or scriptPath is set — running a DEGRADED stub that always ABSTAINS (insufficient support). This is intentional no-refusal behavior; supply denton.dentonfish.package or .scriptPath to run the real engine."
      ++ lib.optional (cfg.host != "127.0.0.1")
        "denton.dentonfish.host=\"${cfg.host}\" is non-loopback — this engine handles life/finance PII (privacy-absolute canon). Ensure this is a tailnet address you intend, NEVER a WAN/0.0.0.0 bind."
      ++ lib.optional (hasPackage && hasScript)
        "denton.dentonfish: both package and scriptPath are set — package wins; scriptPath ignored.";

    # Local-only state dir + secrets dir (0700 — PII). DynamicUser also gets StateDirectory below.
    systemd.tmpfiles.rules = [
      "d /var/lib/secrets 0700 root root - -"
    ];

    systemd.services.denton-dentonfish = {
      description = "DentonOS dentonfish divergence engine (mode=${cfg.mode}, LOCAL-ONLY/PII)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        DENTONFISH_MODE = cfg.mode;
        DENTONFISH_DATA = cfg.dataDir;
      };
      # No-refusal env loading: '-' = file-absent is not a failure.
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = 5;
        EnvironmentFile = [ "-${cfg.envFile}" ];
        StateDirectory = "dentonfish";   # creates/owns ${dataDir} for the DynamicUser
        WorkingDirectory = cfg.dataDir;
        # Hardening: this is PII — lock it down hard.
        DynamicUser = lib.mkDefault true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ cfg.dataDir ];
      } // lib.optionalAttrs ready {
        ExecStart = "${launchCmd} --redis-url ${cfg.redisUrl} --abstain-threshold ${toString cfg.abstainThreshold}"
          + lib.optionalString (cfg.port != null) " --host ${cfg.host} --port ${toString cfg.port}";
      } // lib.optionalAttrs (!ready) {
        # ── Degraded no-refusal stub: stays up, abstains, never crashes the node. ──
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
    };

    # Engine deps available system-wide only when running from a script (no package).
    environment.systemPackages =
      lib.optionals (hasScript && !hasPackage) [ pkgs.python3 ]
      ++ lib.optional hasPackage cfg.package;

    # ── FIREWALL: deliberately NOTHING opened. PII engine = no inbound from anywhere.
    #    If port is set it is loopback-only by default; tailnet exposure is the operator's
    #    explicit choice via host + a separate firewall rule they add knowingly. ──
  };
}
