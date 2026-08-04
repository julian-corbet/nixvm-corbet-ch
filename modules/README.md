# Modules

- `vm-host/` — the hypervisor host: the daemon, an x86-only QEMU, optional tooling, the
  declared bridge guests attach to, remote-libvirtd aliases, optional file-backed storage
  pools. What makes a machine able to host guests at all. Three files, because it serves
  two evaluation planes:
  - `vm-host.nix` — the policy. Options and their resolution, platform-neutral. **Read
    this one's SCOPE block first.**
  - `nixos.nix` — the NixOS delivery (`nixosModules.vm-host`): `virtualisation.libvirtd`,
    the QEMU package, `environment.systemPackages`.
  - `arch.nix` — the system-manager delivery (`systemManagerModules.vm-host`): publishes
    pacman names for the host's own reconciler and installs nothing. Its header lists
    every NixOS-only option it deliberately does not touch, and `checks/default.nix`'s
    `arch-plane/*` group proves the list is accurate.
- `guests/` — guest VM definitions, as data: per-guest disks/network/firmware/tpm/
  graphics/autostart, rendered to libvirt domain XML and kept declared. What runs on
  the host. **NixOS only** — see `vm-host/arch.nix`'s header for why that is a boundary
  rather than an omission. Always composed alongside `vm-host` — see that module's own
  "ALWAYS COMPOSED WITH" note. The RAM/CPU envelope is read from
  `nixhost.environments.<name>` by name, never declared here — see `guests/README.md`'s
  "The resource envelope".
