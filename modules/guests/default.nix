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

  # EVAL SAFETY, same discipline as nixlxc's own modules/containers: `network.bridge` and a
  # disk's `source` have NO safe default at all (see their option docs); the guest's memory
  # ceiling (sourced from nixhost, see below) can likewise legitimately resolve to nothing. All
  # of these can be `null` while NixOS is still forcing `config` on the way to
  # `system.build.toplevel` -- well before, and independent of, whichever order `assertions`
  # happens to be checked in. Indexing any of them directly would raise a raw, unhelpful Nix
  # type error instead of this module's own friendly, guest-named assertion below. So every
  # render path goes through a safe fallback here; the fallback values are never seen by a real
  # user, because `assertions` is what actually stops the build.
  effectiveBridge = guest:
    if guest.network.bridge != null then guest.network.bridge
    else if config.nixvm.host.bridge != null then config.nixvm.host.bridge
    else "unset-bridge";

  effectiveDisks = guest: lib.mapAttrs
    (_: disk: disk // { source = if disk.source != null then disk.source else "/unset-disk-source"; })
    guest.disks;

  # ── The resource envelope is NOT declared here. It is read from nixhost. ──────────────────
  #
  # An earlier draft of this module declared `memoryMiB` (required, no default) and `cpu.cores`
  # (default 2) of its own. That is a fact with two owners: `nixhost` already declares
  # `environments.<name>.resources.ram.limitMiB` and `.cpu.quotaCores`, and it owns the only
  # arithmetic nothing else can do -- summing every environment's claim at each level of the
  # tree and refusing to evaluate when a node's children claim more than that node has.
  #
  # A second ceiling here does not merely duplicate; it DISARMS that check. nixhost would go on
  # summing numbers nobody rendered while this module rendered different ones, which is worse
  # than having no assertion at all, because it reads as coverage. nixhost's own substrate
  # contract states the rule: a substrate must not declare a second resource envelope.
  #
  # Matched BY NAME: `nixvm.guests.<name>` reads `nixhost.environments.<name>.resources`. Read
  # defensively (`config.nixhost.environments or { }`) and never as a flake input, so this
  # module's own assertions still get constructed -- cleanly, never a raw Nix crash -- on a host
  # that has never imported nixhost at all.
  #
  # ⚠ MEMORY IS NOT THE SAME SHAPE AS nixlxc's IDENTICAL-LOOKING CEILING. nixlxc's cgroup2
  # memory ceiling can be silently absent -- "no cgroup limit at all" is a real, valid liblxc
  # state, so nixlxc renders nothing and evaluation proceeds. A libvirt domain has no
  # equivalent, and this was checked empirically against the real libvirt XML parser rather than
  # assumed: `virsh define` (against the `test:///default` driver, no running libvirtd needed) on
  # a domain document with no `<vcpu>` element succeeds fine -- libvirt applies its own upstream
  # default (a single vCPU) -- but the identical domain with no `<memory>` element is REFUSED
  # outright: "error: XML error: Memory size must be specified via <memory> or in the <numa>
  # configuration". So the two ceilings this module reads from nixhost diverge on what "absent"
  # renders as:
  #   - `resources.ram.limitMiB` absent (nixhost not imported, this guest not declared in it, or
  #     declared without a limit) is a BUILD ERROR naming the missing option --
  #     `memoryRequiredAssertions` below -- never a guessed number, and never a domain XML
  #     document libvirt would refuse to define at apply time.
  #   - `resources.cpu.quotaCores` absent means the `<vcpu>` element is omitted entirely, which
  #     genuinely IS "no ceiling" here: libvirt's own upstream default applies, not a number this
  #     module invented.
  #   `quotaCores` may be fractional (nixhost's own type allows it -- a cgroup quota of 1.5 cores
  #   is a real shape for other substrates); a libvirt `<vcpu>` count cannot be fractional, so a
  #   fractional ceiling is rounded UP to the smallest whole vCPU count that can deliver at least
  #   that much capacity. This module does not also throttle the guest to the exact fractional
  #   figure via a `<cputune>` quota/period pair -- flagged here as a known gap, not silently
  #   decided.
  hostEnvs = config.nixhost.environments or { };
  envelopeFor = name: (hostEnvs.${name} or { }).resources or null;

  memoryEnvelopeMissing = name: let e = envelopeFor name; in e == null || e.ram.limitMiB == null;

  effectiveMemoryMiB = name:
    let e = envelopeFor name; in
    # Eval-safety placeholder only -- see the comment above `effectiveBridge`. Never seen by a
    # real user: `memoryRequiredAssertions` below is what actually stops the build whenever
    # `memoryEnvelopeMissing name` is true.
    if !(memoryEnvelopeMissing name) then e.ram.limitMiB else 1;

  effectiveCpuQuotaCores = name:
    let e = envelopeFor name; in if e == null then null else e.cpu.quotaCores;

  effectiveVcpuCount = name:
    let q = effectiveCpuQuotaCores name; in
    if q == null then null else builtins.ceil (q * 1.0);

  mkGuestXml = name: guest: domainXml.mkDomainXML {
    inherit name;
    guest = guest // {
      memoryMiB = effectiveMemoryMiB name;
      disks = effectiveDisks guest;
      cpu = guest.cpu // { cores = effectiveVcpuCount name; };
    };
    bridge = effectiveBridge guest;
  };

  guestAssertions = lib.concatMap
    (name:
      let guest = cfg.${name}; in
      lib.optional (guest.disks == { }) {
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

  # ── memory: ALWAYS required to resolve, present or not -- see the header block above for why
  # this is the one ceiling with no safe "render nothing" fallback.
  memoryRequiredAssertions = lib.concatMap
    (name:
      lib.optional (memoryEnvelopeMissing name) {
        assertion = false;
        message = ''
          nixvm.guests.${name} has no RAM ceiling: nixhost.environments.${name}.resources.ram.limitMiB
          is not set (or nixhost is not imported into this configuration at all). A libvirt
          domain has no equivalent of "run unbounded" the way an LXC container or a podman
          container can -- proven empirically against the real libvirt XML parser (`virsh
          define` against the `test:///default` driver): a domain document with no `<memory>`
          element is refused outright ("Memory size must be specified via <memory> or in the
          <numa> configuration"), never merely under-specified. So unlike nixlxc's
          identical-looking cgroup ceiling (silently absent means unbounded), this one has no
          safe "render nothing" fallback -- set
          nixhost.environments.${name}.resources.ram.limitMiB, either by importing nixhost
          alongside this module or by declaring the environment if nixhost is already imported.
        '';
      })
    (lib.attrNames cfg);

  # ── Cross-check against nixhost: the two declarations must agree on WHAT this is ───────────
  #
  # `nixvm.guests.foo` and `nixhost.environments.foo` describe the same object from two sides --
  # the substrate that builds it and the host that budgets for it. If nixhost has been told that
  # `foo` is, say, an lxc container while this module is building it as a libvirt VM, one of
  # those is wrong, and the consequence is not cosmetic: nixhost's envelope arithmetic would be
  # budgeting for the wrong KIND of thing, and this module would silently read a ceiling meant
  # for something else.
  #
  # Only checked when nixhost actually declares that name -- a guest with no corresponding
  # environment is the ordinary un-adopted case (caught instead by `memoryRequiredAssertions`
  # above), not this check's concern.
  #
  # `or null` alone is not enough here, unlike every other defensive read in this file: the real
  # nixhost's own `kind` option carries NO default (see its own description -- deliberately, an
  # environment nixhost "cannot classify" is one whose resource claims cannot be reasoned about
  # at all). So a real deployment that declares `nixhost.environments.<name>` for its RAM/CPU
  # envelope but genuinely forgets `kind` does not make `.kind` resolve to `null` the way a truly
  # ABSENT environment does -- it makes reading `.kind` raise NixOS's own "option ... was
  # accessed but has no value defined" error, which `or` does NOT catch (that idiom only catches
  # a missing ATTRIBUTE, not an arbitrary `throw` raised while computing one that exists but was
  # never given a value). `builtins.tryEval` is what actually catches it, so an environment
  # declared without `kind` is treated the same as one not declared at all for THIS check --
  # never a raw crash -- while `memoryRequiredAssertions` above still fires on its own terms if
  # that same half-declared environment also left `ram.limitMiB` unset.
  declaredKind = name:
    let r = builtins.tryEval ((hostEnvs.${name} or { }).kind or null); in
    if r.success then r.value else null;

  kindAssertions = lib.concatMap
    (name:
      let declared = declaredKind name; in
      lib.optional (declared != null && declared != "vm") {
        assertion = false;
        message = "nixvm.guests.${name} builds a libvirt VM, but nixhost.environments.${name}.kind = \"${declared}\". The same name is declared as two different kinds of thing: nixhost is budgeting an envelope for a ${declared} while this module defines a VM domain against it. Rename one, or correct the kind.";
      })
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
    ] ++ guestAssertions ++ memoryRequiredAssertions ++ kindAssertions;

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
