# guests

Persistent guest VM definitions, as data. One attrset key per guest under
`nixvm.guests.<name>`; each renders to a libvirt domain XML document and stays
declared via `virsh define` + `virsh autostart` on every activation. See the module's
own header comment for the full SCOPE block, and its "ALWAYS COMPOSED WITH
modules/vm-host" note — this module reads `nixvm.host.bridge` directly and asserts
`nixvm.host.enable`.

## What "kept declared" means, precisely

`virsh define` changes what a guest **will** boot into the next time it starts. It
never touches a guest that is already running — the same "declare, don't force"
discipline nixk3s applies to k3s node labels and nixboot applies to Secure Boot
enrollment. Powering a guest on, off, or rebooting it is always an operator action
(`virsh start`/`virsh shutdown`/virt-manager), never something a `nixos-rebuild switch`
does on this module's behalf. `autostart` is the one exception worth naming explicitly:
it only affects behavior at the **host's** next boot, never the guest's current state.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `nixvm.guests.<name>.memoryMiB` | null or positive int | **no default** | RAM (MiB) this guest permanently claims from the host. |
| `nixvm.guests.<name>.cpu.cores` | positive int | `2` | Static vCPU count. |
| `nixvm.guests.<name>.cpu.model` | enum `host-passthrough`\|`host-model` | `host-passthrough` | CPU feature exposure; `host-passthrough` is right for a guest that never migrates to different hardware. |
| `nixvm.guests.<name>.firmware` | enum `bios`\|`uefi` | `uefi` | The GUEST's own firmware (QEMU's bundled OVMF for `uefi`) — unrelated to how the host itself boots. |
| `nixvm.guests.<name>.clockOffset` | enum `utc`\|`localtime` | `localtime` | RTC offset presented to the guest. `localtime` matches what Windows expects; a Linux guest should set `utc`. See [../../docs/gotchas.md](../../docs/gotchas.md). |
| `nixvm.guests.<name>.autostart` | bool | `false` | Whether libvirt powers this guest on when the HOST boots. |
| `nixvm.guests.<name>.tpm.enable` | bool | `false` | Attach an emulated TPM 2.0 device. |
| `nixvm.guests.<name>.graphics.enable` | bool | `true` | Attach a libvirt graphical console (VNC/SPICE) — for OS install and initial setup, not the guest's ongoing remote-access story. |
| `nixvm.guests.<name>.graphics.type` | enum `vnc`\|`spice` | `vnc` | Which graphics protocol. |
| `nixvm.guests.<name>.graphics.listenAddress` | str | `"127.0.0.1"` | Loopback by default; reaching it remotely is a host-access problem, not this module's. |
| `nixvm.guests.<name>.network.bridge` | null or str | `null` (→ `nixvm.host.bridge`) | Override only for a guest that needs a different bridge than the host default. |
| `nixvm.guests.<name>.network.model` | enum `virtio`\|`e1000e`\|`rtl8139` | `virtio` | Guest-visible NIC model. |
| `nixvm.guests.<name>.network.macAddress` | null or MAC string | `null` | Pin for a stable DHCP lease across redefines. |
| `nixvm.guests.<name>.disks.<dev>.sourceType` | enum `zvol`\|`file` | `zvol` | Primary mode is a raw zvol block device; `file` is the secondary qcow2-in-a-pool mode. |
| `nixvm.guests.<name>.disks.<dev>.source` | null or str | **no default** | The zvol device path or qcow2 file path. |
| `nixvm.guests.<name>.disks.<dev>.bus` | enum `virtio`\|`sata` | `virtio` | Guest-visible disk controller. |
| `nixvm.guests.<name>.extraDomainXML` | lines | `""` | Escape hatch: raw XML appended inside `<devices>`. |

## What is deliberately NOT modeled in this first cut

- **Installer media.** No cdrom/ISO option surface. Attach one out-of-band
  (`virsh attach-disk ... --type cdrom`, or virt-manager) for the initial OS install,
  then detach it.
- **GPU passthrough.** See `modules/vm-host`'s own README section — the boundary is
  the same one, stated once.
- **The guest operating system's own configuration.** What runs inside the guest —
  including its own RDP setup, or an office suite (see `nixoffice`, a different repo
  entirely) — is invisible to this module.

## Minimal example

```nix
{
  imports = [ nixvm.nixosModules.default ]; # vm-host + guests together

  nixvm.host = {
    enable = true;
    bridge = "br0";
  };

  nixvm.guests.example-guest = {
    memoryMiB = 8192;
    cpu.cores = 4;
    firmware = "uefi";
    tpm.enable = true; # e.g. a guest OS that gates its install on a TPM
    disks.vda.source = "/dev/zvol/pool/example-guest";
  };
}
```

## Status

First cut. Not yet re-verified against a live host with a real guest running — see the
repo README's "Status" section.
