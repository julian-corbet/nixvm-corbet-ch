# Gotchas

Operational lessons this repo's option surface exists to encode, not just document.

## A zvol used under a foreign filesystem needs `nossd`

**The mistake.** A libvirt storage pool (`nixvm.host.storagePools.<name>`, the
file-backed secondary disk mode) is just a directory. If that directory's filesystem
happens to be mounted from a ZFS **zvol** rather than a native ZFS dataset -- for
example a zvol formatted with btrfs and mounted at the pool's `path` -- the mount is
missing something a native dataset never needs: the `nossd` mount option.

**Why.** btrfs decides whether to apply its SSD-tuned heuristics (chunk allocation,
free-space cache behavior) by asking the block device whether it is rotational. A zvol
always reports itself as non-rotational, regardless of what actually backs the pool it
lives in. btrfs then applies SSD assumptions on top of a device that is *already* doing
its own copy-on-write block allocation underneath -- a combination that has bitten this
operator before. `nossd` on the mount turns that auto-detection off.

**Where this repo catches it.** `nixvm.host.storagePools.<name>.zvolBacked` is an
explicit, non-guessable fact you set to `true` for exactly this situation. When it is
set, and this host's own `fileSystems.<path>` entry is visible in the same evaluation
with `fsType = "btrfs"` and no `"nossd"` in its `options`, evaluation **fails** with a
message naming the pool -- see `modules/vm-host/nixos.nix`'s assertion and
`checks/default.nix`'s `zvol-nossd-gotcha/*` group, which proves both the passing and
the failing direction. A pool backed by a native ZFS dataset (`zvolBacked = false`, the
default) is never checked at all -- there is nothing to check.

**What this module does NOT do.** It never adds `nossd` to `fileSystems.<path>.options`
for you. Mount options for a filesystem this module didn't create are not this module's
to silently rewrite -- the same "declare and assert, never create or impose" stance
`modules/vm-host/vm-host.nix`'s own SCOPE block states for the ESP-style facts it reads
elsewhere in this house's other modules. Add `"nossd"` to that filesystem's own
`options` list yourself; the assertion exists to make sure you don't forget to.

## A Windows guest's clock runs on `localtime`, not `utc`

**The mistake.** libvirt's own upstream default for a domain's `<clock offset='...'/>`
is `"utc"` -- correct for a Linux guest, wrong for a Windows one. Windows reads the
emulated hardware clock as local wall-clock time by default; hand it a UTC-offset clock
and it shows the wrong time for its entire uptime (and confuses anything inside the
guest that reads the clock before its own timezone service has run).

**Where this repo catches it.** `nixvm.guests.<name>.clockOffset` defaults to
`"localtime"` -- the opposite of libvirt's own default -- because the guest this repo
was built to host is Windows. A Linux guest should set it back to `"utc"` explicitly;
see the option's own description.
