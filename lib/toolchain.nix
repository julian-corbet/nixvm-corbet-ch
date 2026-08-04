#
# The virtualisation toolchain catalogue: neutral names to per-plane package names, plus the
# guest-architecture table `nixvm.host.foreignArchitectures` selects from.
#
# WHY A CATALOGUE RATHER THAN A PACKAGE LIST INSIDE THE MODULE. The same reason the sibling
# catalogue flakes keep one: the two planes genuinely disagree about names, and the disagreement
# is not cosmetic. The x86-only QEMU is `qemu-desktop` on Arch and `qemu_kvm` in nixpkgs; the
# tool that builds a cloud-init seed image is `cloud-image-utils` on Arch and `cloud-utils` in
# nixpkgs. A module that hard-codes one plane's spelling is a module that cannot serve the other.
#
# THREE TABLES, AND THE LINE BETWEEN THEM MATTERS:
#
#   `daemon`        -- what `nixvm.host.enable` alone means. Not selectable: without these the
#                      declared capability does not exist, so offering them as choices would only
#                      offer the choice of a broken hypervisor.
#   `tools`         -- genuinely optional. A headless host that only ever runs `virsh` wants none
#                      of them; a laptop the operator actually sits at wants all of them.
#   `architectures` -- foreign guest architectures, off by default. See `nixvm.host.
#                      foreignArchitectures` for what the default costs, and what opting in does.
#
# EVERY `nixpkgs = null` IN `daemon` IS A DELIBERATE POSITIVE STATEMENT, not a missing entry: the
# thing exists in nixpkgs, but on the NixOS plane it arrives from `virtualisation.libvirtd`
# itself rather than from a package list, and adding it to `environment.systemPackages` on top
# would be a second owner for one fact. The Arch plane has no such module, so it must name the
# package. `checks/default.nix` pins that split in both directions.
{ ... }:
{
  # ── The daemon stance: installed whenever nixvm.host.enable is true ─────────────────────────
  daemon = {
    # The daemon and its client (`virsh`) -- the whole point of the module.
    # NixOS: `virtualisation.libvirtd.package`, already in systemPackages by that module.
    libvirt = { arch = "libvirt"; nixpkgs = null; };

    # The hypervisor itself, x86-64 only. `qemu-desktop` is Arch's x86-only path: it pulls
    # `qemu-base` (which is `qemu-system-x86` plus the image tools) and the audio/block/UI/display
    # plugin set, and NOT `qemu-emulators-full`. The obvious-looking `qemu-full` is the wrong
    # package here for exactly that reason -- it depends on `qemu-emulators-full` and therefore on
    # every foreign architecture, which is what `nixvm.host.foreignArchitectures` exists to keep
    # out of a host that never asked for it.
    #
    # `qemu-desktop` rather than the bare `qemu-base` because the plugin set IS the graphical
    # console: SPICE, the GTK UI, virtio-gpu, USB redirection. A host with a session wants them,
    # and both planes' selectable `manager`/`viewer` tools are useless without them. If a
    # genuinely headless consumer ever appears, this becomes a selection between the two rather
    # than a constant -- it is not one today because no such host exists to justify the knob.
    #
    # NixOS: `virtualisation.libvirtd.qemu.package`, which the backend sets to `pkgs.qemu_kvm`
    # (or a `hostCpuTargets` override) -- never `environment.systemPackages`, which is why this
    # row's nixpkgs channel is null like the rest of the daemon table.
    qemu = { arch = "qemu-desktop"; nixpkgs = null; };

    # The TPM emulator. Installed unconditionally rather than per-guest for the reason
    # modules/vm-host/nixos.nix's own swtpm line gives: an unused emulator binary costs an
    # inode, while a guest whose OS gates its install on a TPM (Windows 11) and finds none
    # costs an afternoon. NixOS: `virtualisation.libvirtd.qemu.swtpm.enable` owns the package.
    swtpm = { arch = "swtpm"; nixpkgs = null; };

    # DHCP and DNS for libvirt's OWN default NAT network -- the network a host with no bridge
    # has, which is exactly the host this module's Arch plane exists for (see the repo README's
    # "Bridged, and also not"). libvirt shells out to `dnsmasq` by name; without it the network
    # fails to start and an ad-hoc guest comes up with no address at all. It is an *optional*
    # dependency of the Arch `libvirt` package, so pacman will not have pulled it in.
    # NixOS: the libvirtd module puts `pkgs.dnsmasq` on libvirtd's own unit PATH.
    #
    # NOT DECLARED HERE, DELIBERATELY: `iptables`. libvirt's default network also needs a packet
    # filter to NAT through, and Arch's libvirt names `iptables-nft` as the optional dependency
    # for it -- but no package of that name exists in any Arch repo today (the nft-backed
    # implementation IS the `iptables` package; `iptables-legacy` is the other one). Naming a
    # package that does not exist fails the whole pacman transaction on "target not found",
    # taking every other package in the same converge down with it. It is also a firewall
    # package, which is another namespace's subject entirely. Treat it as a precondition of the
    # plane, not a claim this module makes.
    dnsmasq = { arch = "dnsmasq"; nixpkgs = null; };
  };

  # ── Optional tooling: `nixvm.host.tools` selects from these by key ──────────────────────────
  tools = {
    # The GUI. This is what makes "I am out and about and need a little VM" a five-minute job
    # rather than a hand-written domain XML document: pick an ISO or a cloud image, click
    # through, done. Earns its place on any host with a session; pure ballast on one without.
    manager = { arch = "virt-manager"; nixpkgs = "virt-manager"; };

    # The same capability from a script: `virt-install --osinfo ... --cloud-init ...`. A separate
    # entry from `manager` because the split is real on Arch (`virt-install` is its own package)
    # even though nixpkgs ships both binaries out of one derivation -- which is why both rows
    # name the same nixpkgs attribute and the resolution de-duplicates rather than installing it
    # twice.
    installer = { arch = "virt-install"; nixpkgs = "virt-manager"; };

    # The standalone console (`virt-viewer`, `remote-viewer`). virt-manager embeds a viewer, so
    # this is not simply a subset: it is how you open ONE guest's console -- including a guest on
    # a REMOTE libvirtd, straight from a URI -- without running the manager UI at all.
    viewer = { arch = "virt-viewer"; nixpkgs = "virt-viewer"; };

    # libguestfs's tool set: `virt-customize`, `virt-sysprep`, `guestfish`. Edit a downloaded
    # cloud image's contents -- set a password, inject an SSH key, install a package -- WITHOUT
    # booting it first. Pairs with `cloudInit` below; between them, "a little VM for something"
    # is a download and two commands instead of an OS install.
    images = { arch = "guestfs-tools"; nixpkgs = "guestfs-tools"; };

    # `cloud-localds`: builds the NoCloud seed ISO a cloud image reads its user-data from. The
    # missing half of the above -- a cloud image with no seed boots to a login prompt whose
    # credentials nobody knows, which is the single most common way this workflow wastes an hour.
    # Arch calls the package `cloud-image-utils`; nixpkgs folds Debian's `cloud-image-utils` and
    # `cloud-guest-utils` into one `cloud-utils` derivation.
    cloudInit = { arch = "cloud-image-utils"; nixpkgs = "cloud-utils"; };

    # The OS metadata database `virt-install --osinfo` and virt-manager consult to pick per-guest
    # defaults (firmware, disk bus, NIC model, driver hints). Without it both fall back to
    # generic defaults and a Windows guest in particular gets choices that work badly or not at
    # all. Small, and it is the difference between the tooling knowing what you are installing
    # and guessing.
    osinfo = { arch = "osinfo-db"; nixpkgs = "osinfo-db"; };
  };

  # ── Foreign guest architectures ─────────────────────────────────────────────────────────────
  #
  # `qemuTargets` is a LIST because the Arch packaging groups several QEMU targets into one
  # package and the grouping is not arbitrary -- `qemu-system-riscv` really does carry both
  # riscv32 and riscv64. Modelling it as one string per key would force either a table with rows
  # nobody can select independently, or a NixOS `hostCpuTargets` list that silently disagrees
  # with what the Arch plane installs for the same selection.
  #
  # The host's OWN architecture is never in this table: it is always built, on both planes, and
  # is not something a host should be able to switch off.
  architectures = {
    aarch64 = { arch = "qemu-system-aarch64"; qemuTargets = [ "aarch64-softmmu" ]; };
    alpha = { arch = "qemu-system-alpha"; qemuTargets = [ "alpha-softmmu" ]; };
    arm = { arch = "qemu-system-arm"; qemuTargets = [ "arm-softmmu" ]; };
    avr = { arch = "qemu-system-avr"; qemuTargets = [ "avr-softmmu" ]; };
    hppa = { arch = "qemu-system-hppa"; qemuTargets = [ "hppa-softmmu" ]; };
    loongarch64 = { arch = "qemu-system-loongarch64"; qemuTargets = [ "loongarch64-softmmu" ]; };
    m68k = { arch = "qemu-system-m68k"; qemuTargets = [ "m68k-softmmu" ]; };
    microblaze = { arch = "qemu-system-microblaze"; qemuTargets = [ "microblaze-softmmu" "microblazeel-softmmu" ]; };
    mips = { arch = "qemu-system-mips"; qemuTargets = [ "mips-softmmu" "mipsel-softmmu" "mips64-softmmu" "mips64el-softmmu" ]; };
    or1k = { arch = "qemu-system-or1k"; qemuTargets = [ "or1k-softmmu" ]; };
    ppc = { arch = "qemu-system-ppc"; qemuTargets = [ "ppc-softmmu" "ppc64-softmmu" ]; };
    riscv = { arch = "qemu-system-riscv"; qemuTargets = [ "riscv32-softmmu" "riscv64-softmmu" ]; };
    rx = { arch = "qemu-system-rx"; qemuTargets = [ "rx-softmmu" ]; };
    s390x = { arch = "qemu-system-s390x"; qemuTargets = [ "s390x-softmmu" ]; };
    sh4 = { arch = "qemu-system-sh4"; qemuTargets = [ "sh4-softmmu" "sh4eb-softmmu" ]; };
    sparc = { arch = "qemu-system-sparc"; qemuTargets = [ "sparc-softmmu" "sparc64-softmmu" ]; };
    tricore = { arch = "qemu-system-tricore"; qemuTargets = [ "tricore-softmmu" ]; };
    xtensa = { arch = "qemu-system-xtensa"; qemuTargets = [ "xtensa-softmmu" "xtensaeb-softmmu" ]; };
  };
}
