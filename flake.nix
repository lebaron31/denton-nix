{
  description = "denton-nix — DentonOS plug-and-play inference-server NixOS configs (worker-01 first; brainstem deferred)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    disko = {
      url = "github:nix-community/disko";
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
