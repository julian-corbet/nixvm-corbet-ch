# The smallest configuration that composes BOTH modules together with one real guest
# defined, used by the `guests-module-evaluates` check and by the render-content checks
# that inspect the generated domain XML. Every value is generic; nothing here names a
# real host, bridge, pool, or device.
{ ... }:
{
  nixvm.host = {
    enable = true;
    bridge = "examplebr0";
  };

  nixvm.guests.example-guest = {
    memoryMiB = 8192;
    cpu.cores = 4;
    disks.vda.source = "/dev/zvol/pool/example-guest";
  };

  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-vm-host";
  system.stateVersion = "25.05";
}
