# The smallest configuration that composes BOTH modules together with one real guest
# defined, used by the `guests-module-evaluates` check and by the render-content checks
# that inspect the generated domain XML. Every value is generic; nothing here names a
# real host, bridge, pool, or device.
#
# The resource envelope (RAM, vCPU count) is read from `nixhost.environments.<name>`,
# matched by name -- modules/guests declares no ceiling option of its own. See
# modules/guests/README.md's own "The resource envelope" section for why.
{ ... }:
{
  nixvm.host = {
    enable = true;
    bridge = "examplebr0";
  };

  nixhost.environments.example-guest = {
    kind = "vm";
    resources.ram.limitMiB = 8192;
    resources.cpu.quotaCores = 4;
  };

  nixvm.guests.example-guest = {
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
