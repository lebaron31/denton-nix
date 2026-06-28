# denton-disko.nix — declarative disk layout for the plug-and-play install.
#
# Replaces manual parted/mkfs in INSTALL.md: `disko` wipes + partitions + formats +
# mounts from this declaration, so imaging the worker is reproducible and turnkey.
# GPT + UEFI ESP + ext4 root. Swap is zram (denton-hardening), not a disk partition.
#
# ⚠️ Set denton.disk.device to the REAL device from the worker probe (likely
#    /dev/nvme0n1). disko WILL DESTROY everything on that device on install.
{ config, lib, ... }:
let
  cfg = config.denton.disk;
in
{
  options.denton.disk.device = lib.mkOption {
    type = lib.types.str;
    default = "/dev/sda";
    description = "Whole-disk device disko partitions (worker-01 = /dev/sda, 931.5G, confirmed). disko ERASES it.";
  };

  config = {
    disko.devices.disk.main = {
      type = "disk";
      device = cfg.device;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
