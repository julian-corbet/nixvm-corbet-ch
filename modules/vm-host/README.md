# vm-host

The declarative hypervisor stance for one host: the libvirt daemon, a QEMU built for the
architectures the host actually asked for, optional tooling, the bridge guest network
devices attach to, aliases for remote libvirtd instances, and optional file-backed
storage pools for the secondary guest-disk mode.

Three files, one policy:

| file | what it is |
|---|---|
| `vm-host.nix` | the policy — every option, and its resolution. Platform-neutral; installs nothing. Its header carries the full SCOPE block (owned vs. explicitly not-owned). |
| `nixos.nix` | `nixosModules.vm-host` — the NixOS delivery |
| `arch.nix` | `systemManagerModules.vm-host` — the system-manager delivery for a distro host |

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `nixvm.host.enable` | bool | `false` | Enable the module: the daemon, the x86-only QEMU, the TPM emulator, and libvirt's own NAT-network dependency. |
| `nixvm.host.foreignArchitectures` | list of enum | `[ ]` | Guest architectures **other** than this host's own. Empty means x86-64 with KVM and nothing else. See below. |
| `nixvm.host.tools` | list of enum | `[ ]` | Optional tooling: `manager`, `installer`, `viewer`, `images`, `cloudInit`, `osinfo`. |
| `nixvm.host.bridge` | null or str | `null` | Which existing host bridge guest network devices attach to by default. Never created by this module. `null` is a complete answer, not an omission — see below. |
| `nixvm.host.remotes.<name>.uri` | str | **no default** | A remote libvirtd, addressable as `<name>`. Rendered as libvirt's own `uri_aliases`. |
| `nixvm.host.storagePools.<name>.path` | str | **no default** | Absolute directory this file-backed pool serves disk images out of. |
| `nixvm.host.storagePools.<name>.autostart` | bool | `true` | Whether libvirt starts this pool automatically at libvirtd startup. |
| `nixvm.host.storagePools.<name>.zvolBacked` | bool | `false` | Does `path` sit on a filesystem backed by a ZFS zvol (not a native dataset)? See [../../docs/gotchas.md](../../docs/gotchas.md). |

Read-only outputs: `archPackages`, `aurPackages` (wire both to the host's own reconciler on
a distro plane), `nixpkgsPackages` and `unavailableOnArch`.

## The catalogue, and why nothing is installed twice

Every entry in `lib/toolchain.nix` names itself on both channels — `arch` and `nixpkgs` —
the same shape as the sibling `nixdev`/`nixoffice`/`nixfs` catalogues. Four rows disagree
across channels and none of the disagreements is guessable: `cloud-image-utils`/`cloud-utils`,
`virt-install`/`virt-manager` (two pacman packages, one nixpkgs derivation),
`qemu-desktop`/`qemu_kvm`, and the 18 `qemu-system-<arch>` rows, for which nixpkgs has **no**
package at all (`nixpkgs = null` — a foreign architecture there is a `--target-list` entry).

**No host ends up with two copies of one tool**, and each plane gets that wrong differently:

- **Arch** — `/usr/sbin` precedes the system-manager Nix profile on `PATH`, so a nixpkgs copy
  of something pacman also has is the copy that *loses*. An entry with a pacman name is
  published for the reconciler and installed from nowhere by this flake; only `arch = null`
  entries (`unavailableOnArch`) come from nixpkgs. `aur = true` marks a name that is real on
  Arch but not in an official repo — a valid Arch source, held back only because `pacman -S`
  fails the whole transaction on an AUR name.
- **NixOS** — `virtualisation.libvirtd` already delivers libvirt, its QEMU, swtpm and dnsmasq,
  and the QEMU it *execs* is `virtualisation.libvirtd.qemu.package`. Those rows are marked
  `viaLibvirtd = true` and excluded from `nixpkgsPackages`; a second copy in
  `environment.systemPackages` would be a differently-configured binary nothing ever runs.

`nix flake check` asserts both directions on the live catalogue: the Arch backend installs
an empty list from nixpkgs, `archPackages ++ aurPackages` covers every selected entry, and no
`viaLibvirtd` row reaches the NixOS install list.

## x86-64 only, by default

`foreignArchitectures` is empty by default and that is the whole point. A host's own
architecture runs under hardware virtualization; every other one runs under software
emulation, which is a different activity with a different reason for existing. Both planes
make the full set easy to acquire by accident: on Arch the obvious `qemu-full` depends on
`qemu-emulators-full` and lands roughly 600 MiB of emulators and firmware, of which the x86
one is under a tenth; in nixpkgs the top-level `qemu` builds every target for the same
reason.

So the two planes resolve the empty default to their own x86-only path — `qemu-desktop` on
Arch, `pkgs.qemu_kvm` (which is exactly `qemu.override { hostCpuOnly = true; }`) on NixOS —
and a named selection adds `qemu-system-<arch>` packages or `hostCpuTargets` entries on top.

**On NixOS, a non-empty list costs a QEMU source build.** The empty default is a cached
nixpkgs attribute; any selection becomes a `hostCpuTargets` override, which nothing upstream
builds.

## A host with no bridge is a real host

`bridge` used to be required whenever the module was enabled. It is not any more, because
that made the most ordinary hypervisor there is — a laptop on wireless, where bridging onto
the physical link is not something the hardware does — declarable only by naming an
interface that does not exist. Such a host runs ad-hoc guests on libvirt's own default NAT
network instead, which is why `dnsmasq` is part of the daemon stance on the Arch plane.

What genuinely cannot be null is the bridge a **declared guest** attaches to, since that
value is rendered verbatim into a domain document. That requirement lives in `../guests`
now, and names the guest rather than the host.

## Driving a remote libvirtd

`remotes` needs no extra package on either end. The client is `virsh`/`virt-manager`; the
`qemu+ssh://` transport is an ordinary SSH connection that runs `virt-ssh-helper` on the
remote, and that binary ships inside libvirt itself on both planes. So this is configuration,
not installation — a URI, rendered as `uri_aliases` so `virsh -c <name>`, virt-manager and
virt-viewer all resolve the same alias from one declaration.

Where that file goes differs by plane, because libvirt reads it from the `sysconfdir` it was
**built** with: `/etc/libvirt/libvirt.conf` for a distro build, `/var/lib/libvirt/libvirt.conf`
for nixpkgs (`--sysconfdir=/var/lib`). Nothing is rendered at all unless `remotes` is
non-empty — on the Arch plane that path belongs to the distro's own libvirt package, and a
host that declared no remote must not take it over.

## Why storage pools are optional

The PRIMARY guest-disk mode is a zvol handed to a guest directly as a raw block
device — no libvirt storage pool involved at all; `nixvm.guests.<name>.disks.<dev>`
just points at the zvol's device path. `storagePools` exists only for the SECONDARY
mode: qcow2 files living in an ordinary directory. A host with every guest disk
zvol-backed declares no storage pools.

## The zvol/btrfs/`nossd` assertion

If a pool is marked `zvolBacked = true` and this host's own `fileSystems.<path>` entry
is visible in the same evaluation with `fsType = "btrfs"` and no `"nossd"` in its
`options`, evaluation fails, naming the pool. This module never adds the mount option
for you — mount options for a filesystem it didn't create are not its to rewrite — see
[docs/gotchas.md](../../docs/gotchas.md) for the full story and why this bit a real
operator before.

**The check exists on the NixOS plane only.** system-manager has no `fileSystems` option
to read, so `arch.nix` warns that the check did not run rather than pretending it did. The
hazard is a property of the zvol and the filesystem on top of it, not of the configuration
system, so on a distro host verify the mount option by hand.

## GPU passthrough — deliberately absent

No option here (or in `guests/`) attaches a physical GPU to a guest. The host's GPU is
shared platform hardware other workloads depend on; a VM cannot hold a device
exclusively and still share it with them. The guest this module was built to host is
reached over RDP, which needs no GPU inside the guest at all. Re-litigate this
boundary — don't quietly work around it with an `extraDomainXML` passthrough snippet —
before ever adding a passthrough option.

## Minimal examples

A NixOS host with a bridge and declared guests:

```nix
{
  imports = [ nixvm.nixosModules.vm-host ];

  nixvm.host = {
    enable = true;
    bridge = "br0";
    tools = [ "manager" "viewer" "images" "cloudInit" ];
  };
}
```

A distro laptop with no bridge, that also drives a remote hypervisor:

```nix
{
  imports = [ nixvm.systemManagerModules.vm-host ];

  nixvm.host = {
    enable = true;
    tools = [ "manager" "installer" "viewer" "images" "cloudInit" "osinfo" ];
    remotes.vmhost.uri = "qemu+ssh://root@vmhost.example/system";
  };

  # nixvm resolves names; it does not install. Connect its output to your reconciler:
  nixarch.packages.pacman = config.nixvm.host.archPackages;
  nixarch.packages.aur = config.nixvm.host.aurPackages;
}
```

## Status

Both planes are proven by `nix flake check` and neither has yet hosted a guest on real
hardware — see the repo README's "Status" section.
