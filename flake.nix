{
  description = "A declarative home for VM workloads -- a libvirt/QEMU-KVM host stance for NixOS and for distro hosts via system-manager, plus persistent guest definitions as data. The peer of nixk3s: nixk3s is bare metal running k3s, nixvm is bare metal running VMs, and neither owns the other.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # nixhost IS an input, for exactly one thing: `lib.probeFact` (github:julian-corbet/
  # nixhost-corbet-ch, `lib/facts.nix`) -- the shared, plain-function fix for the cross-namespace
  # defensive-read defect class `modules/guests/default.nix`'s own `nixhostEnvironmentsProbe`
  # leans on (see nixhost's own `lib/facts.nix` header). One recipe, not a second copy -- the
  # same fix nixvault/nixnas apply to their own shared f2fs catalogue. `probeFact` is closed over
  # as a plain function argument (below), never `_module.args` -- the same
  # partially-applied-before-the-module-system-sees-it pattern this family already uses for
  # `nixfsCatalogue` (see infra's own flake.nix comment on `mkNixnas` for that precedent) -- so a
  # consumer importing `nixosModules.guests` sees an ordinary module function and never needs to
  # know `nixhost` exists. This is unrelated to how `nixhost.environments` itself is read: that
  # stays a defensive, zero-flake-dependency probe -- only the `probeFact` MECHANISM itself is
  # consumed rather than vendored.
  inputs.nixhost = {
    url = "github:julian-corbet/nixhost-corbet-ch";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixhost }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
      # The hypervisor host on NixOS: libvirtd, the architecture-selected QEMU, the declared
      # bridge guests attach to, optional file-backed storage pools. The policy it implements
      # lives in modules/vm-host/vm-host.nix, whose SCOPE block is the one to read; this entry is
      # the NixOS DELIVERY of it.
      nixosModules.vm-host = ./modules/vm-host/nixos.nix;

      # Guest VM definitions, as data, rendered to libvirt domain XML and kept declared.
      # See modules/guests/default.nix's own SCOPE block -- and its "ALWAYS COMPOSED
      # WITH modules/vm-host" note, which is why `default` below imports both together.
      #
      # `probeFact` closed over here, before the module system ever sees the result -- see the
      # input comment above. The exported value is a plain module function taking the usual
      # `{ lib, config, ... }`; nothing about consuming it changes.
      nixosModules.guests = import ./modules/guests { inherit (nixhost.lib) probeFact; };

      nixosModules.default = { imports = [ self.nixosModules.vm-host self.nixosModules.guests ]; };

      # The SAME hypervisor stance on a distro host managed by system-manager. Not a reduced
      # NixOS module: it is the other delivery of the one policy file, and it sets nothing that
      # only exists on NixOS -- see modules/vm-host/arch.nix's own header for the list of what it
      # deliberately does not touch, and checks/default.nix's "arch-plane/*" group for the proof
      # that the list is accurate rather than aspirational.
      #
      # There is NO systemManagerModules.guests, and that is a boundary rather than an omission:
      # modules/guests renders `virsh define` units against `virtualisation.libvirtd.package` and
      # reads its resource envelope from nixhost. A distro host runs guests it created by hand.
      systemManagerModules.vm-host = ./modules/vm-host/arch.nix;
      systemManagerModules.default = ./modules/vm-host/arch.nix;

      # The pure XML-rendering function, exposed so a consumer can inspect or unit-test
      # it without composing a full NixOS system -- same reasoning as nixfs exposing its
      # catalogue.
      lib.mkDomainXML = (import ./lib/domain-xml.nix { inherit lib; }).mkDomainXML;

      # The toolchain catalogue and the pure channel resolution, for the same reason: a consumer
      # can ask what a selection resolves to on either plane without evaluating a system.
      lib.toolchain = import ./lib/toolchain.nix { };
      lib.resolve = import ./lib/resolve.nix { inherit lib; };

      # EVERY declared system's checks, evaluated from EVERY build platform -- so
      # `checks.x86_64-linux` contains both `eval-tests` (this platform) and
      # `eval-tests-aarch64-linux`, and vice versa.
      #
      # WHY, since it looks like duplication. These are pure EVAL tests, and evaluating a module
      # set for aarch64 needs no aarch64 machine -- but the marker derivation they hang off
      # inherits the platform of whatever `pkgs` built it, so exposing them only under their own
      # system meant `checks.aarch64-linux.eval-tests` could not be BUILT anywhere except on
      # aarch64. `nix flake check --all-systems` on any ordinary x86_64 runner therefore failed
      # with "platform mismatch" -- not a failing check, a check that could not run, which is the
      # same colour of red and a much worse signal.
      #
      # Splitting the two `pkgs` fixes it properly rather than hiding it: the module eval takes
      # the TARGET platform's package set (so the architecture-selection checks really do see an
      # aarch64 host's own QEMU targets), and the marker derivation takes the BUILD platform's.
      # One x86_64 runner now genuinely proves both targets, which `--all-systems` never did.
      checks = forAllSystems (buildSystem:
        lib.listToAttrs (map
          (target: {
            name = if target == buildSystem then "eval-tests" else "eval-tests-${target}";
            value = (import ./checks {
              buildPkgs = nixpkgs.legacyPackages.${buildSystem};
              pkgs = nixpkgs.legacyPackages.${target};
              system = target;
              inherit lib;
              vmHostModule = self.nixosModules.vm-host;
              guestsModule = self.nixosModules.guests;
              archModule = self.systemManagerModules.vm-host;
            }).eval-tests;
          })
          systems));

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
