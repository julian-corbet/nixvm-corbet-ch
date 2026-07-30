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
| *(no resource ceiling option)* | — | — | **Read from `nixhost.environments.<name>.resources`, matched by name.** `ram.limitMiB` renders `<memory>`/`<currentMemory>`; `cpu.quotaCores` renders `<vcpu>` (rounded UP to the nearest whole vCPU — libvirt's vCPU count cannot be fractional). See "The resource envelope" below for why this module declares neither itself, and why the two diverge on what "absent" means. |
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

## The resource envelope: read from nixhost, not declared here

An earlier draft of this module declared `memoryMiB` (required, no default) and
`cpu.cores` (default `2`) of its own. `nixhost` already declares
`environments.<name>.resources.ram.limitMiB` and `.cpu.quotaCores`, and owns the only
arithmetic nothing else can do — summing every environment's claim at each level of the
tree and refusing to evaluate when a node's children claim more than that node has. A
second ceiling here would not duplicate that check, it would **disarm** it: nixhost
would keep summing numbers nobody rendered while this module rendered different ones.
So this module reads the envelope instead, matched **by name**
(`nixvm.guests.<name>` ↔ `nixhost.environments.<name>`), defensively
(`config.nixhost.environments or { }`) and never as a flake input — a host that has
never imported nixhost still evaluates, at least as far as this module's own
assertions (see below).

**Memory and CPU diverge on what "absent" means**, checked empirically against the
real libvirt domain parser (`virsh define` against the `test:///default` driver, no
running libvirtd needed) rather than assumed:

- A domain document with no `<vcpu>` element **defines fine** — libvirt applies its
  own upstream default (a single vCPU). So `cpu.quotaCores` absent means the `<vcpu>`
  element is simply omitted: genuine "no ceiling", not a guessed number.
- A domain document with no `<memory>` element is **refused outright** —
  `error: XML error: Memory size must be specified via <memory> or in the <numa>
  configuration`. A libvirt guest has no equivalent of "run unbounded" the way an LXC
  container or podman container does. So `ram.limitMiB` unresolved (nixhost not
  imported, this guest not declared in it, or declared without a limit) is a **build
  error**, naming `nixhost.environments.<name>.resources.ram.limitMiB` — never a
  guessed number, and never a domain XML document libvirt would refuse to define.

`quotaCores` may be fractional (a cgroup quota of `1.5` cores is a real shape for
other substrates); a libvirt `<vcpu>` count cannot be, so a fractional ceiling is
rounded **up** to the smallest whole vCPU count that can deliver at least that much
capacity. This module does not also throttle the guest to the exact fractional figure
via a `<cputune>` quota/period pair — a known, deliberately unaddressed gap, not a
silent decision.

**The cross-check.** If nixhost declares the same name with a `kind` other than
`"vm"` (say, `"lxc"`), evaluation fails: the two declarations disagree about what the
object *is*, and nixhost's arithmetic would be budgeting an envelope for the wrong
kind of thing entirely.

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

  # The resource envelope comes from nixhost, matched by name -- see "The resource
  # envelope" section above.
  nixhost.environments.example-guest = {
    kind = "vm";
    resources.ram.limitMiB = 8192;
    resources.cpu.quotaCores = 4;
  };

  nixvm.guests.example-guest = {
    firmware = "uefi";
    tpm.enable = true; # e.g. a guest OS that gates its install on a TPM
    disks.vda.source = "/dev/zvol/pool/example-guest";
  };
}
```

## Status

First cut. Not yet re-verified against a live host with a real guest running — see the
repo README's "Status" section.
