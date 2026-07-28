# modules/vm-host/default.nix
#
# ONE declarative hypervisor stance per host: libvirt/QEMU/KVM enabled, the bridge guests
# attach to declared (never created), and optional file-backed storage pools declared
# (never created) and kept applied. This exists because "can this machine host a
# persistent VM at all" is a question every bare-metal host can ask independently of
# what k3s (nixk3s) or a plain workstation config (nixoffice) does on the same box --
# see the repo README for the full boundary against both.
#
# SCOPE -- what this module owns, so no knob has two managers:
#   OWNED : whether libvirtd runs at all (host.enable); the bridge interface guest
#           network devices attach to (host.bridge) -- a DECLARED fact about an
#           interface that already exists, never created here; optional file-backed
#           libvirt storage pools (host.storagePools.*) -- again declared and kept
#           applied via `virsh pool-define-as`/`pool-autostart`, never partitioned or
#           formatted here; and the zvol-backing-a-btrfs-pool assertion documented
#           below and in docs/gotchas.md.
#   NOT   : creating, partitioning, or formatting ANY disk, zvol, or filesystem --
#           every path this module reads (host.bridge, storagePools.<n>.path) must
#           already exist. That is a disk-layout tool's job, not this module's, the
#           same boundary nixboot draws around the ESP it declares but never creates.
#   NOT   : GPU passthrough. The host's GPU is shared platform hardware used by
#           other workloads; a VM cannot hold a device exclusively and still share
#           it. The guest this module was built for is reached over RDP, which
#           needs no GPU in the guest at all. No passthrough option exists in this
#           first cut, and none should be added without first re-litigating that a
#           VM can have exclusive claim on the card.
#   NOT   : per-guest resource/disk/network/firmware definitions -- that is
#           modules/guests, which this module composes alongside but never absorbs.
#           A host that only ever wants the hypervisor capability with no guests
#           defined yet can import this module alone.
{ lib, config, ... }:

let
  cfg = config.nixvm.host;

  poolType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = ''
          Absolute directory this file-backed storage pool serves disk images
          out of. NO DEFAULT -- which directory (and which filesystem/dataset
          backs it) is a fact about this specific host, never a value worth
          guessing.
        '';
      };

      autostart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether libvirt starts this pool automatically at libvirtd startup.";
      };

      zvolBacked = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Does `path` sit on a filesystem whose OWN backing block device is a
          ZFS zvol (e.g. a zvol formatted with a foreign filesystem and
          mounted at `path`, as opposed to a native ZFS dataset)? Set this to
          `true` so nixvm can check `path`'s `fileSystems` entry for the
          `nossd` mount option it needs -- see the "zvolBacked" assertion
          below and docs/gotchas.md for why. Leave `false` for a pool backed
          by a native ZFS dataset directly (no foreign filesystem, no zvol,
          nothing to assert), which is the common case.
        '';
      };
    };
  };
in
{
  options.nixvm.host = {
    enable = lib.mkEnableOption "a declarative libvirt/QEMU-KVM virtualization host";

    bridge = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "br0";
      description = ''
        Which existing host bridge interface do guest network devices attach
        to? NO DEFAULT: this module never creates a bridge (see the SCOPE
        block), and guessing a name like "br0" for a host that actually
        calls it something else silently strands every guest without
        network the moment `virsh define` runs. Set it to the bridge your
        own host networking config already brings up.

        Every guest in `nixvm.guests` attaches to this bridge unless it sets
        its own `network.bridge` override.
      '';
    };

    storagePools = lib.mkOption {
      type = lib.types.attrsOf poolType;
      default = { };
      description = ''
        Optional file-backed libvirt storage pools, for the SECONDARY guest
        disk mode (`nixvm.guests.<name>.disks.<dev>.sourceType = "file"`).
        The primary disk mode -- a zvol handed to a guest as a raw block
        device -- needs no pool at all; it is referenced directly by device
        path. Empty by default: a host with every guest disk zvol-backed
        declares none of these.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.libvirtd.enable = lib.mkDefault true;

    # Harmless if no guest ever asks for a TPM device (nixvm.guests.<name>.tpm.enable):
    # an unused emulator binary, nothing more. Turning it on here rather than per-guest
    # keeps this module the one place that owns "can libvirtd on this host do X at all".
    virtualisation.libvirtd.qemu.swtpm.enable = lib.mkDefault true;

    assertions = [
      {
        assertion = cfg.bridge != null;
        message = ''
          nixvm.host.bridge must be set -- there is no default (see the
          option doc). Set it to the name of the bridge interface this
          host's own network config already brings up; nixvm never creates
          one.
        '';
      }
    ] ++ lib.concatMap
      (name:
        let
          pool = cfg.storagePools.${name};
          fs = config.fileSystems.${pool.path} or null;
        in
        lib.optional (pool.zvolBacked && fs != null && fs.fsType == "btrfs" && !(lib.elem "nossd" fs.options))
          {
            assertion = false;
            message = ''
              nixvm.host.storagePools.${name}: marked zvolBacked = true, and
              the filesystem mounted at "${pool.path}" (fsType "btrfs") does
              not include the "nossd" mount option. A zvol reports
              itself as non-rotational regardless of what actually backs it,
              which makes btrfs apply its SSD-tuned heuristics on top of a
              device that is already doing its own copy-on-write allocation --
              the exact combination that has bitten this operator before (see
              docs/gotchas.md). Add "nossd" to that filesystem's `options`.
            '';
          })
      (lib.attrNames cfg.storagePools);

    systemd.services = lib.mapAttrs'
      (name: pool: {
        name = "nixvm-pool-${name}-apply";
        value = {
          description = "Declare and keep applied the nixvm storage pool '${name}'";
          after = [ "libvirtd.service" ];
          requires = [ "libvirtd.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          # Every step is idempotent and non-destructive: pool-define-as on an
          # already-defined pool of the same name updates the definition rather
          # than erroring, `|| true` covers "pool already started"/"already
          # autostarted" so a repeat run never fails the unit, and nothing here
          # ever touches a pool's CONTENTS -- only its libvirt-level definition.
          script = ''
            ${lib.getExe' config.virtualisation.libvirtd.package "virsh"} pool-define-as --name '${name}' dir --target '${pool.path}' || true
            ${lib.getExe' config.virtualisation.libvirtd.package "virsh"} pool-build '${name}' --overwrite || true
            ${lib.getExe' config.virtualisation.libvirtd.package "virsh"} pool-start '${name}' || true
            ${lib.getExe' config.virtualisation.libvirtd.package "virsh"} pool-autostart '${name}' ${if pool.autostart then "" else "--disable"}
          '';
        };
      })
      cfg.storagePools;
  };
}
