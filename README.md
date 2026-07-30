# nixvm

**A declarative home for persistent, hosted VM workloads on NixOS: libvirt/QEMU-KVM as
a host stance, guest VMs as data.**

Most deployments end up with bare metal and a container orchestrator, and nothing in between.
`nixvm` is that third substrate: a machine that hosts real, persistent virtual machines with
their own identity and storage — not ephemeral, not test infrastructure, not another
container runtime.

## The pitch

Running libvirt/QEMU-KVM by hand is easy and exactly what gets forgotten about a year
later: which bridge a guest was on, whether its disk was a zvol or a file, whether
autostart was ever set. `nixvm` packages the two questions that matter as one small
pair of NixOS modules:

- **Can this host run guests at all?** (`modules/vm-host`) — libvirtd, the bridge guest
  network devices attach to, optional file-backed storage pools. Every fact this module
  reads (a bridge, a directory) already exists; it never partitions, formats, or
  creates anything.
- **What guests does it run?** (`modules/guests`) — per-guest disks/network/firmware/
  tpm/graphics/autostart as typed options, rendered to a real libvirt domain XML
  document and kept declared (`virsh define`, `virsh autostart`) on every activation.
  The RAM/CPU resource envelope is deliberately not one of this module's own options —
  it's read from `nixhost.environments.<name>.resources`, matched by name, so the one
  place that sums every environment's claim against what a host actually has stays the
  only place that does. See `modules/guests/README.md`'s "The resource envelope"
  section.

Neither module starts, stops, or reboots a guest. Declaring a guest's definition is
this repo's job; deciding when it actually runs is the operator's.

## Decisions this repo has already made

- **libvirt + QEMU/KVM**, not `microvm.nix` and not `cloud-hypervisor`. The driving
  workload is a Windows guest: a Windows kernel needs a real VM, and both of those
  alternatives target minimal Linux guests — neither is a Windows host.
- **No GPU passthrough.** The host's discrete GPU is shared platform hardware other
  workloads depend on; a VM cannot hold a device exclusively and still share it. The
  guest this repo was built for is reached over RDP, which needs no GPU inside the
  guest at all. This is not deferred scope — see `modules/vm-host`'s own SCOPE block
  for why it would need re-litigating, not just an option added, to change.
- **zvol-backed guest disks are the PRIMARY storage mode** — a zvol handed to a guest
  directly as a raw block device, no libvirt storage pool involved. File-backed qcow2
  disks (`nixvm.host.storagePools`) are the secondary mode.
- **Bridged networking onto an existing host bridge**, never a NAT layer. `nixvm.host`
  declares which bridge; it never creates one.
- **A known gotcha, encoded, not just remembered**: a zvol used under a foreign
  filesystem (e.g. a file-backed storage pool's directory) needs the `nossd` mount
  option, or btrfs applies SSD heuristics on top of a device already doing its own
  copy-on-write allocation. `nixvm.host.storagePools.<name>.zvolBacked` turns this into
  an eval-time assertion instead of a rediscovered incident — see
  [docs/gotchas.md](docs/gotchas.md).

## Boundaries — three places this repo could quietly absorb scope, and doesn't

**vs. `nixtest` — nixvm does not run tests, and never will.** This repo hosts
persistent VMs with identity and storage; it owns the QEMU lifecycle for exactly those
guests. Ephemeral test VMs are a different domain entirely, owned by nixpkgs itself via
`pkgs.testers.nixosTest` — a standing decision recorded before this repo existed. The
two must never share a hypervisor layer: the day `nixvm` offers to "also run the
tests" is the day both domains rot, because `nixtest` would inherit standing
infrastructure it was designed not to need, and `nixvm` would inherit a scheduling
concern that belongs to this project's build/deploy platform, not to a VM-hosting module.
If you are looking for ephemeral CI test VMs, this is not that repo, on purpose.

**vs. `nixoffice` — nixoffice is what the guest runs; nixvm is how it's hosted.**
`nixoffice` describes the documents half of a workstation — office suites, editors,
viewers — as data a host's own package reconciler consumes. It has no idea whether it
is running on bare metal or inside a VM, and `nixvm` has no idea what software runs
inside any guest it hosts. A Windows guest defined here might run an office suite
configured by `nixoffice`-equivalent tooling *inside itself*; that is entirely outside
this repo's field of view. Neither repo imports the other.

**vs. `nixk3s` — sibling substrates, not a hierarchy.** `nixk3s` splits "the host
platform" (`k3s-host`) from "what runs on it" (`tenancy`); `nixvm` mirrors that shape
exactly (`vm-host` / `guests`) for a different substrate. They compose on the same
host without either one depending on the other — a host can run k3s, host VMs, both,
or neither.

## What ships

- **`vm-host`** (`nixosModules.vm-host`) — the hypervisor stance: libvirtd, the
  declared guest-network bridge, optional file-backed storage pools.
- **`guests`** (`nixosModules.guests`) — guest VM definitions as data, rendered to
  libvirt domain XML and kept declared. Always composed alongside `vm-host` — see its
  own README for why that composition is required, not just conventional.
- **`nixosModules.default`** — both together, for the common case.
- **`lib.mkDomainXML`** — the pure XML-rendering function `guests` is built on,
  exposed for inspection or reuse without a NixOS evaluation (mirrors `nixfs` exposing
  its own catalogue).
- **[docs/gotchas.md](docs/gotchas.md)** — the zvol/`nossd` incident and the
  Windows/`localtime` clock offset, written down so neither gets rediscovered.

## Status

**First cut, freshly built — a clean slate, not a migration.** No libvirt state
survives from any earlier era; this repo starts from an idle KVM stack with nothing
defined on top of it. `nix flake check` proves both modules compose into a real NixOS
system and render correct libvirt domain XML from typed guest data — and, just as
deliberately, that a host missing its required bridge, a guest missing its memory
allocation or its disks, and the zvol/`nossd` gotcha with `nossd` actually missing, all
fail evaluation by name rather than producing something half-formed. Nothing here has
yet hosted a guest on real hardware; that is the next step, not this one.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
