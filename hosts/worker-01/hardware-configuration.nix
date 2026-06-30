# ⚠️ PLACEHOLDER — regenerate on the worker before any real install.
#
# disko (denton-disko.nix) now owns fileSystems + swap, so this file carries ONLY the
# hardware scan bits disko can't know: kernel modules, platform, microcode. On the box:
#
#     sudo nixos-generate-config --no-filesystems --show-hardware-config \
#         > hardware-configuration.nix
#
# (--no-filesystems is important: it omits fileSystems so it won't fight disko.)
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # Real values come from nixos-generate-config. Defaults matched to THIS box: Intel Celeron
  # G5920 + SATA SSD (OS) + USB HDDs (Insignia bay) — NOT AMD, NOT NVMe. Regenerate to be exact.
  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "usbhid" "usb_storage" "uas" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];   # Intel CPU — was wrongly "kvm-amd"
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.enableRedistributableFirmware = true;
}
