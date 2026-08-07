#
# The virtualisation toolchain catalogue: one entry per tool, naming it on each platform, plus the
# guest-architecture table `nixvm.host.foreignArchitectures` selects from.
#
# TWO COLUMNS, THE SAME SHAPE AS THE SIBLING CATALOGUES (nixdev/lib/tools.nix,
# nixoffice/lib/tools.nix, nixfs/lib/catalogue.nix). Every entry names itself twice, `arch` and
# `nixpkgs`, even where the two strings are identical -- because they are not always, and the
# divergence is not guessable. In this catalogue four entries disagree:
#
#   cloud-image-utils / cloud-utils   Arch names Debian's image half; nixpkgs keeps upstream's
#                                     own name (canonical/cloud-utils), which folds Debian's
#                                     cloud-image-utils and cloud-guest-utils into one derivation.
#   virt-install      / virt-manager  a separate pacman package on Arch; one derivation in nixpkgs
#                                     that ships virt-install, virt-clone and virt-xml alongside
#                                     the GUI. Two rows, one nixpkgs attribute, de-duplicated.
#   qemu-desktop      / qemu_kvm      not a rename -- two different packaging models, see the row.
#   qemu-system-<a>   / (nothing)     nixpkgs has NO per-architecture qemu package at all; a
#                                     foreign architecture there is a `--target-list` entry, not
#                                     a package. Those rows carry `nixpkgs = null` truthfully.
#
# WE DO NOT SHADOW. No host may end up with two copies of one tool, and the two planes each have
# their own way of getting that wrong:
#
#   On ARCH, `/usr/sbin` precedes the system-manager Nix profile on `PATH` -- nixfs's catalogue
#   header records the live evidence (mkfs.xfs, smartctl, pv, mcopy and others all resolving to
#   the distro copy while pinned nixpkgs copies sat unreached). So an entry with a pacman name is
#   published for the reconciler and installed from NOWHERE by this flake; only `arch = null`
#   entries come from nixpkgs there, which is the one case where no second copy exists to race.
#
#   On NixOS the hazard is not `PATH`, it is `virtualisation.libvirtd`. That module already puts
#   libvirt and its QEMU on the system and hands libvirtd its own `swtpm`/`dnsmasq`, and the QEMU
#   it EXECS is whatever `virtualisation.libvirtd.qemu.package` says. Adding those same packages
#   to `environment.systemPackages` would put a second, differently-configured QEMU in the closure
#   that nothing ever runs -- the identical defect, one plane over. `viaLibvirtd = true` marks
#   those rows, and they are excluded from the nixpkgs install list for exactly that reason.
#
# `aur = true` marks a pacman name that lives in the AUR rather than an official repo. The AUR is
# a valid Arch source, not a fallback: such an entry is still installed BY Arch, it just has to be
# held back into `aurPackages` because `pacman -S` cannot resolve an AUR name and fails the whole
# transaction on "target not found". No entry here needs it today -- all 28 pacman names below are
# in `extra`, verified with `pacman -Si` -- so the branch is exercised by a fixture in ../checks/
# rather than by a live row.
#
# EVERY NAME HERE WAS VERIFIED ON BOTH CHANNELS, by identity and not merely by existence: `pacman
# -Si <name>` for the repo and description, and a FORCED nixpkgs evaluation reading back
# `meta.description` and `meta.homepage` (an attribute can exist and still be a different project
# -- `pkgs.zoom` is a Z-code interpreter, not the conferencing client -- or exist as a `throw`
# that only forcing reveals).
{ ... }:
{
  # ── The daemon stance: installed whenever nixvm.host.enable is true ─────────────────────────
  #
  # Not selectable, unlike `tools` below: without these the declared capability does not exist, so
  # offering them as choices would only offer the choice of a broken hypervisor.
  daemon = {
    # The daemon and its client (`virsh`) -- the whole point of the module.
    libvirt = { arch = "libvirt"; nixpkgs = "libvirt"; viaLibvirtd = true; };

    # The hypervisor itself, x86-64 only, and the one row where the two channels differ by
    # PACKAGING MODEL rather than by spelling.
    #
    # Arch splits QEMU across many packages: `qemu-desktop` pulls `qemu-base` (which is
    # `qemu-system-x86` plus the image tools) and the audio/block/UI/display plugin set, and
    # explicitly NOT `qemu-emulators-full`. The obvious-looking `qemu-full` is the wrong name here
    # for precisely that reason -- it depends on `qemu-emulators-full` and therefore on every
    # foreign architecture, which is what `nixvm.host.foreignArchitectures` exists to keep off a
    # host that never asked for it. `qemu-desktop` rather than the bare `qemu-base` because the
    # plugin set IS the graphical console (SPICE, GTK, virtio-gpu, USB redirection), without which
    # the selectable `manager`/`viewer` tools have nothing to draw on.
    #
    # nixpkgs builds one derivation and varies its `--target-list`. `qemu_kvm` is exactly
    # `qemu.override { hostCpuOnly = true; }` -- verified: pname `qemu-host-cpu-only`,
    # `--target-list=i386-softmmu,x86_64-softmmu` -- while the top-level `qemu` leaves
    # `hostCpuTargets` at null, which configures EVERY target and is the nixpkgs equivalent of
    # `qemu-full`. `qemu_kvm` is also a stock attribute, so it has a binary cache behind it.
    qemu = { arch = "qemu-desktop"; nixpkgs = "qemu_kvm"; viaLibvirtd = true; };

    # The TPM emulator. Part of the stance rather than per-guest: an unused emulator binary costs
    # an inode, while a guest whose OS gates its install on a TPM (Windows 11) and finds none
    # costs an afternoon.
    swtpm = { arch = "swtpm"; nixpkgs = "swtpm"; viaLibvirtd = true; };

    # DHCP and DNS for libvirt's OWN default NAT network -- the network a host with no bridge has,
    # which is exactly the host this module's Arch plane exists for. libvirt shells out to
    # `dnsmasq` by name; without it the network fails to start and an ad-hoc guest comes up with
    # no address at all. It is an OPTIONAL dependency of the Arch `libvirt` package, so pacman
    # will not have pulled it in. `viaLibvirtd` because on NixOS the libvirtd module puts
    # `pkgs.dnsmasq` on libvirtd's own unit PATH, which is the only place it needs to be.
    #
    # NOT A ROW HERE, DELIBERATELY: `iptables`. libvirt's default network also needs a packet
    # filter to NAT through, and Arch's libvirt names `iptables-nft` as the optional dependency
    # for it -- but no package of that name exists in any Arch repo today (`pacman -Si
    # iptables-nft` reports "package not found"; the nft-backed implementation IS the `iptables`
    # package, and `iptables-legacy` is the other one). Naming a package that does not exist fails
    # the whole pacman transaction on "target not found", taking every other package in the same
    # converge with it. It is also a firewall package, which is another namespace's subject
    # entirely. Treat it as a precondition of the plane, not a claim this module makes.
    dnsmasq = { arch = "dnsmasq"; nixpkgs = "dnsmasq"; viaLibvirtd = true; };
  };

  # ── Optional tooling: `nixvm.host.tools` selects from these by key ──────────────────────────
  #
  # No `viaLibvirtd` on any of these: they are ordinary packages a person runs, so on NixOS they
  # are an `environment.systemPackages` install and on Arch they are pacman's.
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
    #
    # ⚠ THE TWO PLANES DISAGREE ABOUT WHAT THIS COSTS BY THREE ORDERS OF MAGNITUDE, and the
    # reason is a packaging difference worth knowing before selecting it on a space-constrained
    # host. Both figures are measured, not estimated.
    #
    #   NixOS  ~5.0 GiB of closure. `guestfs-tools` pulls `libguestfs`, which pulls a PREBUILT
    #          4 GiB appliance derivation AND the top-level all-targets `qemu` (~965 MiB) --
    #          reintroducing, through a side door, exactly the QEMU `foreignArchitectures` keeps
    #          out of `virtualisation.libvirtd.qemu.package`. `nix why-depends` names the chain:
    #          system-path -> guestfs-tools -> libguestfs -> qemu. Nothing in this catalogue can
    #          prevent it; it is libguestfs's own dependency, and it does NOT widen the declared
    #          architecture stance -- the QEMU libvirtd execs is still the x86-only one.
    #
    #   Arch   36 MiB of packages (libguestfs 6.9 + guestfs-tools 29.2), and NO second QEMU at
    #          all: the `qemu` its libguestfs depends on is a virtual provide already satisfied
    #          by `qemu-base`, which the `daemon.qemu` row above pulls in via `qemu-desktop`.
    #          There is no shipped appliance either -- Arch builds one with supermin on first use
    #          (/usr/lib/guestfs/supermin.d is 2.4 MiB of manifests) from the host's OWN installed
    #          packages, cached under /var/tmp/.guestfs-$UID and rebuilt when those change.
    #
    # So the same selection is a rounding error on a distro host and a real decision on a NixOS
    # one. Stated here rather than left for a consumer to discover after a deploy.
    images = { arch = "guestfs-tools"; nixpkgs = "guestfs-tools"; };

    # `cloud-localds`: builds the NoCloud seed ISO a cloud image reads its user-data from. The
    # missing half of the above -- a cloud image with no seed boots to a login prompt whose
    # credentials nobody knows, which is the single most common way this workflow wastes an hour.
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
  # `nixpkgs = null` on every row, and it is TRUE rather than a placeholder: nixpkgs ships no
  # per-architecture QEMU package for these to name. A foreign architecture there is a
  # `--target-list` entry on the one qemu derivation, which is what `qemuTargets` carries and what
  # `viaLibvirtd` points at -- the same `virtualisation.libvirtd.qemu.package` the `daemon.qemu`
  # row above is delivered through.
  #
  # `qemuTargets` is a LIST because the Arch packaging groups several QEMU targets into one
  # package and the grouping is not arbitrary -- `qemu-system-riscv` really does carry both
  # riscv32 and riscv64. Modelling it as one string per key would force either a table with rows
  # nobody can select independently, or a NixOS `hostCpuTargets` list that silently disagrees with
  # what the Arch plane installs for the same selection.
  #
  # The host's OWN architecture is never in this table: it is always built, on both planes, and is
  # not something a host should be able to switch off.
  architectures = {
    aarch64 = { arch = "qemu-system-aarch64"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "aarch64-softmmu" ]; };
    alpha = { arch = "qemu-system-alpha"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "alpha-softmmu" ]; };
    arm = { arch = "qemu-system-arm"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "arm-softmmu" ]; };
    avr = { arch = "qemu-system-avr"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "avr-softmmu" ]; };
    hppa = { arch = "qemu-system-hppa"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "hppa-softmmu" ]; };
    loongarch64 = { arch = "qemu-system-loongarch64"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "loongarch64-softmmu" ]; };
    m68k = { arch = "qemu-system-m68k"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "m68k-softmmu" ]; };
    microblaze = { arch = "qemu-system-microblaze"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "microblaze-softmmu" "microblazeel-softmmu" ]; };
    mips = { arch = "qemu-system-mips"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "mips-softmmu" "mipsel-softmmu" "mips64-softmmu" "mips64el-softmmu" ]; };
    or1k = { arch = "qemu-system-or1k"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "or1k-softmmu" ]; };
    ppc = { arch = "qemu-system-ppc"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "ppc-softmmu" "ppc64-softmmu" ]; };
    riscv = { arch = "qemu-system-riscv"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "riscv32-softmmu" "riscv64-softmmu" ]; };
    rx = { arch = "qemu-system-rx"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "rx-softmmu" ]; };
    s390x = { arch = "qemu-system-s390x"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "s390x-softmmu" ]; };
    sh4 = { arch = "qemu-system-sh4"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "sh4-softmmu" "sh4eb-softmmu" ]; };
    sparc = { arch = "qemu-system-sparc"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "sparc-softmmu" "sparc64-softmmu" ]; };
    tricore = { arch = "qemu-system-tricore"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "tricore-softmmu" ]; };
    xtensa = { arch = "qemu-system-xtensa"; nixpkgs = null; viaLibvirtd = true; qemuTargets = [ "xtensa-softmmu" "xtensaeb-softmmu" ]; };
  };
}
