# The smallest NixOS configuration that lets `nixvm.host` be evaluated as part of a real
# system, used by the `host-module-evaluates` check. `nixvm.guests` is untouched here --
# a host that only wants the hypervisor capability, with no guest defined yet, imports
# modules/vm-host alone.
{ ... }:
{
  nixvm.host = {
    enable = true;
    bridge = "examplebr0";
  };

  # ── Stubs NixOS demands of any bootable system ───────────────────────────
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
