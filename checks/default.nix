# checks/default.nix
#
# Two kinds of check, cheapest first:
#
#   1. "xml-render/*" -- pure unit tests against lib/domain-xml.nix directly. No NixOS
#      eval at all: hand-built plain-value fixtures in, a string out, substring
#      assertions on the result. This is the whole reason that file is `lib`-only
#      rather than living inside modules/guests -- see its own header.
#
#   2. Everything else -- EVAL-TIME tests through real `nixosSystem` composition
#      (mirroring nixk3s's own checks/flake.nix): does a host importing modules/vm-host
#      (and modules/guests) evaluate at all, does the rendered domain XML/systemd
#      service actually contain what the guest declared, and -- the failing direction,
#      proven as deliberately as the passing one -- does a guest missing a required
#      field, or a host missing its required bridge, fail evaluation BY NAME rather
#      than silently produce something half-formed.
#
# Nothing here builds a VM, starts libvirtd, or runs a single line of the rendered
# script. That is exactly the boundary this repo exists to keep: nixvm declares and
# renders, `nix flake check` proves the declaring and rendering, and nothing more.
{ pkgs, lib, system, vmHostModule, guestsModule }:

let
  domainXml = import ../lib/domain-xml.nix { inherit lib; };

  check = name: ok: detail: { inherit name ok detail; };

  # ── Stubs every fixture below needs to reach system.build.toplevel ──────────────────
  bootStub = {
    fileSystems."/" = { device = "nodev"; fsType = "tmpfs"; };
    boot.loader.grub = { enable = true; devices = [ "nodev" ]; };
    networking.hostName = "example-vm-host";
    system.stateVersion = "25.05";
  };

  evalNixos = extraConfig:
    (lib.nixosSystem {
      inherit system;
      modules = [ vmHostModule guestsModule extraConfig bootStub ];
    }).config;

  # Mirrors nixfs's own `nixosBuildFails`: forcing `system.build.toplevel` is what
  # actually runs `assertions` (a bare read of `.config.assertions` is a passive list
  # nobody enforced yet). `seq` reaches the wrapping throw without deep-forcing, or
  # building, the whole system closure; the string context is discarded so this stays
  # an EVAL check, never a build.
  buildFails = extraConfig:
    !(builtins.tryEval (builtins.seq
      (builtins.unsafeDiscardStringContext (evalNixos extraConfig).system.build.toplevel.drvPath)
      true)).success;

  # ── Fixtures ─────────────────────────────────────────────────────────────────────
  cfg-host-only = evalNixos {
    nixvm.host = { enable = true; bridge = "examplebr0"; };
  };

  cfg-one-guest = evalNixos {
    nixvm.host = { enable = true; bridge = "examplebr0"; };
    nixvm.guests.example-guest = {
      memoryMiB = 8192;
      cpu.cores = 4;
      disks.vda.source = "/dev/zvol/pool/example-guest";
    };
  };

  cfg-guest-own-bridge = evalNixos {
    nixvm.host = { enable = true; bridge = "examplebr0"; };
    nixvm.guests.example-guest = {
      memoryMiB = 2048;
      network.bridge = "otherbr0";
      disks.vda.source = "/dev/zvol/pool/example-guest";
    };
  };

  cfg-guest-autostart = evalNixos {
    nixvm.host = { enable = true; bridge = "examplebr0"; };
    nixvm.guests.example-guest = {
      memoryMiB = 2048;
      autostart = true;
      disks.vda.source = "/dev/zvol/pool/example-guest";
    };
  };

  cfg-storage-pool = evalNixos {
    nixvm.host = {
      enable = true;
      bridge = "examplebr0";
      storagePools.file-backed = { path = "/var/lib/libvirt/pools/file-backed"; autostart = false; };
    };
  };

  # zvolBacked pool whose declared `fileSystems` entry already carries "nossd" -- the
  # passing direction for the known gotcha.
  cfg-zvol-pool-ok = evalNixos {
    nixvm.host = {
      enable = true;
      bridge = "examplebr0";
      storagePools.on-zvol = { path = "/mnt/zvol-pool"; zvolBacked = true; };
    };
    fileSystems."/mnt/zvol-pool" = { device = "/dev/zvol/pool/dataset"; fsType = "btrfs"; options = [ "nossd" ]; };
  };

  results = [
    # --- host-only composes -------------------------------------------------------
    (check "host-only/toplevel-evaluates"
      (builtins.tryEval (builtins.seq (builtins.unsafeDiscardStringContext cfg-host-only.system.build.toplevel.drvPath) true)).success
      "expected a host with nixvm.host.enable + bridge set to evaluate cleanly")

    (check "host-only/libvirtd-enabled"
      cfg-host-only.virtualisation.libvirtd.enable
      "got: ${builtins.toJSON cfg-host-only.virtualisation.libvirtd.enable}")

    (check "host-only/swtpm-enabled-by-default"
      cfg-host-only.virtualisation.libvirtd.qemu.swtpm.enable
      "got: ${builtins.toJSON cfg-host-only.virtualisation.libvirtd.qemu.swtpm.enable}")

    (check "host-only/no-guest-apply-services"
      (!(lib.any (n: lib.hasPrefix "nixvm-guest-" n) (lib.attrNames cfg-host-only.systemd.services)))
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfg-host-only.systemd.services)}")

    # --- host-bridge-required (failing direction) ---------------------------------
    (check "host-bridge-required/fails-when-unset"
      (buildFails { nixvm.host.enable = true; })
      "expected nixvm.host.enable with no bridge set to fail evaluation, but it succeeded")

    # --- guests-need-a-host (failing direction) ------------------------------------
    (check "guests-need-a-host/fails-when-host-disabled"
      (buildFails {
        nixvm.host.bridge = "examplebr0";
        nixvm.guests.orphan = {
          memoryMiB = 1024;
          disks.vda.source = "/dev/zvol/pool/orphan";
        };
      })
      "expected a guest defined with nixvm.host.enable = false (its own default) to fail evaluation, but it succeeded")

    # --- guest required fields (failing direction, each named) ---------------------
    (check "guest-required/memoryMiB-unset-fails"
      (buildFails {
        nixvm.host = { enable = true; bridge = "examplebr0"; };
        nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
      })
      "expected a guest with no memoryMiB to fail evaluation, but it succeeded")

    (check "guest-required/no-disks-fails"
      (buildFails {
        nixvm.host = { enable = true; bridge = "examplebr0"; };
        nixvm.guests.example-guest.memoryMiB = 2048;
      })
      "expected a guest with zero disks to fail evaluation, but it succeeded")

    (check "guest-required/disk-source-unset-fails"
      (buildFails {
        nixvm.host = { enable = true; bridge = "examplebr0"; };
        nixvm.guests.example-guest = {
          memoryMiB = 2048;
          disks.vda = { };
        };
      })
      "expected a disk with no source to fail evaluation, but it succeeded")

    # --- the passing guest composes and renders correctly --------------------------
    (check "one-guest/toplevel-evaluates"
      (builtins.tryEval (builtins.seq (builtins.unsafeDiscardStringContext cfg-one-guest.system.build.toplevel.drvPath) true)).success
      "expected a fully-specified guest to evaluate cleanly")

    (check "one-guest/xml-rendered-to-etc"
      (cfg-one-guest.environment.etc ? "nixvm/guests/example-guest.xml")
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames cfg-one-guest.environment.etc)}")

    (check "one-guest/xml-contains-memory"
      (lib.hasInfix "<memory unit='MiB'>8192</memory>" cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text)
      "text: ${cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text}")

    (check "one-guest/xml-contains-vcpu"
      (lib.hasInfix "<vcpu placement='static'>4</vcpu>" cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text)
      "text: ${cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text}")

    (check "one-guest/xml-contains-disk-source"
      (lib.hasInfix "/dev/zvol/pool/example-guest" cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text)
      "text: ${cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text}")

    (check "one-guest/xml-uses-host-bridge-by-default"
      (lib.hasInfix "<source bridge='examplebr0'/>" cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text)
      "text: ${cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text}")

    (check "one-guest/xml-defaults-to-uefi-firmware"
      (lib.hasInfix "<os firmware='efi'>" cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text)
      "text: ${cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text}")

    (check "one-guest/xml-defaults-to-localtime-clock"
      (lib.hasInfix "<clock offset='localtime'/>" cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text)
      "text: ${cfg-one-guest.environment.etc."nixvm/guests/example-guest.xml".text}")

    (check "one-guest/apply-service-defines-and-disables-autostart-by-default"
      (
        let script = cfg-one-guest.systemd.services."nixvm-guest-example-guest-apply".script;
        in lib.hasInfix "virsh define /etc/nixvm/guests/example-guest.xml" script
          && lib.hasInfix "autostart --disable 'example-guest'" script
      )
      "script: ${cfg-one-guest.systemd.services."nixvm-guest-example-guest-apply".script}")

    (check "one-guest/apply-service-wanted-by-multi-user"
      (lib.elem "multi-user.target" cfg-one-guest.systemd.services."nixvm-guest-example-guest-apply".wantedBy)
      "wantedBy: ${builtins.toJSON cfg-one-guest.systemd.services."nixvm-guest-example-guest-apply".wantedBy}")

    # --- guest network.bridge override wins over the host default ------------------
    (check "guest-own-bridge/xml-uses-guest-override-not-host-default"
      (lib.hasInfix "<source bridge='otherbr0'/>" cfg-guest-own-bridge.environment.etc."nixvm/guests/example-guest.xml".text)
      "text: ${cfg-guest-own-bridge.environment.etc."nixvm/guests/example-guest.xml".text}")

    # --- autostart = true reaches the apply service without --disable -------------
    (check "guest-autostart/apply-service-omits-disable-flag"
      (
        let script = cfg-guest-autostart.systemd.services."nixvm-guest-example-guest-apply".script;
        in lib.hasInfix "autostart  'example-guest'" script
      )
      "script: ${cfg-guest-autostart.systemd.services."nixvm-guest-example-guest-apply".script}")

    # --- storage pools render an idempotent apply service ---------------------------
    (check "storage-pool/apply-service-rendered"
      (cfg-storage-pool.systemd.services ? "nixvm-pool-file-backed-apply")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfg-storage-pool.systemd.services)}")

    (check "storage-pool/apply-service-uses-declared-path"
      (lib.hasInfix "--target '/var/lib/libvirt/pools/file-backed'"
        cfg-storage-pool.systemd.services."nixvm-pool-file-backed-apply".script)
      "script: ${cfg-storage-pool.systemd.services."nixvm-pool-file-backed-apply".script}")

    (check "storage-pool/autostart-false-reaches-disable-flag"
      (lib.hasInfix "pool-autostart 'file-backed' --disable"
        cfg-storage-pool.systemd.services."nixvm-pool-file-backed-apply".script)
      "script: ${cfg-storage-pool.systemd.services."nixvm-pool-file-backed-apply".script}")

    # --- the known zvol/btrfs/nossd gotcha, both directions -------------------------
    (check "zvol-nossd-gotcha/passes-when-nossd-present"
      (builtins.tryEval (builtins.seq (builtins.unsafeDiscardStringContext cfg-zvol-pool-ok.system.build.toplevel.drvPath) true)).success
      "expected a zvolBacked pool whose filesystem already carries \"nossd\" to evaluate cleanly")

    (check "zvol-nossd-gotcha/fails-when-nossd-missing"
      (buildFails {
        nixvm.host = {
          enable = true;
          bridge = "examplebr0";
          storagePools.on-zvol = { path = "/mnt/zvol-pool"; zvolBacked = true; };
        };
        fileSystems."/mnt/zvol-pool" = { device = "/dev/zvol/pool/dataset"; fsType = "btrfs"; };
      })
      "expected a zvolBacked pool on a btrfs filesystem missing \"nossd\" to fail evaluation, but it succeeded")

    (check "zvol-nossd-gotcha/not-checked-when-zvolBacked-false"
      (
        let cfg = evalNixos {
          nixvm.host = {
            enable = true;
            bridge = "examplebr0";
            # zvolBacked left at its false default -- a native ZFS dataset (not a
            # zvol formatted with a foreign filesystem) needs no "nossd" at all,
            # even though this pool's own filesystem is btrfs with no "nossd" set.
            storagePools.native-dataset = { path = "/mnt/native-dataset"; };
          };
          fileSystems."/mnt/native-dataset" = { device = "/dev/sdz1"; fsType = "btrfs"; };
        };
        in (builtins.tryEval (builtins.seq (builtins.unsafeDiscardStringContext cfg.system.build.toplevel.drvPath) true)).success
      )
      "a pool with zvolBacked = false (the default) must never be asserted against regardless of its filesystem, but evaluation failed")
  ];

  # ── Pure xml-render checks: no nixosSystem at all --------------------------------
  baseGuest = {
    memoryMiB = 4096;
    cpu = { cores = 2; model = "host-passthrough"; };
    firmware = "uefi";
    clockOffset = "localtime";
    autostart = false;
    tpm.enable = false;
    graphics = { enable = true; type = "vnc"; listenAddress = "127.0.0.1"; };
    network = { bridge = null; model = "virtio"; macAddress = null; };
    disks.vda = { sourceType = "zvol"; source = "/dev/zvol/pool/unit-test"; bus = "virtio"; };
    extraDomainXML = "";
  };

  render = guest: domainXml.mkDomainXML { name = "unit-test-guest"; inherit guest; bridge = "examplebr0"; };

  xmlRenderResults = [
    (check "xml-render/zvol-disk-uses-block-source"
      (lib.hasInfix "<disk type='block' device='disk'>" (render baseGuest)
        && lib.hasInfix "<source dev='/dev/zvol/pool/unit-test'/>" (render baseGuest))
      "rendered: ${render baseGuest}")

    (check "xml-render/file-disk-uses-file-source"
      (
        let xml = render (baseGuest // { disks.vda = baseGuest.disks.vda // { sourceType = "file"; source = "/var/lib/libvirt/pools/x/disk0.qcow2"; }; });
        in lib.hasInfix "<disk type='file' device='disk'>" xml && lib.hasInfix "<source file='/var/lib/libvirt/pools/x/disk0.qcow2'/>" xml
      )
      "rendered: ${render (baseGuest // { disks.vda = baseGuest.disks.vda // { sourceType = "file"; source = "/var/lib/libvirt/pools/x/disk0.qcow2"; }; })}")

    (check "xml-render/tpm-block-present-when-enabled"
      (lib.hasInfix "<tpm model='tpm-crb'>" (render (baseGuest // { tpm.enable = true; })))
      "rendered: ${render (baseGuest // { tpm.enable = true; })}")

    (check "xml-render/tpm-block-absent-by-default"
      (!(lib.hasInfix "<tpm" (render baseGuest)))
      "rendered: ${render baseGuest}")

    (check "xml-render/graphics-block-absent-when-disabled"
      (!(lib.hasInfix "<graphics" (render (baseGuest // { graphics = baseGuest.graphics // { enable = false; }; }))))
      "rendered: ${render (baseGuest // { graphics = baseGuest.graphics // { enable = false; }; })}")

    (check "xml-render/mac-address-rendered-when-pinned"
      (lib.hasInfix "<mac address='52:54:00:12:34:56'/>" (render (baseGuest // { network = baseGuest.network // { macAddress = "52:54:00:12:34:56"; }; })))
      "rendered: ${render (baseGuest // { network = baseGuest.network // { macAddress = "52:54:00:12:34:56"; }; })}")

    (check "xml-render/bios-firmware-omits-firmware-attribute"
      (!(lib.hasInfix "firmware='efi'" (render (baseGuest // { firmware = "bios"; }))))
      "rendered: ${render (baseGuest // { firmware = "bios"; })}")

    (check "xml-render/extra-domain-xml-appended"
      (lib.hasInfix "<serial type='pty'/>" (render (baseGuest // { extraDomainXML = "<serial type='pty'/>"; })))
      "rendered: ${render (baseGuest // { extraDomainXML = "<serial type='pty'/>"; })}")

    (check "xml-render/name-and-bridge-escaped"
      (lib.hasInfix "<name>unit-test-guest</name>" (render baseGuest)
        && lib.hasInfix "<source bridge='examplebr0'/>" (render baseGuest))
      "rendered: ${render baseGuest}")
  ];

  allResults = results ++ xmlRenderResults;
  failed = builtins.filter (r: !r.ok) allResults;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then
  throw ''
    nixvm eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length allResults)}):
    ${report}
  ''
else {
  eval-tests = pkgs.runCommand "nixvm-eval-tests"
    { passedCount = toString (builtins.length allResults); }
    ''
      echo "all $passedCount nixvm eval tests passed"
      touch $out
    '';
}
