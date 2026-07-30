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
#      than silently produce something half-formed. This group also proves the
#      nixhost resource-envelope read: rendered from nixhost when declared, a BUILD
#      ERROR when the guest's memory ceiling cannot resolve (see "envelope/*" below --
#      and modules/guests/default.nix's own header for why memory, unlike CPU, has no
#      safe "render nothing" fallback, checked empirically against the real libvirt
#      domain parser), and a cross-check that nixhost and this repo agree on what KIND
#      of thing a given name is.
#
# Nothing here builds a VM, starts libvirtd, or runs a single line of the rendered
# script. That is exactly the boundary this repo exists to keep: nixvm declares and
# renders, `nix flake check` proves the declaring and rendering, and nothing more.
{ pkgs, lib, system, vmHostModule, guestsModule }:

let
  domainXml = import ../lib/domain-xml.nix { inherit lib; };
  stubs = import ./stub-modules.nix { inherit lib; };

  check = name: ok: detail: { inherit name ok detail; };

  # ── Stubs every fixture below needs to reach system.build.toplevel ──────────────────
  bootStub = {
    fileSystems."/" = { device = "nodev"; fsType = "tmpfs"; };
    boot.loader.grub = { enable = true; devices = [ "nodev" ]; };
    networking.hostName = "example-vm-host";
    system.stateVersion = "25.05";
  };

  evalNixos = extraModules:
    (lib.nixosSystem {
      inherit system;
      modules = [ vmHostModule guestsModule bootStub ] ++ extraModules;
    }).config;

  # Mirrors nixlxc's own `buildFails`: forcing `system.build.toplevel` is what actually
  # runs `assertions` (a bare read of `.config.assertions` is a passive list nobody
  # enforced yet). `seq` reaches the wrapping throw without deep-forcing, or building,
  # the whole system closure; the string context is discarded so this stays an EVAL
  # check, never a build.
  buildFails = extraModules:
    !(builtins.tryEval (builtins.seq
      (builtins.unsafeDiscardStringContext (evalNixos extraModules).system.build.toplevel.drvPath)
      true)).success;

  # ── Fixtures ─────────────────────────────────────────────────────────────────────
  cfg-host-only = evalNixos [{
    nixvm.host = { enable = true; bridge = "examplebr0"; };
  }];

  # nixhost declares the full envelope for this guest by name -- ram AND cpu -- so this
  # fixture doubles as both "the passing guest" and the source for every
  # render-content check below.
  cfg-one-guest = evalNixos [
    stubs.hostEnvStub
    {
      nixvm.host = { enable = true; bridge = "examplebr0"; };
      nixhost.environments.example-guest = {
        resources.ram.limitMiB = 8192;
        resources.cpu.quotaCores = 4;
      };
      nixvm.guests.example-guest = {
        disks.vda.source = "/dev/zvol/pool/example-guest";
      };
    }
  ];

  cfg-guest-own-bridge = evalNixos [
    stubs.hostEnvStub
    {
      nixvm.host = { enable = true; bridge = "examplebr0"; };
      nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
      nixvm.guests.example-guest = {
        network.bridge = "otherbr0";
        disks.vda.source = "/dev/zvol/pool/example-guest";
      };
    }
  ];

  cfg-guest-autostart = evalNixos [
    stubs.hostEnvStub
    {
      nixvm.host = { enable = true; bridge = "examplebr0"; };
      nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
      nixvm.guests.example-guest = {
        autostart = true;
        disks.vda.source = "/dev/zvol/pool/example-guest";
      };
    }
  ];

  cfg-storage-pool = evalNixos [{
    nixvm.host = {
      enable = true;
      bridge = "examplebr0";
      storagePools.file-backed = { path = "/var/lib/libvirt/pools/file-backed"; autostart = false; };
    };
  }];

  # zvolBacked pool whose declared `fileSystems` entry already carries "nossd" -- the
  # passing direction for the known gotcha.
  cfg-zvol-pool-ok = evalNixos [{
    nixvm.host = {
      enable = true;
      bridge = "examplebr0";
      storagePools.on-zvol = { path = "/mnt/zvol-pool"; zvolBacked = true; };
    };
    fileSystems."/mnt/zvol-pool" = { device = "/dev/zvol/pool/dataset"; fsType = "btrfs"; options = [ "nossd" ]; };
  }];

  xmlTextOf = cfg: name: cfg.environment.etc."nixvm/guests/${name}.xml".text;

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
      (buildFails [{ nixvm.host.enable = true; }])
      "expected nixvm.host.enable with no bridge set to fail evaluation, but it succeeded")

    # --- guests-need-a-host (failing direction) ------------------------------------
    (check "guests-need-a-host/fails-when-host-disabled"
      (buildFails [
        stubs.hostEnvStub
        {
          nixvm.host.bridge = "examplebr0";
          nixhost.environments.orphan.resources.ram.limitMiB = 1024;
          nixvm.guests.orphan.disks.vda.source = "/dev/zvol/pool/orphan";
        }
      ])
      "expected a guest defined with nixvm.host.enable = false (its own default) to fail evaluation, but it succeeded")

    # --- guest required fields (failing direction, each named) ---------------------
    # Both fixtures below supply a full nixhost envelope so the ONE thing under test --
    # disks -- is what actually fails, not a memory ceiling incidentally left unset.
    (check "guest-required/no-disks-fails"
      (buildFails [
        stubs.hostEnvStub
        {
          nixvm.host = { enable = true; bridge = "examplebr0"; };
          nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
          nixvm.guests.example-guest = { };
        }
      ])
      "expected a guest with zero disks to fail evaluation, but it succeeded")

    (check "guest-required/disk-source-unset-fails"
      (buildFails [
        stubs.hostEnvStub
        {
          nixvm.host = { enable = true; bridge = "examplebr0"; };
          nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
          nixvm.guests.example-guest.disks.vda = { };
        }
      ])
      "expected a disk with no source to fail evaluation, but it succeeded")

    # --- the passing guest composes and renders correctly --------------------------
    (check "one-guest/toplevel-evaluates"
      (builtins.tryEval (builtins.seq (builtins.unsafeDiscardStringContext cfg-one-guest.system.build.toplevel.drvPath) true)).success
      "expected a fully-specified guest, with its envelope declared in nixhost, to evaluate cleanly")

    (check "one-guest/xml-rendered-to-etc"
      (cfg-one-guest.environment.etc ? "nixvm/guests/example-guest.xml")
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames cfg-one-guest.environment.etc)}")

    (check "one-guest/xml-contains-memory"
      (lib.hasInfix "<memory unit='MiB'>8192</memory>" (xmlTextOf cfg-one-guest "example-guest"))
      "text: ${xmlTextOf cfg-one-guest "example-guest"}")

    (check "one-guest/xml-contains-vcpu"
      (lib.hasInfix "<vcpu placement='static'>4</vcpu>" (xmlTextOf cfg-one-guest "example-guest"))
      "text: ${xmlTextOf cfg-one-guest "example-guest"}")

    (check "one-guest/xml-contains-disk-source"
      (lib.hasInfix "/dev/zvol/pool/example-guest" (xmlTextOf cfg-one-guest "example-guest"))
      "text: ${xmlTextOf cfg-one-guest "example-guest"}")

    (check "one-guest/xml-uses-host-bridge-by-default"
      (lib.hasInfix "<source bridge='examplebr0'/>" (xmlTextOf cfg-one-guest "example-guest"))
      "text: ${xmlTextOf cfg-one-guest "example-guest"}")

    (check "one-guest/xml-defaults-to-uefi-firmware"
      (lib.hasInfix "<os firmware='efi'>" (xmlTextOf cfg-one-guest "example-guest"))
      "text: ${xmlTextOf cfg-one-guest "example-guest"}")

    (check "one-guest/xml-defaults-to-localtime-clock"
      (lib.hasInfix "<clock offset='localtime'/>" (xmlTextOf cfg-one-guest "example-guest"))
      "text: ${xmlTextOf cfg-one-guest "example-guest"}")

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
      (lib.hasInfix "<source bridge='otherbr0'/>" (xmlTextOf cfg-guest-own-bridge "example-guest"))
      "text: ${xmlTextOf cfg-guest-own-bridge "example-guest"}")

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
      (buildFails [{
        nixvm.host = {
          enable = true;
          bridge = "examplebr0";
          storagePools.on-zvol = { path = "/mnt/zvol-pool"; zvolBacked = true; };
        };
        fileSystems."/mnt/zvol-pool" = { device = "/dev/zvol/pool/dataset"; fsType = "btrfs"; };
      }])
      "expected a zvolBacked pool on a btrfs filesystem missing \"nossd\" to fail evaluation, but it succeeded")

    (check "zvol-nossd-gotcha/not-checked-when-zvolBacked-false"
      (
        let cfg = evalNixos [{
          nixvm.host = {
            enable = true;
            bridge = "examplebr0";
            # zvolBacked left at its false default -- a native ZFS dataset (not a
            # zvol formatted with a foreign filesystem) needs no "nossd" at all,
            # even though this pool's own filesystem is btrfs with no "nossd" set.
            storagePools.native-dataset = { path = "/mnt/native-dataset"; };
          };
          fileSystems."/mnt/native-dataset" = { device = "/dev/sdz1"; fsType = "btrfs"; };
        }];
        in (builtins.tryEval (builtins.seq (builtins.unsafeDiscardStringContext cfg.system.build.toplevel.drvPath) true)).success
      )
      "a pool with zvolBacked = false (the default) must never be asserted against regardless of its filesystem, but evaluation failed")

    # ══ THE RESOURCE ENVELOPE: read from nixhost, matched by name ══════════════════
    #
    # See modules/guests/default.nix's own header, right above `envelopeFor`, for the
    # full reasoning and the empirical libvirt finding these checks are built on:
    # memory has no safe "render nothing" state (a domain with no <memory> element is
    # refused outright by the real libvirt parser), CPU does (a domain with no <vcpu>
    # element defines fine, libvirt's own default applies).

    # --- absent nixhost: the assertion fires, named, rather than a raw crash --------
    (check "envelope/memory-required-fails-without-nixhost-at-all"
      (buildFails [{
        nixvm.host = { enable = true; bridge = "examplebr0"; };
        nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
      }])
      "expected a guest with no nixhost import at all to fail evaluation -- a libvirt domain cannot omit <memory>, so unlike nixlxc's identical-looking ceiling this one has no safe absent-state")

    # The same fixture again, but reading `config.assertions` directly instead of
    # `buildFails`'s bare boolean -- proving the CONFIG ITSELF (assertions included)
    # evaluates cleanly, through to a friendly, NAMED failure, rather than crashing on
    # a raw Nix attribute/type error the moment `config.nixhost` is read on a host that
    # never imported it at all. This is the literal, checked form of "a guest still
    # evaluates on a host which never imported nixhost": it evaluates far enough to
    # produce this exact message, it just never reaches a successful toplevel.
    (check "envelope/absent-nixhost-produces-a-named-assertion-not-a-raw-crash"
      (
        let
          cfg = evalNixos [{
            nixvm.host = { enable = true; bridge = "examplebr0"; };
            nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
          }];
          failing = builtins.filter (a: !a.assertion) cfg.assertions;
        in
        (builtins.tryEval (builtins.seq (builtins.length failing) true)).success
        && lib.any (a: lib.hasInfix "nixhost.environments.example-guest.resources.ram.limitMiB" a.message) failing
      )
      "expected config.assertions itself to evaluate (not raw-crash) and to contain a message naming nixhost.environments.example-guest.resources.ram.limitMiB")

    # --- nixhost IS imported, but this name's ram.limitMiB is left unset ------------
    (check "envelope/memory-required-fails-when-nixhost-declares-guest-without-ram"
      (buildFails [
        stubs.hostEnvStub
        {
          nixvm.host = { enable = true; bridge = "examplebr0"; };
          nixhost.environments.example-guest = { };
          nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
        }
      ])
      "expected a guest declared in nixhost.environments but with no ram.limitMiB set to fail evaluation, but it succeeded")

    # --- a fully-declared envelope renders memory AND vcpu (positive direction) -----
    # (also proven above by one-guest/xml-contains-memory + one-guest/xml-contains-vcpu,
    # restated here under the envelope/* group for discoverability)
    (check "envelope/read-from-nixhost-renders-memory-and-vcpu"
      (
        let text = xmlTextOf cfg-one-guest "example-guest"; in
        lib.hasInfix "<memory unit='MiB'>8192</memory>" text && lib.hasInfix "<vcpu placement='static'>4</vcpu>" text
      )
      "the ceiling must come from nixhost.environments.<name>.resources, matched by name -- this module declares no envelope of its own")

    # --- cpu.quotaCores absent: the <vcpu> element is omitted, not defaulted --------
    (check "envelope/cpu-quota-absent-omits-vcpu-element"
      (!(lib.hasInfix "<vcpu"
        (xmlTextOf
          (evalNixos [
            stubs.hostEnvStub
            {
              nixvm.host = { enable = true; bridge = "examplebr0"; };
              nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
              nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
            }
          ])
          "example-guest")))
      "with no cpu.quotaCores declared in nixhost there is no ceiling to render: libvirt's own upstream default applies, not a number this module invented")

    (check "envelope/cpu-quota-absent-still-builds"
      (!(buildFails [
        stubs.hostEnvStub
        {
          nixvm.host = { enable = true; bridge = "examplebr0"; };
          nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
          nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
        }
      ]))
      "a guest with a declared memory ceiling but no cpu.quotaCores must still evaluate -- CPU, unlike memory, has a safe absent state")

    # --- a fractional quotaCores rounds UP to the smallest whole vCPU count ---------
    (check "envelope/fractional-quota-cores-rounds-up-to-whole-vcpu"
      (lib.hasInfix "<vcpu placement='static'>2</vcpu>"
        (xmlTextOf
          (evalNixos [
            stubs.hostEnvStub
            {
              nixvm.host = { enable = true; bridge = "examplebr0"; };
              nixhost.environments.example-guest = {
                resources.ram.limitMiB = 2048;
                resources.cpu.quotaCores = 1.5;
              };
              nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
            }
          ])
          "example-guest"))
      "a libvirt <vcpu> count cannot be fractional, so a 1.5-core ceiling must round UP to 2 whole vCPUs, never down (which would under-provision) and never fail outright")

    # ── Cross-check: nixhost and this repo must agree on what a name IS ─────────────
    (check "envelope/kind-disagreement-fails"
      (buildFails [
        stubs.hostEnvStub
        {
          nixvm.host = { enable = true; bridge = "examplebr0"; };
          nixhost.environments.example-guest = { kind = "lxc"; resources.ram.limitMiB = 2048; };
          nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
        }
      ])
      "nixhost calling the same name an lxc container while this module builds a libvirt VM is two declarations disagreeing about what the thing IS -- nixhost would budget an envelope for the wrong kind and this module would read a ceiling meant for something else")

    (check "envelope/matching-kind-builds-fine"
      (!(buildFails [
        stubs.hostEnvStub
        {
          nixvm.host = { enable = true; bridge = "examplebr0"; };
          nixhost.environments.example-guest = { kind = "vm"; resources.ram.limitMiB = 2048; };
          nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
        }
      ]))
      "kind = vm agreeing with a libvirt guest must not fire -- the check is about disagreement, not about nixhost being present")

    # --- kind check must not raw-crash when a REAL nixhost-shaped `kind` is left unset ----
    # Unlike `stubs.hostEnvStub` (whose `kind` carries a default purely for fixture
    # convenience), the real nixhost's `kind` option has NO default at all -- reading it
    # when unset raises NixOS's own "option ... accessed but has no value defined" error,
    # which a bare `or null` does NOT catch (that idiom only catches a missing ATTRIBUTE,
    # not a `throw` raised while computing one that exists but was never given a value).
    # This fixture mirrors that real shape exactly (no default on `kind`) to prove the
    # `builtins.tryEval` guard in `declaredKind` earns its keep: ram.limitMiB IS set here,
    # so the ONLY thing standing between this guest and a clean build is whether reading
    # the unset `kind` crashes raw -- it must not.
    (check "envelope/kind-unset-in-real-nixhost-shape-does-not-raw-crash"
      (
        let
          noDefaultKindStub = { lib, ... }: {
            options.nixhost.environments = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule {
                options = {
                  kind = lib.mkOption { type = lib.types.str; }; # no default -- matches the real nixhost
                  resources.ram.limitMiB = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
                  resources.cpu.quotaCores = lib.mkOption { type = lib.types.nullOr (lib.types.either lib.types.int lib.types.float); default = null; };
                };
              });
              default = { };
            };
          };
        in
        !(buildFails [
          noDefaultKindStub
          {
            nixvm.host = { enable = true; bridge = "examplebr0"; };
            nixhost.environments.example-guest.resources.ram.limitMiB = 2048; # kind left unset
            nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
          }
        ])
      )
      "expected an environment declared with a real-nixhost-shaped (no-default) `kind` left unset, but ram.limitMiB set, to evaluate cleanly -- reading `.kind` must never raw-crash the kind cross-check")
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

    # --- vcpu is the one field the caller may legitimately hand this file `null` ----
    (check "xml-render/vcpu-rendered-when-cores-set"
      (lib.hasInfix "<vcpu placement='static'>2</vcpu>" (render baseGuest))
      "rendered: ${render baseGuest}")

    (check "xml-render/vcpu-omitted-when-cores-null"
      (!(lib.hasInfix "<vcpu" (render (baseGuest // { cpu = baseGuest.cpu // { cores = null; }; }))))
      "rendered: ${render (baseGuest // { cpu = baseGuest.cpu // { cores = null; }; })}")
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
