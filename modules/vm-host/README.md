# vm-host

The declarative hypervisor stance for one host: libvirt/QEMU-KVM enabled, the bridge
guest network devices attach to, and optional file-backed storage pools for the
secondary guest-disk mode. See the module's own header comment for the full SCOPE block
(owned vs. explicitly not-owned).

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `nixvm.host.enable` | bool | `false` | Enable the module. |
| `nixvm.host.bridge` | null or str | **no default** | Which existing host bridge guest network devices attach to. Never created by this module — set it to a bridge your own host networking already brings up. |
| `nixvm.host.storagePools.<name>.path` | str | **no default** | Absolute directory this file-backed pool serves disk images out of. |
| `nixvm.host.storagePools.<name>.autostart` | bool | `true` | Whether libvirt starts this pool automatically at libvirtd startup. |
| `nixvm.host.storagePools.<name>.zvolBacked` | bool | `false` | Does `path` sit on a filesystem backed by a ZFS zvol (not a native dataset)? See [../../docs/gotchas.md](../../docs/gotchas.md). |

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

## GPU passthrough — deliberately absent

No option here (or in `guests/`) attaches a physical GPU to a guest. The host's GPU is
shared platform hardware other workloads depend on; a VM cannot hold a device
exclusively and still share it with them. The guest this module was built to host is
reached over RDP, which needs no GPU inside the guest at all. Re-litigate this
boundary — don't quietly work around it with an `extraDomainXML` passthrough snippet —
before ever adding a passthrough option.

## Minimal example

```nix
{
  imports = [ nixvm.nixosModules.vm-host ];

  nixvm.host = {
    enable = true;
    bridge = "br0";
  };
}
```

## Status

First cut. Not yet re-verified against a live host with a real guest running — see the
repo README's "Status" section.
