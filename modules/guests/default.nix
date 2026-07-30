# modules/guests/default.nix
#
# Guest VM DEFINITIONS, as data: `nixvm.guests.<name>` describes a persistent guest's
# cpu/memory/disks/network/firmware/autostart. This module owns rendering that data into
# a libvirt domain XML document and keeping it DECLARED (`virsh define`, `virsh
# autostart`) -- it never starts, stops, or otherwise touches a guest's running power
# state, the same "declare, don't force" discipline nixk3s's k3s-host applies to node
# labels and nixboot applies to Secure Boot enrollment.
#
# SCOPE -- what this module owns, so no knob has two managers:
#   OWNED : the per-guest resource/disk/network/firmware/tpm/graphics/autostart data
#           model; rendering it to a libvirt domain XML document (lib/domain-xml.nix);
#           keeping that definition applied via `virsh define` on every activation, and
#           keeping libvirt's own autostart flag in sync via `virsh autostart`.
#   NOT   : starting, stopping, rebooting, or migrating a guest. `virsh define` changes
#           what a guest WILL boot into next time it starts; it never touches a guest
#           that is already running. Powering a guest on or off is always an operator
#           action (`virsh start`/`virsh shutdown`/virt-manager) -- the same reasoning
#           this family applies everywhere else to anything that could interrupt a
#           running workload without warning.
#   NOT   : installer media. A first OS install commonly needs a cdrom device holding
#           an ISO; this first cut has no option surface for that. Attach one
#           out-of-band (`virsh attach-disk ... --type cdrom`, or virt-manager) for the
#           initial install, then detach it once the guest has its own boot disk.
#   NOT   : GPU passthrough -- see modules/vm-host's own SCOPE block; the same boundary
#           applies here, since it is guest device data that would otherwise live in
#           this file.
#   NOT   : the guest operating system's own configuration. Whatever runs inside the
#           guest (a Windows install, its own RDP setup, an office suite -- see
#           nixoffice) is invisible to this module. It hands libvirt a virtual
#           machine; what boots inside it is the guest's own concern entirely.
#
# ALWAYS COMPOSED WITH modules/vm-host. This module reads `config.nixvm.host.bridge`
# directly (as the fallback for a guest that doesn't set its own `network.bridge`) and
# asserts `config.nixvm.host.enable` -- a host that imports this module without also
# importing vm-host fails evaluation the moment `nixvm.guests` is non-empty, the same
# "required composition, never a silent dependency" contract nixboot's own CONTRACT.md
# states for the lanzaboote module (its behavior B12).
{ lib, config, ... }:

let
  cfg = config.nixvm.guests;
  domainXml = import ../../lib/domain-xml.nix { inherit lib; };

  diskType = lib.types.submodule {
    options = {
      sourceType = lib.mkOption {
        type = lib.types.enum [ "zvol" "file" ];
        default = "zvol";
        description = ''
          The PRIMARY storage mode is `"zvol"`: `source` names an existing zvol
          block device (e.g. `/dev/zvol/<pool>/<dataset>`), handed to the guest
          directly as a raw block device -- nixvm never creates the zvol itself;
          that is a ZFS-management step this module deliberately has no opinion
          on. `"file"` is the SECONDARY mode: `source` names a qcow2 file, and is
          the mode `nixvm.host.storagePools` exists to serve.
        '';
      };

      source = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          The zvol device path or qcow2 file path backing this disk (see
          `sourceType`). NO DEFAULT: which device or file backs a specific
          guest's specific disk is never a value worth guessing, and a wrong
          guess here is silent data loss waiting to happen.
        '';
      };

      bus = lib.mkOption {
        type = lib.types.enum [ "virtio" "sata" ];
        default = "virtio";
        description = "Guest-visible disk controller. virtio needs in-guest drivers (bundled by every mainstream Linux; Windows needs the virtio-win driver ISO attached once) but is materially faster; sata needs none.";
      };
    };
  };

  guestType = lib.types.submodule {
    options = {
      memoryMiB = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = ''
          How much RAM (MiB) this guest permanently claims from the host. NO
          DEFAULT: memory handed to a guest is memory the host's other
          workloads (and its own memory-pressure tuning) cannot use for as
          long as the guest is defined, on a host that is never running only
          this one VM -- a silently-guessed number is a resourcing decision
          made without the operator noticing it was made.
        '';
      };

      cpu.cores = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Static vCPU count. CPU is overcommittable far more forgivingly than RAM, so this carries an ordinary default unlike memoryMiB.";
      };

      cpu.model = lib.mkOption {
        type = lib.types.enum [ "host-passthrough" "host-model" ];
        default = "host-passthrough";
        description = ''
          `"host-passthrough"` (the default) exposes the full host CPU feature
          set to the guest -- the right choice for a guest that never needs to
          migrate to different hardware, which describes every guest this
          module can define (there is no live-migration target here: this
          repo hosts VMs on ONE persistent, hosted machine). `"host-model"`
          trades some of those features for a CPU description more likely to
          also exist on a different physical host, which only matters once
          migration is a real, planned capability.
        '';
      };

      firmware = lib.mkOption {
        type = lib.types.enum [ "bios" "uefi" ];
        default = "uefi";
        description = ''
          Which firmware the guest boots through. `"uefi"` uses QEMU's own
          bundled OVMF and is required by any guest OS that gates its install
          on it (Windows 11 being the concrete case this repo was built
          against). `"bios"` is legacy SeaBIOS, only for a guest OS old
          enough to need it. This is the GUEST's own firmware, running inside
          the VM -- entirely separate from how the HOST itself boots
          (nixboot's concern, a different machine's firmware entirely).
        '';
      };

      clockOffset = lib.mkOption {
        type = lib.types.enum [ "utc" "localtime" ];
        default = "localtime";
        description = ''
          What the emulated RTC presents as its epoch offset. Defaults here to
          `"localtime"` -- the OPPOSITE of libvirt's own upstream default of
          `"utc"` -- because Windows reads the hardware clock as local time by
          default and shows the wrong time for the rest of its uptime if the
          two disagree. A Linux guest expects `"utc"` and will show a clock
          offset by the host's own timezone if left at this module's default.
        '';
      };

      autostart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether libvirt powers this guest on automatically when the HOST boots. Off by default: a newly-declared guest should not silently start running before an operator has actually looked at it.";
      };

      tpm.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Attach an emulated TPM 2.0 device (swtpm, via nixvm.host's own swtpm.enable). Needed by any guest OS that gates its install or disk encryption on a TPM being present; harmless to leave off for a guest that doesn't care.";
      };

      graphics.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Attach a libvirt graphical console (VNC/SPICE). This is NOT the
          guest's ongoing remote-access story -- a guest reached over RDP (or
          any in-guest remote-access service) needs none of this once that
          service is configured. It exists for the window before that: seeing
          the guest's screen to install its OS and set up that in-guest
          service in the first place. Safe to leave on permanently as a
          fallback console; `listenAddress` keeps it off the network by
          default (see below).
        '';
      };

      graphics.type = lib.mkOption {
        type = lib.types.enum [ "vnc" "spice" ];
        default = "vnc";
        description = "Which libvirt graphics protocol to attach when graphics.enable is true.";
      };

      graphics.listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          Address the graphics protocol listens on. Loopback-only by default
          -- reaching it remotely is a host-access problem (an SSH tunnel, or
          whatever mechanism already reaches this host at all), not something
          this module should open a network listener for on its own say-so.
        '';
      };

      network.bridge = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Which host bridge this guest's network interface attaches to. `null`
          (the default) uses `nixvm.host.bridge` -- the whole point of a
          shared bridged-networking stance is that most guests don't need to
          say this at all. Override only for a guest that genuinely needs a
          DIFFERENT bridge than the host default (e.g. an isolated VLAN).
        '';
      };

      network.model = lib.mkOption {
        type = lib.types.enum [ "virtio" "e1000e" "rtl8139" ];
        default = "virtio";
        description = "Guest-visible NIC model. virtio needs in-guest drivers (bundled by every mainstream Linux; Windows needs the virtio-win driver ISO attached once) but is materially faster; e1000e/rtl8139 need none.";
      };

      network.macAddress = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$");
        default = null;
        description = ''
          Pin a MAC address for a stable DHCP lease across guest redefines.
          `null` lets libvirt assign one when the guest is first defined --
          fine for a guest whose IP doesn't need to be predictable, but note
          that re-defining an existing guest with this still unset is a
          libvirt-behavior detail this module does not control (whether it
          keeps the previously-assigned address or not); pin one explicitly
          if a stable lease actually matters.
        '';
      };

      disks = lib.mkOption {
        type = lib.types.attrsOf diskType;
        default = { };
        example = { vda = { source = "/dev/zvol/pool/example-guest"; }; };
        description = ''
          This guest's disks, keyed by the target device name libvirt exposes
          to the guest (`vda`, `vdb`, ...). Empty by default, but a guest with
          zero disks is asserted against below -- add at least one.
        '';
      };

      extraDomainXML = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = ''
          Escape hatch: raw XML appended inside this guest's `<devices>`
          element, for anything this module doesn't model as its own option
          (a second NIC, a passthrough USB device, a serial console, and so
          on all belong here until/unless they earn a dedicated option).
        '';
      };
    };
  };

  # EVAL SAFETY, same discipline as nixram's modules/default.nix: `memoryMiB`,
  # `network.bridge` and a disk's `source` all have NO safe default (see their
  # option docs), which means their value can legitimately be `null` while
  # NixOS is still forcing `config` on the way to `system.build.toplevel` --
  # well before, and independent of, whichever order `assertions` happens to
  # be checked in. Indexing any of them directly would raise a raw, unhelpful
  # Nix type error instead of this module's own friendly, guest-named
  # assertion below. So every render path goes through a safe fallback here;
  # the fallback values are never seen by a real user, because `assertions`
  # is what actually stops the build.
  effectiveMemoryMiB = guest: if guest.memoryMiB != null then guest.memoryMiB else 1;

  effectiveBridge = guest:
    if guest.network.bridge != null then guest.network.bridge
    else if config.nixvm.host.bridge != null then config.nixvm.host.bridge
    else "unset-bridge";

  effectiveDisks = guest: lib.mapAttrs
    (_: disk: disk // { source = if disk.source != null then disk.source else "/unset-disk-source"; })
    guest.disks;

  mkGuestXml = name: guest: domainXml.mkDomainXML {
    inherit name;
    guest = guest // {
      memoryMiB = effectiveMemoryMiB guest;
      disks = effectiveDisks guest;
    };
    bridge = effectiveBridge guest;
  };

  guestAssertions = lib.concatMap
    (name:
      let guest = cfg.${name}; in
      lib.optional (guest.memoryMiB == null) {
        assertion = false;
        message = "nixvm.guests.${name}.memoryMiB must be set -- there is no default (see the option doc); a guest's memory allocation is never a value worth guessing.";
      }
      ++ lib.optional (guest.disks == { }) {
        assertion = false;
        message = "nixvm.guests.${name} declares no disks -- add at least one entry to nixvm.guests.${name}.disks.";
      }
      ++ lib.concatMap
        (devName: lib.optional (guest.disks.${devName}.source == null) {
          assertion = false;
          message = "nixvm.guests.${name}.disks.${devName}.source must be set -- there is no default (see the option doc).";
        })
        (lib.attrNames guest.disks))
    (lib.attrNames cfg);
in
{
  options.nixvm.guests = lib.mkOption {
    type = lib.types.attrsOf guestType;
    default = { };
    description = ''
      Persistent guest VM definitions, one attrset key per guest name. Each
      guest renders to a libvirt domain XML document kept applied via
      `virsh define` -- see this file's own header for exactly what "kept
      applied" does and does not mean.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        assertion = config.nixvm.host.enable;
        message = ''
          nixvm.guests defines at least one guest, but nixvm.host.enable is
          false. A guest needs a host to run on -- import modules/vm-host
          alongside modules/guests and set nixvm.host.enable = true.
        '';
      }
    ] ++ guestAssertions;

    environment.etc = lib.mapAttrs'
      (name: guest: {
        name = "nixvm/guests/${name}.xml";
        value.text = mkGuestXml name guest;
      })
      cfg;

    systemd.services = lib.mapAttrs'
      (name: guest: {
        name = "nixvm-guest-${name}-apply";
        value = {
          description = "Declare and keep applied the nixvm guest '${name}'";
          after = [ "libvirtd.service" ];
          requires = [ "libvirtd.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          # `virsh define` only ever changes what this guest boots into NEXT
          # time it starts -- it never touches a guest that is currently
          # running (see this file's own SCOPE block). Setting autostart is
          # equally non-disruptive: it only affects behavior at the HOST's
          # next boot.
          script = ''
            ${lib.getExe' config.virtualisation.libvirtd.package "virsh"} define /etc/nixvm/guests/${name}.xml
            ${lib.getExe' config.virtualisation.libvirtd.package "virsh"} autostart ${if guest.autostart then "" else "--disable"} '${name}'
          '';
        };
      })
      cfg;
  };
}
