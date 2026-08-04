# nixvm

**A declarative home for VM workloads: libvirt/QEMU-KVM as a host stance — on NixOS and on
distro hosts via system-manager — and persistent guest VMs as data.**

Most deployments end up with bare metal and a container orchestrator, and nothing in between.
`nixvm` is that third substrate: a machine that hosts real virtual machines — the persistent
kind with their own identity and storage, and the ad-hoc kind you spin up on a laptop because
you need one for an afternoon.

## The pitch

Running libvirt/QEMU-KVM by hand is easy and exactly what gets forgotten about a year
later: which bridge a guest was on, whether its disk was a zvol or a file, whether
autostart was ever set, and — the one that costs real disk — which of QEMU's thirty
target architectures the box ended up carrying. `nixvm` packages the two questions that
matter as one small pair of modules:

- **Can this host run guests at all?** (`modules/vm-host`) — the daemon, a QEMU built for
  the architectures the host actually asked for, optional tooling, the bridge guest network
  devices attach to, aliases for remote libvirtd instances, optional file-backed storage
  pools. Every fact this module reads (a bridge, a directory) already exists; it never
  partitions, formats, or creates anything.
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

## Two planes, one policy

`vm-host` serves NixOS **and** any distro host managed by
[system-manager](https://github.com/numtide/system-manager). Those are two separate
`evalModules` runs with no option in common: NixOS has `virtualisation.libvirtd`;
system-manager has no `virtualisation` namespace at all, no `boot`, and no `fileSystems`.
So the policy is written once (`modules/vm-host/vm-host.nix`) and delivered twice — as
`virtualisation.libvirtd` on NixOS, and as a published pacman/AUR package list on a distro
host, where nixvm installs nothing and the host's own reconciler does the work.

The claim "the distro backend sets nothing NixOS-only" is enforced rather than asserted:
`nix flake check` evaluates it against a stand-in for system-manager's option surface, so
reaching for an option that plane does not have fails the check. The same group proves the
stand-in is strict, so none of it can pass vacuously.

`modules/guests` is NixOS-only, and that is a boundary rather than an omission — it renders
`virsh define` units against `virtualisation.libvirtd.package` and reads a resource envelope
from `nixhost`. A distro host runs guests it made by hand.

## Decisions this repo has already made

- **libvirt + QEMU/KVM**, not `microvm.nix` and not `cloud-hypervisor`. The driving
  workload is a Windows guest: a Windows kernel needs a real VM, and both of those
  alternatives target minimal Linux guests — neither is a Windows host.
- **The host's own architecture, and nothing else, unless asked.** `qemu-full` on Arch and
  the top-level `qemu` in nixpkgs both build every target QEMU has — roughly 600 MiB of
  emulators and firmware for architectures nobody on the box owns hardware for. The default
  here is the x86-only path on both planes; foreign architectures are named one at a time in
  `nixvm.host.foreignArchitectures`.
- **No GPU passthrough.** The host's discrete GPU is shared platform hardware other
  workloads depend on; a VM cannot hold a device exclusively and still share it. The
  guest this repo was built for is reached over RDP, which needs no GPU inside the
  guest at all. This is not deferred scope — see `modules/vm-host`'s own SCOPE block
  for why it would need re-litigating, not just an option added, to change.
- **zvol-backed guest disks are the PRIMARY storage mode** — a zvol handed to a guest
  directly as a raw block device, no libvirt storage pool involved. File-backed qcow2
  disks (`nixvm.host.storagePools`) are the secondary mode.
- **Bridged networking for DECLARED guests, onto an existing host bridge this repo never
  creates.** A host with no bridge at all is still a complete configuration, though: that
  is every laptop on wireless, and its ad-hoc guests use libvirt's own default NAT network.
  The bridge requirement therefore belongs to the guest that needs one, not to the host.
- **A remote hypervisor is a URI, not a package.** `qemu+ssh://` needs nothing installed on
  either end beyond libvirt itself, so `nixvm.host.remotes` is configuration —
  rendered as libvirt's own `uri_aliases`, to the path the local libvirt's `sysconfdir`
  actually points at, which is not the same path on both planes.
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

- **`vm-host`** (`nixosModules.vm-host`, `systemManagerModules.vm-host`) — the hypervisor
  stance on either plane: the daemon, the architecture-selected QEMU, optional tooling, the
  declared guest-network bridge, remote-libvirtd aliases, optional file-backed storage
  pools.
- **`guests`** (`nixosModules.guests`) — guest VM definitions as data, rendered to
  libvirt domain XML and kept declared. NixOS only. Always composed alongside `vm-host` —
  see its own README for why that composition is required, not just conventional.
- **`nixosModules.default`** — both together, for the common case.
  **`systemManagerModules.default`** — `vm-host` alone, which is the whole of this repo on
  that plane.
- **`lib.mkDomainXML`** — the pure XML-rendering function `guests` is built on,
  exposed for inspection or reuse without a NixOS evaluation (mirrors `nixfs` exposing
  its own catalogue).
- **`lib.toolchain` / `lib.resolve`** — the per-plane package catalogue and the pure
  channel resolution, so a consumer can ask what a selection resolves to without
  evaluating a system.
- **[docs/gotchas.md](docs/gotchas.md)** — the zvol/`nossd` incident and the
  Windows/`localtime` clock offset, written down so neither gets rediscovered.

## Status

**A clean slate, not a migration.** No libvirt state survives from any earlier era; this
repo starts from an idle KVM stack with nothing defined on top of it. `nix flake check`
proves the modules compose into a real NixOS system, that the distro backend evaluates
against system-manager's own option surface and reaches for nothing outside it, that the
x86-only default resolves to the x86-only QEMU on both planes while a named selection adds
exactly what was named — and, just as deliberately, that a declared guest with no bridge
anywhere, a guest missing its memory allocation or its disks, a malformed remote alias, and
the zvol/`nossd` gotcha with `nossd` actually missing, all fail evaluation by name rather
than producing something half-formed. Nothing here has yet hosted a guest on real hardware;
that is the next step, not this one.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
