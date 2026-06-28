# brainstem-inference.nix — "the new card" overlay for brainstem.
#
# brainstem already has a desktop NixOS config in dentoncode/nix (#digital-nvsble) with
# denton-amd.nix for its RX 5700 XT display GPU. This overlay adds the INFERENCE role
# on top, so when the new card lands brainstem can serve models too.
#
# USAGE (preferred — additive, no duplication):
#   In dentoncode/nix/flake.nix brainstem modules list, add:
#     denton-nix.nixosModules.inference
#     ({ ... }: { denton.inference = { enable = true; gpuCount = 1; rocmGfxVersion = "..."; }; })
#
# This file is the same thing as a ready-to-import snippet (and lets flake.nix build a
# standalone `brainstem-inference` toplevel for CI eval).
{ config, pkgs, lib, ... }:
{
  imports = [ ../modules/denton-inference.nix ];

  denton.inference = {
    enable = true;
    # brainstem's new card. The RX 5700 XT stays the display GPU (denton-amd.nix);
    # this counts the compute card(s). Set rocmGfxVersion to the new card's family.
    gpuCount = 1;
    rocmGfxVersion = null; # e.g. "10.3.0" (RDNA2) / "11.0.0" (RDNA3) once known
    # brainstem is a desktop host → it DOES want 32-bit graphics; re-enable here.
  };

  hardware.graphics.enable32Bit = lib.mkForce true;
}
