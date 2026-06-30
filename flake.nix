{
  description = "denton-nix — DentonOS plug-and-play inference-server NixOS configs (worker-01 first; brainstem deferred)";

  inputs = {
    # COMMIT-PINNED tarball URLs — NOT github: (uses api.github.com, blocked/flaky on some nodes
    # and triggers the `-33 object hash mismatch` git-fetcher corruption seen on these rigs) and
    # NOT branch tarballs (…/nixos-24.11.tar.gz is byte-UNSTABLE → nix hash mismatch). A commit-SHA
    # archive is content-stable → deterministic narHash, plain-HTTPS codeload, zero GitHub API /
    # token. These SHAs are nixos-24.11 (built clean on the worker). Bump to update.
    nixpkgs.url = "https://github.com/NixOS/nixpkgs/archive/50ab793786d9de88ee30ec4e4c24fb4236fc2674.tar.gz";
    disko = {
      url = "https://github.com/nix-community/disko/archive/ff8702b4de27f72b4c78573dfb89ec74e36abdf1.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }:
    let
      system = "x86_64-linux";
    in
    {
      # ── Reusable modules (import into the deferred dentoncode/nix brainstem flake too) ──
      nixosModules = {
        base = ./modules/denton-base.nix;
        inference = ./modules/denton-inference.nix;
        hardening = ./modules/denton-hardening.nix;
        disko = ./modules/denton-disko.nix;
        desktop = ./modules/denton-desktop.nix;   # TEMPORARY bring-up desktop (opt-in toggle)
        # ── DentonOS "era ideas" — all opt-in (default OFF), warn+degrade, local-only/PII ──
        dentonfish = ./modules/denton-dentonfish.nix;  # OG worker divergence engine (cortex/security/finance)
        finance = ./modules/denton-finance.nix;        # local-only ledger (records/stages, never executes)
        quarantine = ./modules/denton-quarantine.nix;  # network-less sandbox for vice/nsfw/Lilith
      };

      nixosConfigurations = {
        # worker-01 — THE plug-and-play inference test. disko owns the disk.
        # Install: boot stock NixOS ISO, then on the box:
        #   disko --mode destroy,format,mount ./modules/denton-disko.nix   # ERASES the disk
        #   nixos-install --flake .#worker-01
        worker-01 = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            disko.nixosModules.disko
            ./hosts/worker-01/configuration.nix
          ];
        };

        # brainstem-inference — DEFERRED. Standalone so the "new card" overlay still
        # CI-evals; in production it's imported into dentoncode/nix's brainstem host.
        brainstem-inference = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/denton-base.nix
            ./hosts/brainstem-inference.nix
            {
              networking.hostName = "brainstem";
              system.stateVersion = "24.11";
              boot.loader.systemd-boot.enable = true;
              boot.loader.efi.canTouchEfiVariables = true;
              nixpkgs.hostPlatform = system;
              # eval-only stub root FS (real brainstem uses its dentoncode hardware config)
              fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
            }
          ];
        };
      };
    };
}
