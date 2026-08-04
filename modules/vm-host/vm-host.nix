# modules/vm-host/vm-host.nix
#
# ONE declarative hypervisor stance per host, PLATFORM-NEUTRAL: what this machine may run as a
# guest, which tooling it carries, which remote libvirtd instances it knows how to reach, the
# bridge guests attach to, and optional file-backed storage pools. This file declares and
# resolves; it installs nothing and touches no plane-specific option. `./nixos.nix` and
# `./arch.nix` are the two backends that do.
#
# WHY A NEUTRAL POLICY FILE AT ALL. "Can this machine host a VM" is a question a NixOS server and
# an Arch laptop ask identically, and the answer they need is the same answer -- but they have no
# option in common to express it with. NixOS has `virtualisation.libvirtd`; system-manager has no
# `virtualisation` namespace of any kind, no `boot.kernelModules`, and no `fileSystems`. Writing
# the policy once here and the delivery twice is what keeps a laptop from being a hand-copy of
# the server with the NixOS-only lines deleted.
#
# SCOPE -- what this module owns, so no knob has two managers:
#   OWNED : whether this host is a hypervisor at all (`host.enable`); which guest architectures
#           it can run (`host.foreignArchitectures` -- see that option for why the default is
#           the host's own and nothing else); which optional tooling it carries (`host.tools`);
#           which REMOTE libvirtd instances it can address by name (`host.remotes`); the bridge
#           guest network devices attach to (`host.bridge`) -- a DECLARED fact about an interface
#           that already exists, never created here; and optional file-backed libvirt storage
#           pools (`host.storagePools.*`) -- again declared and kept applied, never partitioned
#           or formatted here.
#   NOT   : creating, partitioning, or formatting ANY disk, zvol, or filesystem -- every path
#           this module reads (host.bridge, storagePools.<n>.path) must already exist. That is a
#           disk-layout tool's job, the same boundary nixboot draws around the ESP it declares
#           but never creates.
#   NOT   : GPU passthrough. The host's GPU is shared platform hardware used by other workloads;
#           a VM cannot hold a device exclusively and still share it. No passthrough option
#           exists, and none should be added without first re-litigating that a VM can have
#           exclusive claim on the card.
#   NOT   : per-guest resource/disk/network/firmware definitions -- that is modules/guests, which
#           this module composes alongside but never absorbs. A host that only wants the
#           hypervisor capability with no guests defined yet imports this module alone, which is
#           exactly the Arch-laptop shape (modules/guests is NixOS-only -- see ./arch.nix).
{ lib, config, ... }:

let
  cfg = config.nixvm.host;
  cat = import ../../lib/toolchain.nix { };
  resolve = import ../../lib/resolve.nix { inherit lib; };

  # Each resolved entry carries the catalogue KEY it was selected by, so anything reporting about
  # a selection has an identity to report it BY that does not depend on which delivery channels
  # that particular entry happens to have.
  withName = keys: table: map (k: table.${k} // { name = k; }) keys;

  selectedTools = withName cfg.tools cat.tools;
  selectedDaemon = withName (lib.attrNames cat.daemon) cat.daemon;
  selectedArches = withName cfg.foreignArchitectures cat.architectures;

  # The daemon stance and the selected tooling resolve together: they are one package set from
  # the reconciler's point of view, and separating them would only invite a consumer to wire one
  # and forget the other.
  allSelected = selectedDaemon ++ selectedTools ++ selectedArches;

  poolType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = ''
          Absolute directory this file-backed storage pool serves disk images out of. NO DEFAULT
          -- which directory (and which filesystem/dataset backs it) is a fact about this
          specific host, never a value worth guessing.
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
          Does `path` sit on a filesystem whose OWN backing block device is a ZFS zvol (e.g. a
          zvol formatted with a foreign filesystem and mounted at `path`, as opposed to a native
          ZFS dataset)? Set this to `true` so nixvm can check `path`'s `fileSystems` entry for
          the `nossd` mount option it needs -- see docs/gotchas.md. Leave `false` for a pool
          backed by a native ZFS dataset directly, which is the common case.

          ⚠ THE CHECK ONLY EXISTS ON THE NixOS PLANE. system-manager has no `fileSystems` option
          at all, so there is nothing for the assertion to read there; ./arch.nix warns rather
          than pretending to have checked. The gotcha itself is just as real on that plane -- it
          is a property of the zvol and the filesystem on top of it, not of the configuration
          system -- so on a distro host verify the mount option by hand.
        '';
      };
    };
  };

  remoteType = lib.types.submodule ({ name, ... }: {
    options.uri = lib.mkOption {
      type = lib.types.str;
      example = "qemu+ssh://root@vmhost.example/system";
      description = ''
        The libvirt connection URI this alias resolves to. NO DEFAULT: which host, which
        transport and which user is a deployment fact, and this repo is public -- a guessed
        default here would either be wrong or would be someone's hostname.

        Reaching a remote libvirtd needs NO extra package on either end. The client side is
        `virsh`/`virt-manager`, which the `enable` stance and `tools` already provide; the
        `qemu+ssh://` transport is an ordinary SSH connection that runs `virt-ssh-helper` on the
        REMOTE, and that binary ships inside libvirt itself on both planes. So this is
        configuration, not installation -- which is why it is a URI here and not a package list.
      '';
    };
  });
in
{
  options.nixvm.host = {
    enable = lib.mkEnableOption ''
      a declarative libvirt/QEMU-KVM virtualization host. Brings the daemon, an x86-64-only QEMU
      (see `foreignArchitectures`), the TPM emulator and libvirt's own NAT-network dependency --
      the set below which "this machine can host a VM" is not true
    '';

    foreignArchitectures = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames cat.architectures));
      default = [ ];
      example = [ "aarch64" ];
      description = ''
        Guest architectures OTHER than this host's own that QEMU should be able to emulate.
        Empty by default, which means: this host runs guests of its own architecture, with KVM,
        and nothing else.

        THE DEFAULT IS THE POINT. A host's own architecture runs under hardware virtualization
        and is what anyone means by "a VM"; every other architecture runs under pure software
        emulation (TCG), at a small fraction of the speed, and is a genuinely different activity
        -- bringing up firmware for a board you do not own, or reproducing an architecture-
        specific bug. Both planes make the full set easy to acquire by accident and expensive to
        carry: on Arch the obvious `qemu-full` pulls `qemu-emulators-full` and lands roughly 600
        MiB of emulators and firmware, of which the x86 one is under a tenth; in nixpkgs the
        top-level `qemu` builds every target for the same reason. So the module asks for the
        extras by name instead of shipping them by default.

        Opting in is per-architecture, and the catalogue key names the family rather than a
        single QEMU target -- `riscv` covers riscv32 and riscv64, `ppc` covers ppc and ppc64 --
        because that is how the packaging actually groups them (see lib/toolchain.nix).

        ⚠ ON NixOS, A NON-EMPTY LIST COSTS A QEMU SOURCE BUILD. The empty default resolves to
        `pkgs.qemu_kvm`, an ordinary nixpkgs attribute with a binary cache behind it. Any
        selection here becomes a `hostCpuTargets` override, which is a different derivation than
        anything upstream builds, so it compiles locally. That is the honest price of asking for
        exactly the targets you named rather than all of them; see ./nixos.nix.
      '';
    };

    tools = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames cat.tools));
      default = [ ];
      example = [ "manager" "viewer" "images" "cloudInit" ];
      description = ''
        Optional virtualisation tooling to install. Available: ${lib.concatStringsSep ", " (lib.attrNames cat.tools)}
        -- see lib/toolchain.nix for what each one is and why it is a separate entry.

        Empty by default rather than "the obvious set", because the obvious set is different for
        a headless server driven entirely over `virsh` and for a laptop somebody sits in front
        of, and this module has no way to tell which it is on.
      '';
    };

    bridge = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "br0";
      description = ''
        Which existing host bridge do guest network devices attach to by default? NO DEFAULT:
        this module never creates a bridge (see the SCOPE block), and guessing a name like "br0"
        for a host that calls it something else silently strands every guest without network the
        moment `virsh define` runs.

        `null` is a legitimate, complete configuration and NOT an omission -- it is the correct
        answer for a host that has no bridge to offer, which is every laptop on wireless. Such a
        host still hosts guests; they attach to libvirt's own default NAT network instead, which
        is what `daemon.dnsmasq` in the catalogue exists to make work. What `null` does forbid is
        a DECLARED guest (`nixvm.guests.<name>`) that names no bridge of its own -- modules/
        guests asserts on exactly that, naming the guest, because that combination would render
        a domain document with an empty bridge name.
      '';
    };

    remotes = lib.mkOption {
      type = lib.types.attrsOf remoteType;
      default = { };
      example = { vmhost.uri = "qemu+ssh://root@vmhost.example/system"; };
      description = ''
        Remote libvirtd instances this host can address by a short name, rendered as libvirt's
        own `uri_aliases` so `virsh -c <name>`, virt-manager and virt-viewer all resolve the same
        alias from one declaration.

        Independent of `enable`: driving someone else's hypervisor and being one are different
        capabilities, and a host may legitimately want either without the other.

        The alias name must match `[a-zA-Z0-9_-]+`. libvirt does not reject a name outside that
        set -- it stops reading at the first foreign character and silently resolves a prefix --
        so this module asserts instead of letting that become a debugging session.
      '';
    };

    storagePools = lib.mkOption {
      type = lib.types.attrsOf poolType;
      default = { };
      description = ''
        Optional file-backed libvirt storage pools, for the SECONDARY guest disk mode
        (`nixvm.guests.<name>.disks.<dev>.sourceType = "file"`). The primary disk mode -- a zvol
        handed to a guest as a raw block device -- needs no pool at all; it is referenced
        directly by device path. Empty by default: a host with every guest disk zvol-backed
        declares none of these.
      '';
    };

    # ── Resolved outputs: what a backend, or a consumer's own reconciler, actually consumes ────

    want = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      internal = true;
      description = "Resolved catalogue entries; the contract a platform backend consumes.";
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The stance as pacman names, for the host's own reconciler:

          nixarch.packages.pacman = config.nixvm.host.archPackages;

        Empty when `enable` is false. This module installs nothing on a distro plane -- there is
        no installer for it to call -- so publishing the list and letting the consumer connect it
        is the whole of the Arch contract.
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that live in the AUR rather than an official repo, kept SEPARATE because
        `pacman -S` cannot resolve them -- it fails the whole transaction with "target not
        found", which takes the rest of the converge down with it. Wire them to the AUR side:

          nixarch.packages.aur = config.nixvm.host.aurPackages;

        Empty for every selection this catalogue currently offers; the split exists so that the
        first entry that needs it cannot break a converge on the way in.
      '';
    };

    nixpkgsPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The stance as nixpkgs attribute names. Consumed by ./nixos.nix; exposed rather than kept
        internal so a consumer can see what the stance resolves to without building a system.

        Shorter than `archPackages` on purpose: entries whose catalogue row carries
        `nixpkgs = null` are delivered on NixOS by `virtualisation.libvirtd` itself rather than
        by a package list -- see lib/toolchain.nix's header.
      '';
    };

    qemuTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "QEMU `--target-list=` entries the selected foreign architectures imply, excluding the host's own (which the backend adds, since only it knows the host platform).";
    };
  };

  config = {
    nixvm.host.want = if cfg.enable then allSelected else [ ];
    nixvm.host.archPackages = resolve.archPackages config.nixvm.host.want;
    nixvm.host.aurPackages = resolve.aurPackages config.nixvm.host.want;
    nixvm.host.nixpkgsPackages = resolve.nixpkgsNames config.nixvm.host.want;
    nixvm.host.qemuTargets = resolve.qemuTargets [ ] selectedArches;

    assertions =
      # Plane-neutral only. Anything that needs to read `fileSystems`, `pkgs`, or a NixOS option
      # lives in ./nixos.nix -- an assertion this file cannot evaluate on both planes is an
      # assertion that would make the Arch backend fail to evaluate at all.
      lib.concatMap
        (name: lib.optional (!(resolve.aliasNameOk name)) {
          assertion = false;
          message = ''
            nixvm.host.remotes.${name}: an alias name must match [a-zA-Z0-9_-]+. libvirt does not
            reject a name outside that set -- it reads up to the first foreign character and
            resolves whatever prefix it found, so "${name}" would silently address the wrong
            thing (or nothing) with no error to search for. Rename the alias.
          '';
        })
        (lib.attrNames cfg.remotes)
      ++ lib.concatMap
        (name: lib.optional (!(resolve.uriOk cfg.remotes.${name}.uri)) {
          assertion = false;
          message = ''
            nixvm.host.remotes.${name}.uri contains a double quote or a newline. Neither can
            appear in a legal libvirt connection URI, and either one would end the entry early in
            the generated uri_aliases file -- producing a config libvirt parses differently than
            it reads here.
          '';
        })
        (lib.attrNames cfg.remotes);
  };
}
