# Modules

- `vm-host/` — the hypervisor host: libvirtd, the declared bridge guests attach to,
  optional file-backed storage pools. What makes a machine able to host guests at all.
- `guests/` — guest VM definitions, as data: per-guest cpu/memory/disks/network/
  firmware/tpm/graphics/autostart, rendered to libvirt domain XML and kept declared.
  What runs on the host. Always composed alongside `vm-host` — see that module's own
  "ALWAYS COMPOSED WITH" note.
