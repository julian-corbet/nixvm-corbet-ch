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
#      of thing a given name is. The "fact-wiring/*" group at the bottom proves
#      `lib.probeFact` (consumed from nixhost's own `lib/facts.nix` via this repo's `nixhost`
#      flake input, see flake.nix) actually distinguishes "nixhost not composed at all" from
#      "nixhost composed but
#      `environments` renamed" THROUGH this real module -- the ambiguity nixvm's own
#      pre-existing memoryRequiredAssertions message could not resolve on its own (see
#      that group's own header).
#
#   3. "arch-plane/*" and the resolution/catalogue groups -- the SECOND plane. These evaluate
#      modules/vm-host/arch.nix against a stand-in for system-manager's own option surface
#      (checks/stub-modules.nix's `systemManagerPlaneStub`), which turns "sets nothing that only
#      exists on NixOS" from a claim in a comment into something the module system enforces: an
#      assignment to an option the stub does not declare fails evaluation. The group starts by
#      proving the stub is actually strict, because a permissive stub would make every check
#      built on it pass for no reason.
#
# Nothing here builds a VM, starts libvirtd, or runs a single line of the rendered
# script. That is exactly the boundary this repo exists to keep: nixvm declares and
# renders, `nix flake check` proves the declaring and rendering, and nothing more.
{ pkgs, lib, system, vmHostModule, guestsModule, archModule }:

let
  domainXml = import ../lib/domain-xml.nix { inherit lib; };
  stubs = import ./stub-modules.nix { inherit lib; };
  cat = import ../lib/toolchain.nix { };
  resolve = import ../lib/resolve.nix { inherit lib; };

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

  # ── Second-plane evaluation: modules/vm-host/arch.nix against the system-manager stand-in ────
  #
  # A plain `lib.evalModules`, NOT `lib.nixosSystem`: composing the NixOS module set would
  # declare every NixOS option and defeat the entire purpose, which is that the option surface
  # here is exactly system-manager's and nothing beyond it. `pkgs` is threaded through
  # `specialArgs` because system-manager provides it too -- so the `stub-rejects-the-nixos-
  # backend` check below fails for the reason it is meant to (an undeclared NixOS option) rather
  # than incidentally, on a missing module argument.
  evalArch = extraModules:
    (lib.evalModules {
      modules = [ stubs.systemManagerPlaneStub archModule ] ++ extraModules;
      specialArgs = { inherit pkgs; };
    }).config;

  # `deepSeq` on `.config`, not `seq`: the undeclared-option error is raised while the module
  # system assembles `config`, and stopping at weak-head-normal-form would leave it unforced.
  # Everything the stub declares is a cheap list or attrset, so this never drags a package
  # closure in.
  planeEvalFails = modules:
    !(builtins.tryEval (builtins.deepSeq
      (lib.evalModules {
        modules = [ stubs.systemManagerPlaneStub ] ++ modules;
        specialArgs = { inherit pkgs; };
      }).config
      true)).success;

  # The Arch plane has no `system.build.toplevel` to force, so a failing assertion is read
  # straight off `config.assertions` -- the same list system-manager's own activation checks.
  archAssertionFires = cfgArch: needle:
    lib.any (a: !a.assertion && lib.hasInfix needle a.message) cfgArch.assertions;

  arch-host = evalArch [{ nixvm.host.enable = true; }];
  arch-disabled = evalArch [{ }];
  arch-tools = evalArch [{
    nixvm.host = { enable = true; tools = [ "manager" "viewer" "images" "cloudInit" "installer" "osinfo" ]; };
  }];
  arch-foreign = evalArch [{
    nixvm.host = { enable = true; foreignArchitectures = [ "aarch64" "riscv" ]; };
  }];
  arch-remote-only = evalArch [{
    nixvm.host.remotes.vmhost.uri = "qemu+ssh://root@vmhost.example/system";
  }];
  arch-pool-zvol = evalArch [{
    nixvm.host = {
      enable = true;
      storagePools.on-zvol = { path = "/mnt/zvol-pool"; zvolBacked = true; };
    };
  }];

  # ── NixOS-plane fixtures for the architecture and tooling selection ─────────────────────────
  qemuOf = cfg: cfg.virtualisation.libvirtd.qemu.package;
  targetListOf = cfg:
    lib.filter (f: lib.hasPrefix "--target-list=" f) ((qemuOf cfg).configureFlags or [ ]);
  # Joined rather than indexed, because the FAILING state of these checks is precisely "there is
  # no --target-list flag at all" (that is what the build-everything qemu looks like). A check
  # that reaches for `builtins.head` of that list stops being a failing check and becomes a raw
  # eval error, which reports nothing about which property broke.
  targetListStr = cfg: lib.concatStringsSep " " (targetListOf cfg);

  cfg-nixos-default-arch = evalNixos [{ nixvm.host = { enable = true; bridge = "examplebr0"; }; }];
  cfg-nixos-foreign-arch = evalNixos [{
    nixvm.host = { enable = true; bridge = "examplebr0"; foreignArchitectures = [ "aarch64" ]; };
  }];
  cfg-nixos-tools = evalNixos [{
    nixvm.host = { enable = true; bridge = "examplebr0"; tools = [ "manager" "installer" "viewer" ]; };
  }];
  cfg-nixos-remote = evalNixos [{
    nixvm.host = {
      enable = true;
      bridge = "examplebr0";
      remotes.vmhost.uri = "qemu+ssh://root@vmhost.example/system";
    };
  }];

  pkgNames = cfg: map (p: p.pname or p.name or "?") cfg.environment.systemPackages;

  # ── Fixture entry tables for lib/resolve.nix, in the shapes lib/toolchain.nix lacks ──────────
  # The real catalogue has no AUR entry at all, so `archPackages` and `aurPackages` return the
  # identical result against it whether the split works or is a no-op -- see lib/resolve.nix's
  # own header for why that makes a catalogue-only test worthless here.
  repoEntry = { name = "repo"; arch = "repo"; nixpkgs = "repo"; };
  aurEntry = { name = "aurthing"; arch = "aurthing"; aur = true; nixpkgs = "aurthing"; };
  daemonEntry = { name = "daemonish"; arch = "daemonish"; nixpkgs = null; };
  allEntries = [ repoEntry aurEntry daemonEntry ];

  # ── fact-wiring fixtures: `lib.probeFact` proven THROUGH the real `modules/guests` ──────
  #
  # One guest declared in every fixture below (`cfg != { }`), so `config.warnings` is actually
  # computed -- but `.warnings` is a plain attribute read, never `system.build.toplevel`, so it
  # evaluates the same whether or not the fixture's OWN, unrelated `memoryRequiredAssertions`
  # would also fail the build (see that assertion's own header: a libvirt guest cannot omit
  # `<memory>`, so unlike nixlxc's identical-looking ceiling, nixvm's own ram requirement is
  # loud on BOTH "nixhost absent" and "nixhost renamed" already, before `lib.probeFact` was ever
  # adopted). What `lib.probeFact` adds is a signal that tells the two apart, which the ambiguous
  # pre-existing assertion message ("... is not set (or nixhost is not imported ...)") could not:
  # state (a) must still warn zero times; state (c) must warn exactly once, naming the option.
  quietGuest = name: {
    nixvm.host = { enable = true; bridge = "examplebr0"; };
    nixvm.guests.${name}.disks.vda.source = "/dev/zvol/pool/${name}";
  };

  cfg-facts-no-nixhost-at-all = evalNixos [ (quietGuest "example-guest") ];

  cfg-facts-nixhost-renamed = evalNixos [
    stubs.hostEnvironmentsRenamedStub
    (quietGuest "example-guest")
  ];

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

    # --- a hypervisor with NO bridge is a complete configuration ---------------------
    # The requirement used to sit on `nixvm.host.enable` itself, which made the one host shape
    # this repo's second plane exists for -- a laptop on wireless, with no bridge to offer and
    # libvirt's own NAT network instead -- impossible to declare truthfully. See
    # modules/guests/default.nix's `bridgeAssertions` for the full reasoning, and the
    # guest-bridge/* pair below for where the requirement went.
    (check "host-only/no-bridge-still-evaluates"
      (!(buildFails [{ nixvm.host.enable = true; }]))
      "expected a hypervisor host with no bridge and no guests to evaluate cleanly -- a host with nothing to bridge onto is a real, correct configuration, not a half-finished one")

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
        let
          cfg = evalNixos [{
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
        in
        (builtins.tryEval (builtins.seq (builtins.unsafeDiscardStringContext cfg.system.build.toplevel.drvPath) true)).success
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
      (
        !(lib.hasInfix "<vcpu"
          (xmlTextOf
            (evalNixos [
              stubs.hostEnvStub
              {
                nixvm.host = { enable = true; bridge = "examplebr0"; };
                nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
                nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
              }
            ])
            "example-guest"))
      )
      "with no cpu.quotaCores declared in nixhost there is no ceiling to render: libvirt's own upstream default applies, not a number this module invented")

    (check "envelope/cpu-quota-absent-still-builds"
      (
        !(buildFails [
          stubs.hostEnvStub
          {
            nixvm.host = { enable = true; bridge = "examplebr0"; };
            nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
            nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
          }
        ])
      )
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
      (
        !(buildFails [
          stubs.hostEnvStub
          {
            nixvm.host = { enable = true; bridge = "examplebr0"; };
            nixhost.environments.example-guest = { kind = "vm"; resources.ram.limitMiB = 2048; };
            nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
          }
        ])
      )
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

    # ══ fact-wiring: lib.probeFact through the real module, not just lib/facts.nix's own ══
    (check "fact-wiring/all-siblings-faithful-has-no-warnings"
      (cfg-one-guest.warnings == [ ])
      "got warnings=${builtins.toJSON cfg-one-guest.warnings}, expected none: nixhost composed with its real, un-renamed shape and a full envelope must produce zero warnings")

    (check "fact-wiring/no-nixhost-composed-has-no-warnings"
      (cfg-facts-no-nixhost-at-all.warnings == [ ])
      "got warnings=${builtins.toJSON cfg-facts-no-nixhost-at-all.warnings}, expected none: state (a) -- nixhost never imported at all -- must stay silent even though the SEPARATE, pre-existing memoryRequiredAssertions correctly still fails this guest's build for its own, unrelated reason")

    (check "fact-wiring/nixhost-environments-renamed-warns-exactly-once"
      (
        let w = cfg-facts-nixhost-renamed.warnings; in
        lib.length w == 1
        && lib.hasInfix "nixhost.environments" (lib.head w)
        && lib.hasInfix "nixhost" (lib.head w)
      )
      "got warnings=${builtins.toJSON cfg-facts-nixhost-renamed.warnings}, expected exactly one, naming nixhost.environments -- the decoy renames it to nixhost.workloads while nixhost itself IS composed. This is the one this whole group exists for: before lib.probeFact, this exact case was indistinguishable from state (a) above -- both silently produced the same ambiguous assertion message and no way to tell them apart")

    (check "fact-wiring/nixhost-environments-renamed-still-fails-for-its-own-unrelated-mandatory-ram-reason"
      (buildFails [ stubs.hostEnvironmentsRenamedStub (quietGuest "example-guest") ])
      "expected the build to still fail here too -- NOT because lib.probeFact ever asserts (it defaults to mode = \"warn\", never \"assert\", for this read) but because nixvm's own memoryRequiredAssertions correctly has nothing to resolve against either way. Adopting lib.probeFact must not have silently loosened that pre-existing requirement")

    # ══ THE BRIDGE REQUIREMENT, AT ITS POINT OF USE ═══════════════════════════════════════════
    #
    # Both directions of the assertion that moved out of vm-host and into guests. The failing
    # direction is the interesting one: a declared guest with no bridge ANYWHERE must not
    # silently render `<source bridge=''/>`.
    (check "guest-bridge/fails-when-neither-host-nor-guest-names-one"
      (buildFails [
        stubs.hostEnvStub
        {
          nixvm.host.enable = true; # no bridge
          nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
          nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
        }
      ])
      "expected a declared guest with no bridge on either the host or itself to fail evaluation, but it succeeded")

    (check "guest-bridge/failure-names-the-guest-not-the-host"
      (
        let
          cfg = evalNixos [
            stubs.hostEnvStub
            {
              nixvm.host.enable = true;
              nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
              nixvm.guests.example-guest.disks.vda.source = "/dev/zvol/pool/example-guest";
            }
          ];
          failing = builtins.filter (a: !a.assertion) cfg.assertions;
        in
        lib.any (a: lib.hasInfix "nixvm.guests.example-guest.network.bridge" a.message) failing
      )
      "the message must name the guest that has no bridge -- on a host with several guests, only one of which declines to say, naming the host instead sends the reader to the wrong file")

    (check "guest-bridge/passes-when-only-the-guest-names-one"
      (
        !(buildFails [
          stubs.hostEnvStub
          {
            nixvm.host.enable = true; # still no host bridge
            nixhost.environments.example-guest.resources.ram.limitMiB = 2048;
            nixvm.guests.example-guest = {
              network.bridge = "guestbr0";
              disks.vda.source = "/dev/zvol/pool/example-guest";
            };
          }
        ])
      )
      "a guest that names its own bridge needs nothing from the host -- the requirement is about the value being resolvable, not about which option supplies it")

    # ══ ARCHITECTURE SELECTION -- NixOS plane ═════════════════════════════════════════════════
    #
    # The discriminator is QEMU's own `--target-list=` configure flag, read off the derivation:
    # `pkgs.qemu_kvm` carries `--target-list=i386-softmmu,x86_64-softmmu`, an override carries
    # exactly what it was given, and the unrestricted top-level `pkgs.qemu` carries NO
    # `--target-list` flag at all (that is what "every target" looks like). So a check on the
    # flag's CONTENT and a check that the flag EXISTS test two different failure modes.

    (check "arch-select/default-is-the-host-cpu-only-qemu"
      ((qemuOf cfg-nixos-default-arch).pname == "qemu-host-cpu-only")
      "expected the empty foreignArchitectures default to resolve to pkgs.qemu_kvm (pname qemu-host-cpu-only), which has a binary cache behind it; got pname: ${(qemuOf cfg-nixos-default-arch).pname}")

    (check "arch-select/default-target-list-carries-no-foreign-target"
      (
        let tl = targetListOf cfg-nixos-default-arch; in
        tl != [ ] && !(lib.any (f: lib.hasInfix "aarch64-softmmu" f || lib.hasInfix "riscv" f || lib.hasInfix "s390x" f) tl)
      )
      "got target-list flags: ${builtins.toJSON (targetListOf cfg-nixos-default-arch)}")

    # The failure this catches is the easy mistake: reaching for `pkgs.qemu` when someone asks
    # for a foreign architecture. That "works" -- it does include aarch64 -- while also shipping
    # every other target, which is precisely what the option exists to prevent.
    (check "arch-select/opting-in-does-not-fall-back-to-the-unrestricted-qemu"
      (targetListOf cfg-nixos-foreign-arch != [ ])
      "a qemu with no --target-list flag at all is the build-everything qemu; got flags: ${builtins.toJSON ((qemuOf cfg-nixos-foreign-arch).configureFlags or [ ])}")

    (check "arch-select/opting-in-adds-exactly-the-named-target"
      (
        let tl = targetListStr cfg-nixos-foreign-arch; in
        lib.hasInfix "aarch64-softmmu" tl
        && lib.hasInfix "x86_64-softmmu" tl
        && !(lib.hasInfix "riscv" tl)
        && !(lib.hasInfix "s390x" tl)
      )
      "got: ${builtins.toJSON (targetListOf cfg-nixos-foreign-arch)}")

    (check "arch-select/the-hosts-own-targets-survive-opting-in"
      (lib.hasInfix "i386-softmmu" (targetListStr cfg-nixos-foreign-arch))
      "asking for a foreign architecture must ADD to the host's own targets, never replace them -- a host that can no longer run its own architecture is not a hypervisor. got: ${builtins.toJSON (targetListOf cfg-nixos-foreign-arch)}")

    # ══ TOOLING -- NixOS plane ════════════════════════════════════════════════════════════════
    #
    # `environment.systemPackages` on a real NixOS system is the whole base closure plus whatever
    # `virtualisation.libvirtd` itself adds, so it can only ever be asked about MEMBERSHIP. What
    # nixvm itself chose is `nixvm.host.nixpkgsPackages`, and the two are checked separately on
    # purpose: the first says the selection arrived, the second says nothing arrived that was not
    # selected.
    (check "tools/empty-selection-adds-nothing-of-its-own"
      (
        cfg-nixos-default-arch.nixvm.host.nixpkgsPackages == [ ]
        && !(lib.elem "virt-manager" (pkgNames cfg-nixos-default-arch))
        && !(lib.elem "virt-viewer" (pkgNames cfg-nixos-default-arch))
      )
      "nixpkgsPackages: ${builtins.toJSON cfg-nixos-default-arch.nixvm.host.nixpkgsPackages}")

    (check "tools/selection-reaches-systemPackages"
      (lib.elem "virt-viewer" (pkgNames cfg-nixos-tools))
      "got: ${builtins.toJSON (pkgNames cfg-nixos-tools)}")

    # `manager` and `installer` are two catalogue rows (they are two packages on Arch) that name
    # ONE nixpkgs attribute, so the resolution must de-duplicate rather than list it twice.
    (check "tools/manager-and-installer-collapse-to-one-nixpkgs-attribute"
      (
        cfg-nixos-tools.nixvm.host.nixpkgsPackages == [ "virt-manager" "virt-viewer" ]
        && lib.length (lib.filter (n: n == "virt-manager") (pkgNames cfg-nixos-tools)) == 1
      )
      "nixpkgsPackages: ${builtins.toJSON cfg-nixos-tools.nixvm.host.nixpkgsPackages}")

    # The daemon rows carry `nixpkgs = null` on purpose, so nixvm must contribute none of them...
    (check "tools/daemon-rows-are-not-nixvms-to-install"
      (
        let ns = cfg-nixos-tools.nixvm.host.nixpkgsPackages; in
        !(lib.elem "libvirt" ns) && !(lib.elem "qemu" ns) && !(lib.elem "qemu_kvm" ns)
        && !(lib.elem "swtpm" ns) && !(lib.elem "dnsmasq" ns)
      )
      "a daemon row appearing here would be a SECOND copy of a package virtualisation.libvirtd already delivers, and a second owner for one fact. got: ${builtins.toJSON cfg-nixos-tools.nixvm.host.nixpkgsPackages}")

    # ...and the other half of the same claim, which is the one that makes the null a positive
    # statement rather than a hole: they are on the system anyway, from the libvirtd module.
    (check "tools/daemon-rows-arrive-from-the-libvirtd-module-instead"
      (
        let names = pkgNames cfg-nixos-tools; in
        lib.elem "libvirt" names && lib.elem "qemu-host-cpu-only" names
      )
      "the daemon rows are `nixpkgs = null` because virtualisation.libvirtd puts them on the system itself -- if that stops being true, the null becomes a genuine gap and this module ships a host with no libvirt. got: ${builtins.toJSON (pkgNames cfg-nixos-tools)}")

    (check "tools/no-warning-on-todays-catalogue"
      (cfg-nixos-tools.warnings == [ ])
      "a warning here means a lib/toolchain.nix nixpkgs attribute does not resolve or does not force -- fix the catalogue, do not pin around it. got: ${builtins.toJSON cfg-nixos-tools.warnings}")

    # ══ REMOTE CONNECTIONS -- NixOS plane ═════════════════════════════════════════════════════
    #
    # nixpkgs builds libvirt with `--sysconfdir=/var/lib`, so the client config it reads is
    # /var/lib/libvirt/libvirt.conf. A file at /etc/libvirt/libvirt.conf on this plane is read by
    # nothing at all -- which is why the wrong-path check below is as load-bearing as the right
    # one, and why the two planes render the same text to different places.
    (check "remotes/nixos-renders-under-var-lib"
      (lib.any (r: lib.hasInfix "L+ /var/lib/libvirt/libvirt.conf" r) cfg-nixos-remote.systemd.tmpfiles.rules)
      "got tmpfiles rules: ${builtins.toJSON cfg-nixos-remote.systemd.tmpfiles.rules}")

    (check "remotes/nixos-does-not-render-into-etc"
      (!(cfg-nixos-remote.environment.etc ? "libvirt/libvirt.conf"))
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames cfg-nixos-remote.environment.etc)}")

    (check "remotes/nixos-renders-nothing-when-none-declared"
      (!(lib.any (r: lib.hasInfix "libvirt/libvirt.conf" r) cfg-nixos-default-arch.systemd.tmpfiles.rules))
      "a host declaring no remote must not take ownership of libvirt's client config at all. got: ${builtins.toJSON cfg-nixos-default-arch.systemd.tmpfiles.rules}")

    (check "remotes/bad-alias-name-fails-by-name"
      (buildFails [{
        nixvm.host = {
          enable = true;
          bridge = "examplebr0";
          remotes."has a space".uri = "qemu+ssh://root@vmhost.example/system";
        };
      }])
      "libvirt reads an alias up to the first character outside [a-zA-Z0-9_-] and resolves that prefix, so a name with a space fails silently at runtime rather than loudly at eval -- unless this assertion catches it first")

    (check "remotes/a-quote-in-the-uri-fails"
      (buildFails [{
        nixvm.host = {
          enable = true;
          bridge = "examplebr0";
          remotes.vmhost.uri = "qemu+ssh://root@vm\"host.example/system";
        };
      }])
      "a double quote would close the string libvirt is parsing, making the generated file mean something different than it reads here")

    # ══ THE ARCH PLANE ════════════════════════════════════════════════════════════════════════
    #
    # NON-VACUITY FIRST. Everything below rests on the claim that
    # `stubs.systemManagerPlaneStub` refuses an option system-manager does not have. If it
    # quietly accepted them, "the Arch backend sets nothing NixOS-only" would pass for a backend
    # that set all of them. These three probes are that proof, and they are permanent rather than
    # a one-off manual experiment.

    (check "arch-plane/stub-rejects-a-virtualisation-option"
      (planeEvalFails [{ virtualisation.libvirtd.enable = true; }])
      "the system-manager stand-in accepted virtualisation.libvirtd.enable, so every arch-plane check below is vacuous")

    (check "arch-plane/stub-rejects-boot-kernel-modules"
      (planeEvalFails [{ boot.kernelModules = [ "tun" ]; }])
      "the system-manager stand-in accepted boot.kernelModules, which system-manager has no namespace for at all")

    (check "arch-plane/stub-rejects-filesystems"
      (planeEvalFails [{ fileSystems."/mnt/x" = { device = "/dev/sdz1"; fsType = "btrfs"; }; }])
      "the system-manager stand-in accepted fileSystems -- the option the zvol/nossd assertion reads, and the reason that assertion is NixOS-only")

    # The whole NixOS backend, against the same stub. It must fail, because it is the module that
    # legitimately does set NixOS-only options -- this is the negative control for the positive
    # check immediately after it.
    (check "arch-plane/stub-rejects-the-nixos-backend"
      (planeEvalFails [ vmHostModule { nixvm.host.enable = true; } ])
      "modules/vm-host/nixos.nix evaluated cleanly on a system-manager option surface, which would mean either the stub is not strict or the NixOS backend is not actually setting virtualisation.*")

    # ...and the positive direction: the Arch backend, same stub, evaluates.
    (check "arch-plane/backend-evaluates-cleanly"
      (builtins.tryEval (builtins.deepSeq arch-host true)).success
      "modules/vm-host/arch.nix must evaluate against system-manager's own option surface -- if this fails, it is reaching for an option that plane does not have")

    (check "arch-plane/backend-sets-no-assertion-of-its-own-when-clean"
      (lib.filter (a: !a.assertion) arch-host.assertions == [ ])
      "got failing assertions: ${builtins.toJSON (map (a: a.message) (lib.filter (a: !a.assertion) arch-host.assertions))}")

    # ── the x86-only default, on the plane where the accident is 600 MiB ──────────────────────
    (check "arch-plane/default-installs-the-x86-only-qemu"
      (lib.elem "qemu-desktop" arch-host.nixvm.host.archPackages)
      "got: ${builtins.toJSON arch-host.nixvm.host.archPackages}")

    (check "arch-plane/default-installs-no-foreign-arch-package"
      (!(lib.any (p: lib.hasPrefix "qemu-system-" p) arch-host.nixvm.host.archPackages))
      "got: ${builtins.toJSON arch-host.nixvm.host.archPackages}")

    # Named explicitly rather than left to the prefix check above: these two are the packages a
    # host acquires the full emulator set THROUGH, and `qemu-full` does not match `qemu-system-*`.
    (check "arch-plane/never-selects-qemu-full-or-qemu-emulators-full"
      (
        let ps = arch-host.nixvm.host.archPackages ++ arch-foreign.nixvm.host.archPackages; in
        !(lib.elem "qemu-full" ps) && !(lib.elem "qemu-emulators-full" ps)
      )
      "got: ${builtins.toJSON (arch-host.nixvm.host.archPackages ++ arch-foreign.nixvm.host.archPackages)}")

    (check "arch-plane/opting-in-adds-exactly-the-named-architectures"
      (
        let ps = arch-foreign.nixvm.host.archPackages; in
        lib.elem "qemu-system-aarch64" ps
        && lib.elem "qemu-system-riscv" ps
        && !(lib.elem "qemu-system-s390x" ps)
        && lib.elem "qemu-desktop" ps
      )
      "got: ${builtins.toJSON arch-foreign.nixvm.host.archPackages}")

    (check "arch-plane/daemon-stance-carries-libvirts-nat-dependency"
      (
        let ps = arch-host.nixvm.host.archPackages; in
        lib.elem "libvirt" ps && lib.elem "swtpm" ps && lib.elem "dnsmasq" ps
      )
      "libvirt shells out to dnsmasq by name for its default NAT network -- the only network a bridge-less host has -- and it is an OPTIONAL pacman dependency, so nothing else will have pulled it in. got: ${builtins.toJSON arch-host.nixvm.host.archPackages}")

    (check "arch-plane/tools-are-not-installed-unless-selected"
      (!(lib.elem "virt-manager" arch-host.nixvm.host.archPackages))
      "got: ${builtins.toJSON arch-host.nixvm.host.archPackages}")

    (check "arch-plane/selected-tools-reach-the-pacman-list"
      (
        let ps = arch-tools.nixvm.host.archPackages; in
        lib.all (p: lib.elem p ps) [ "virt-manager" "virt-install" "virt-viewer" "guestfs-tools" "cloud-image-utils" "osinfo-db" ]
      )
      "got: ${builtins.toJSON arch-tools.nixvm.host.archPackages}")

    (check "arch-plane/disabled-host-publishes-no-packages"
      (arch-disabled.nixvm.host.archPackages == [ ] && arch-disabled.nixvm.host.aurPackages == [ ])
      "a host that never enabled the stance must publish an empty list, not the catalogue. got: ${builtins.toJSON arch-disabled.nixvm.host.archPackages}")

    # A null reaching the pacman list is not a cosmetic defect: `pacman -S` is handed a literal
    # "null", fails on "target not found", and takes every other package in the same converge
    # down with it.
    (check "arch-plane/package-lists-never-contain-a-null"
      (
        let
          ps = arch-tools.nixvm.host.archPackages ++ arch-tools.nixvm.host.aurPackages
            ++ arch-foreign.nixvm.host.archPackages;
        in
          !(builtins.elem null ps)
      )
      "got: ${builtins.toJSON (arch-tools.nixvm.host.archPackages ++ arch-tools.nixvm.host.aurPackages)}")

    (check "arch-plane/todays-catalogue-needs-no-aur"
      (arch-tools.nixvm.host.aurPackages == [ ] && arch-foreign.nixvm.host.aurPackages == [ ])
      "got: ${builtins.toJSON arch-tools.nixvm.host.aurPackages}")

    # ── the Arch plane's own delivery of pools and remotes ────────────────────────────────────
    (check "arch-plane/pool-units-use-the-distro-virsh"
      (
        let script = arch-pool-zvol.systemd.services."nixvm-pool-on-zvol-apply".script; in
        lib.hasInfix "/usr/bin/virsh pool-define-as" script
        && !(lib.hasInfix "/nix/store" script)
      )
      "a nix-provided virsh here would be a second libvirt client talking to the distro daemon over a socket path the two builds need not agree on. got: ${arch-pool-zvol.systemd.services."nixvm-pool-on-zvol-apply".script}")

    # The zvol/nossd gotcha has no `fileSystems` to check against on this plane. Warning is the
    # honest outcome; asserting would claim a check that did not happen, and staying silent would
    # let the hazard through unmentioned on the plane where nobody can check it automatically.
    (check "arch-plane/zvol-backed-pool-warns-rather-than-asserting"
      (
        lib.any (w: lib.hasInfix "nossd" w && lib.hasInfix "on-zvol" w) arch-pool-zvol.warnings
        && lib.filter (a: !a.assertion) arch-pool-zvol.assertions == [ ]
      )
      "warnings: ${builtins.toJSON arch-pool-zvol.warnings}")

    (check "arch-plane/no-warning-for-a-pool-that-is-not-zvol-backed"
      ((evalArch [{
        nixvm.host = { enable = true; storagePools.plain = { path = "/var/lib/libvirt/pools/plain"; }; };
      }]).warnings == [ ])
      "the warning is about an unCHECKABLE claim, not about pools -- a pool that never claimed zvolBacked has nothing to warn about")

    (check "arch-plane/remotes-render-into-etc-libvirt"
      (arch-remote-only.environment.etc ? "libvirt/libvirt.conf")
      "a distro libvirt is built with --sysconfdir=/etc, so this is the file it reads. environment.etc keys: ${builtins.toJSON (builtins.attrNames arch-remote-only.environment.etc)}")

    (check "arch-plane/remotes-render-the-declared-uri-as-an-alias"
      (
        let t = arch-remote-only.environment.etc."libvirt/libvirt.conf".text; in
        lib.hasInfix "uri_aliases" t && lib.hasInfix ''"vmhost=qemu+ssh://root@vmhost.example/system"'' t
      )
      "got: ${arch-remote-only.environment.etc."libvirt/libvirt.conf".text}")

    # Driving someone else's hypervisor and being one are separate capabilities: this fixture
    # sets `remotes` with `enable` left false, and must get the alias file and NO packages.
    (check "arch-plane/remotes-do-not-require-the-host-stance"
      (
        (arch-remote-only.environment.etc ? "libvirt/libvirt.conf")
        && arch-remote-only.nixvm.host.archPackages == [ ]
      )
      "arch packages: ${builtins.toJSON arch-remote-only.nixvm.host.archPackages}")

    (check "arch-plane/no-remotes-means-the-distro-file-is-left-alone"
      (!(arch-host.environment.etc ? "libvirt/libvirt.conf"))
      "the path is owned by the distro's own libvirt package -- taking it over unasked would produce a .pacnew on the next upgrade for a host that declared no remote at all. environment.etc keys: ${builtins.toJSON (builtins.attrNames arch-host.environment.etc)}")

    # ══ lib/resolve.nix, driven with fixtures the real catalogue has no instance of ═══════════
    (check "resolve/arch-list-excludes-aur-entries"
      (resolve.archPackages allEntries == [ "repo" "daemonish" ])
      "got: ${builtins.toJSON (resolve.archPackages allEntries)}")

    (check "resolve/aur-list-holds-only-aur-entries"
      (resolve.aurPackages allEntries == [ "aurthing" ])
      "got: ${builtins.toJSON (resolve.aurPackages allEntries)}")

    # A null nixpkgs attribute is a POSITIVE statement here ("the libvirtd module delivers this"),
    # unlike a null pacman name, which would be a catalogue defect. So it must be dropped from the
    # nixpkgs list silently and NOT reported as a problem.
    (check "resolve/nixpkgs-list-drops-null-attributes-silently"
      (resolve.nixpkgsNames allEntries == [ "repo" "aurthing" ])
      "got: ${builtins.toJSON (resolve.nixpkgsNames allEntries)}")

    (check "resolve/qemu-targets-keep-the-native-ones-and-deduplicate"
      (
        resolve.qemuTargets [ "i386-softmmu" "x86_64-softmmu" ] [
          { name = "a"; qemuTargets = [ "aarch64-softmmu" ]; }
          { name = "b"; qemuTargets = [ "aarch64-softmmu" "arm-softmmu" ]; }
        ] == [ "i386-softmmu" "x86_64-softmmu" "aarch64-softmmu" "arm-softmmu" ]
      )
      "got: ${builtins.toJSON (resolve.qemuTargets [ "i386-softmmu" "x86_64-softmmu" ] [{ name = "a"; qemuTargets = [ "aarch64-softmmu" ]; } { name = "b"; qemuTargets = [ "aarch64-softmmu" "arm-softmmu" ]; }])}")

    (check "resolve/alias-name-rules-accept-and-reject"
      (resolve.aliasNameOk "vm-host_2" && !(resolve.aliasNameOk "vm host") && !(resolve.aliasNameOk "vm.host"))
      "libvirt stops reading an alias at the first character outside [a-zA-Z0-9_-]")

    (check "resolve/uri-rules-reject-a-quote-and-a-newline"
      (resolve.uriOk "qemu+ssh://root@h/system"
        && !(resolve.uriOk ''qemu+ssh://root@h"/system'')
        && !(resolve.uriOk "qemu+ssh://root@h/system\nuri_default = \"x\""))
      "either character would end the entry early and change what the generated file means")

    # ══ The catalogue's own shape, so a future edit cannot silently break the above ═══════════
    (check "catalogue/every-entry-has-a-pacman-name"
      (
        let entries = lib.concatMap lib.attrValues [ cat.daemon cat.tools cat.architectures ]; in
        lib.all (t: (t.arch or null) != null) entries
      )
      "the Arch plane is the only one that resolves a catalogue row to a package name at all; a row without one is deliverable by nothing there")

    (check "catalogue/daemon-rows-carry-no-nixpkgs-attribute"
      (lib.all (t: (t.nixpkgs or null) == null) (lib.attrValues cat.daemon))
      "every daemon row is delivered on NixOS by virtualisation.libvirtd itself -- a nixpkgs attribute here would put a second copy in systemPackages and give one fact two owners")

    (check "catalogue/every-tool-row-carries-a-nixpkgs-attribute"
      (lib.all (t: (t.nixpkgs or null) != null) (lib.attrValues cat.tools))
      "a selectable tool with no nixpkgs attribute would resolve to silence on the NixOS plane -- the host would declare it and not get it")

    (check "catalogue/every-architecture-row-names-at-least-one-qemu-target"
      (lib.all (a: (a.qemuTargets or [ ]) != [ ]) (lib.attrValues cat.architectures))
      "the NixOS plane selects architectures by QEMU target, not by package name -- a row with no target adds a pacman package on one plane and nothing at all on the other")

    (check "catalogue/architecture-rows-and-their-targets-agree-in-shape"
      (lib.all (a: lib.all (t: lib.hasSuffix "-softmmu" t) a.qemuTargets) (lib.attrValues cat.architectures))
      "a `*-user` target is userspace binary emulation (Arch's qemu-user), a different capability entirely from running a guest machine -- this module selects system emulation only")

    # x86 is deliberately absent from the architecture table: it is the host's own, always built
    # on both planes, and must not be something a host can switch off by omitting it from a list.
    (check "catalogue/the-host-architecture-is-not-selectable"
      (!(cat.architectures ? x86) && !(cat.architectures ? x86_64) && !(cat.architectures ? i386))
      "architecture keys: ${builtins.toJSON (lib.attrNames cat.architectures)}")
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
