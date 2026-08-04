# modules/vm-host/nixos.nix
#
# The NixOS backend: turns the neutral stance in ./vm-host.nix into `virtualisation.libvirtd`,
# a QEMU built for exactly the declared architectures, the optional tooling as
# `environment.systemPackages`, and the storage-pool apply units.
#
# This is also the only plane where the zvol/btrfs/`nossd` assertion can exist at all, because it
# reads `config.fileSystems` -- an option system-manager does not have. See ./arch.nix.
{ lib, config, pkgs, ... }:

let
  cfg = config.nixvm.host;
  resolve = import ../../lib/resolve.nix { inherit lib; };
  pools = import ../../lib/pools.nix { inherit lib; };

  # Mirrors nixpkgs' own `hostCpuOnly` branch exactly (pkgs/by-name/qe/qemu/package.nix): the
  # host's architecture, plus i386 on x86_64 because a 64-bit x86 host is expected to be able to
  # boot a 32-bit guest and QEMU splits those into two targets.
  nativeTargets =
    lib.optional pkgs.stdenv.hostPlatform.isx86_64 "i386-softmmu"
    ++ [ "${pkgs.stdenv.hostPlatform.qemuArch}-softmmu" ];

  # THE x86-ONLY ANSWER ON THIS PLANE, read from the CATALOGUE rather than spelled here: the
  # `daemon.qemu` row names `qemu_kvm` as this channel's x86-only QEMU, exactly as it names
  # `qemu-desktop` for the other one, and a backend that hard-coded its own answer would be a
  # second place for the two channels to disagree.
  #
  # Why that attribute and not `qemu`: the top-level `qemu` leaves `hostCpuTargets` at null, which
  # configures `--target-list` with EVERY target QEMU can build -- the nixpkgs equivalent of
  # Arch's `qemu-full`. `qemu_kvm` is precisely `qemu.override { hostCpuOnly = true; }`, i.e. the
  # host's own targets and nothing else, and it is an ordinary nixpkgs attribute, so it comes from
  # the binary cache.
  #
  # The non-empty case cannot reuse it: `hostCpuOnly` computes its own target list and offers no
  # way to add to it, so asking for named extras means passing `hostCpuTargets` directly, applied
  # to the SAME derivation the catalogue row's attribute is an override of. That produces a
  # derivation nothing upstream builds (different pname, different configure flags), so it
  # compiles locally -- stated in `foreignArchitectures`' own option doc, because a build that
  # takes twenty minutes should not be a surprise discovered at deploy time.
  cat = import ../../lib/toolchain.nix { };
  baseQemu = lib.getAttrFromPath (lib.splitString "." cat.daemon.qemu.nixpkgs) pkgs;

  qemuPackage =
    if cfg.foreignArchitectures == [ ]
    then baseQemu
    else baseQemu.override { hostCpuOnly = false; hostCpuTargets = lib.unique (nativeTargets ++ cfg.qemuTargets); };

  # `hasAttrByPath` alone is not enough and this is not hypothetical: nixpkgs carries attributes
  # that exist as a `throw`, so the path resolves while forcing the value raises. Only forcing
  # tells the truth, so the filter forces -- and the warning below reports what actually failed
  # rather than letting a bad catalogue row become an obscure eval error.
  resolvable = name:
    let
      r = builtins.tryEval (
        lib.hasAttrByPath (lib.splitString "." name) pkgs
        && builtins.seq (lib.getAttrFromPath (lib.splitString "." name) pkgs).outPath true
      );
    in
    r.success && r.value;

  wanted = cfg.nixpkgsPackages;
  usable = lib.filter resolvable wanted;
  broken = lib.filter (n: !(resolvable n)) wanted;

  # The pool gotcha, checked against this host's OWN declared filesystems. Only fires when the
  # pool says it is zvol-backed AND the filesystem is visible in the same evaluation AND it is
  # btrfs AND `nossd` is genuinely absent -- see docs/gotchas.md for why that combination and no
  # other.
  poolAssertions = lib.concatMap
    (name:
      let
        pool = cfg.storagePools.${name};
        fs = config.fileSystems.${pool.path} or null;
      in
      lib.optional (pool.zvolBacked && fs != null && fs.fsType == "btrfs" && !(lib.elem "nossd" fs.options))
        {
          assertion = false;
          message = ''
            nixvm.host.storagePools.${name}: marked zvolBacked = true, and the filesystem mounted
            at "${pool.path}" (fsType "btrfs") does not include the "nossd" mount option. A zvol
            reports itself as non-rotational regardless of what actually backs it, which makes
            btrfs apply its SSD-tuned heuristics on top of a device that is already doing its own
            copy-on-write allocation -- the exact combination that has bitten this operator
            before (see docs/gotchas.md). Add "nossd" to that filesystem's `options`.
          '';
        })
    (lib.attrNames cfg.storagePools);
in
{
  imports = [ ./vm-host.nix ];

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      virtualisation.libvirtd.enable = lib.mkDefault true;

      # `mkDefault` so a host with a genuine reason to pin its own QEMU still can, without having
      # to also stop using this module.
      virtualisation.libvirtd.qemu.package = lib.mkDefault qemuPackage;

      # Harmless if no guest ever asks for a TPM device (nixvm.guests.<name>.tpm.enable): an
      # unused emulator binary, nothing more. Turning it on here rather than per-guest keeps this
      # module the one place that owns "can libvirtd on this host do X at all".
      virtualisation.libvirtd.qemu.swtpm.enable = lib.mkDefault true;

      # The `tools` selection and nothing else. libvirt, its QEMU, swtpm and dnsmasq are already
      # delivered by `virtualisation.libvirtd` -- which is what `viaLibvirtd` marks in the
      # catalogue, and why `nixpkgsPackages` filters those rows out. Installing them here as well
      # would put a SECOND, differently-configured QEMU in the closure that libvirtd never execs
      # (it runs `virtualisation.libvirtd.qemu.package`) -- the same shadowing defect the Arch
      # backend avoids one plane over, for a different underlying reason.
      environment.systemPackages = map (n: lib.getAttrFromPath (lib.splitString "." n) pkgs) usable;

      warnings = lib.optional (broken != [ ])
        "nixvm: nixpkgs attribute missing or unbuildable for: ${lib.concatStringsSep ", " broken}. Fix lib/toolchain.nix rather than pinning around it.";

      assertions = poolAssertions;

      systemd.services = pools.mkPoolUnits {
        virsh = lib.getExe' config.virtualisation.libvirtd.package "virsh";
        pools = cfg.storagePools;
      };
    })

    (lib.mkIf (cfg.remotes != { }) {
      # NOT `environment.etc`. nixpkgs builds libvirt with `--sysconfdir=/var/lib`, so the client
      # config libvirt actually reads on this plane is /var/lib/libvirt/libvirt.conf -- a path
      # under /var, which is why the NixOS libvirtd module likewise copies its generated
      # `qemu.conf` there instead of into /etc. A file dropped at /etc/libvirt/libvirt.conf on
      # NixOS is read by nothing.
      #
      # `L+` replaces whatever is there, which is safe precisely because nothing else writes this
      # path: libvirtd-config.service copies only qemu.conf, network.conf and the shipped
      # network/nwfilter XML, and the libvirt package ships no libvirt.conf of its own.
      systemd.tmpfiles.rules = [
        "L+ /var/lib/libvirt/libvirt.conf - - - - ${pkgs.writeText "nixvm-libvirt.conf" (resolve.aliasFileText cfg.remotes)}"
      ];
    })
  ];
}
