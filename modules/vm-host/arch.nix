# modules/vm-host/arch.nix
#
# The Arch/system-manager backend. Publishes the stance as pacman/AUR names for the host's own
# reconciler, installs from nixpkgs ONLY the entries Arch has nothing for at all, and renders the
# storage-pool apply units and the remote-connection aliases.
#
# THE ANTI-SHADOWING RULE THIS FILE ENFORCES, the same one nixfs's own Arch backend documents. On
# a live Arch host `/usr/sbin` precedes the system-manager Nix profile on `PATH`, so a package
# installed from nixpkgs into that profile when pacman ALSO has it does not add redundancy -- it
# adds a copy that is never the one that runs, dead weight in every rebuild and a pin that means
# nothing. So the line here is hard: an entry with a pacman name is PUBLISHED for the reconciler
# and installed from nowhere by this module; an entry with no Arch source at all
# (`unavailableOnArch`) is installed from nixpkgs and published nowhere else. No entry is ever
# both. For this catalogue that leaves no residue today -- all 28 pacman names are in an official
# repo -- so the nixpkgs path is exercised by a fixture in ../../checks/, not by a live row.
#
# The published lists are NOT wired to a reconciler here, on purpose -- the same reasoning the
# sibling nixdev/nixoffice/nixfs Arch backends give: wiring one in would couple a general flake to
# one deployment's package module. A host's own config connects them:
#
#   nixarch.packages.pacman = config.nixvm.host.archPackages;
#   nixarch.packages.aur    = config.nixvm.host.aurPackages;
#
# WHAT THIS FILE DELIBERATELY DOES NOT SET, because system-manager has no such option and
# composing one would fail evaluation on this plane outright:
#
#   `virtualisation.*`     -- there is no `virtualisation` namespace here at all. The daemon is a
#                             pacman package and an ordinary systemd unit the distro ships; the
#                             reconciler installs it and systemd runs it, with nothing for a
#                             module to enable.
#   `boot.kernelModules`   -- no `boot` namespace either. NixOS's libvirtd module loads `tun`
#                             this way; on Arch, `tun` is built into or auto-loaded by the distro
#                             kernel and is not this module's to arrange.
#   `fileSystems`          -- which is why the zvol/`nossd` assertion cannot exist here and this
#                             file warns instead (see below).
#   `users.groups`         -- system-manager DOES have a users module, but the `libvirt` group on
#                             Arch is created by the package's own sysusers entry, and Arch's
#                             shipped polkit rule already grants `wheel`. Declaring the group a
#                             second time would be a second owner for a fact the distro already
#                             owns, and a GID this module has no business choosing.
#
# NOR modules/guests. That module is NixOS-only, and not by omission: it renders `virsh define`
# units against `config.virtualisation.libvirtd.package`, and it reads a resource envelope from
# `nixhost.environments`, a namespace that is composed on the NixOS hosts. A distro host runs
# ad-hoc guests it created by hand -- which is the whole shape this plane exists for -- and
# declaring persistent guests there is a capability that has not been built, rather than one that
# was suppressed.
{ lib, config, pkgs, ... }:

let
  cfg = config.nixvm.host;
  resolve = import ../../lib/resolve.nix { inherit lib; };
  pools = import ../../lib/pools.nix { inherit lib; };

  zvolBackedPools = lib.filter (n: cfg.storagePools.${n}.zvolBacked) (lib.attrNames cfg.storagePools);

  # The ONLY entries this backend may touch with nixpkgs: exactly the ones with no Arch source at
  # all, never more. Filtered from `cfg.want` directly rather than re-derived from the published
  # `unavailableOnArch` name list, so a bug that changed what gets INSTALLED here could not also
  # quietly change what the option REPORTS -- nixfs's own backend draws the same distinction for
  # the same reason.
  nixpkgsOnly = lib.filter (t: (t.arch or null) == null && (t.nixpkgs or null) != null) cfg.want;
  path = name: lib.splitString "." name;
  resolves = t: lib.hasAttrByPath (path t.nixpkgs) pkgs;
  missing = lib.filter (t: !(resolves t)) nixpkgsOnly;
in
{
  imports = [ ./vm-host.nix ];

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages =
        map (t: lib.getAttrFromPath (path t.nixpkgs) pkgs) (lib.filter resolves nixpkgsOnly);

      assertions = [
        {
          assertion = missing == [ ];
          message = ''
            nixvm: ${toString (builtins.length missing)} nixpkgs-only package(s) do not exist in
            this nixpkgs: ${lib.concatStringsSep ", " (map (t: t.nixpkgs) missing)}.

            These are entries with no Arch source at all, so nixpkgs is the only channel left for
            them on this plane and there is nothing to fall back to. This is a catalogue problem,
            not a host problem -- fix lib/toolchain.nix so every host gets the correction, rather
            than pinning an older nixpkgs or omitting the entry on one machine.
          '';
        }
      ];

      # `/usr/bin/virsh` rather than a store path: on this plane libvirt comes from the distro,
      # and the reconciler that installed it puts its binaries exactly there. A nix-provided
      # `virsh` would be a SECOND libvirt client talking to the distro daemon over a socket whose
      # path the two builds need not agree on.
      systemd.services = pools.mkPoolUnits {
        virsh = "/usr/bin/virsh";
        pools = cfg.storagePools;
      };

      warnings = lib.optional (zvolBackedPools != [ ])
        ''
          nixvm.host.storagePools.{${lib.concatStringsSep ", " zvolBackedPools}} set zvolBacked =
          true, but this is the system-manager plane, which has no `fileSystems` option for the
          "nossd" check to read. The check has NOT run. The hazard is real regardless of which
          configuration system is in charge -- see docs/gotchas.md -- so verify by hand that the
          btrfs filesystem backing each of those pools is mounted with "nossd".
        '';
    })

    (lib.mkIf (cfg.remotes != { }) {
      # A distro libvirt is built with `--sysconfdir=/etc`, so /etc/libvirt/libvirt.conf is the
      # file it actually reads -- unlike the NixOS plane, where nixpkgs builds it with
      # `--sysconfdir=/var/lib` and this same content goes under /var (see ./nixos.nix).
      #
      # ⚠ THIS PATH IS OWNED BY THE DISTRO'S OWN libvirt PACKAGE, and managing it means the
      # package manager will write `libvirt.conf.pacnew` beside it on a future upgrade rather
      # than overwriting what is here. That is the ordinary, visible outcome for a config file a
      # configuration system has taken over, and it is why nothing is rendered at all unless
      # `remotes` is non-empty: a host that declares no remote never touches the file.
      environment.etc."libvirt/libvirt.conf".text = resolve.aliasFileText cfg.remotes;
    })
  ];
}
