{
  description = "A declarative home for persistent, hosted VM workloads on NixOS -- libvirt/QEMU-KVM host stance plus guest definitions as data. The peer of nixk3s: nixk3s is bare metal running k3s, nixvm is bare metal running VMs, and neither owns the other.";

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
      # The hypervisor host: libvirtd, the declared bridge guests attach to, optional
      # file-backed storage pools. See modules/vm-host/default.nix's own SCOPE block.
      nixosModules.vm-host = ./modules/vm-host;

      # Guest VM definitions, as data, rendered to libvirt domain XML and kept declared.
      # See modules/guests/default.nix's own SCOPE block -- and its "ALWAYS COMPOSED
      # WITH modules/vm-host" note, which is why `default` below imports both together.
      #
      # `probeFact` closed over here, before the module system ever sees the result -- see the
      # input comment above. The exported value is a plain module function taking the usual
      # `{ lib, config, ... }`; nothing about consuming it changes.
      nixosModules.guests = import ./modules/guests { inherit (nixhost.lib) probeFact; };

      nixosModules.default = { imports = [ self.nixosModules.vm-host self.nixosModules.guests ]; };

      # The pure XML-rendering function, exposed so a consumer can inspect or unit-test
      # it without composing a full NixOS system -- same reasoning as nixfs exposing its
      # catalogue.
      lib.mkDomainXML = (import ./lib/domain-xml.nix { inherit lib; }).mkDomainXML;

      checks = forAllSystems (system:
        import ./checks {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit lib system;
          vmHostModule = self.nixosModules.vm-host;
          guestsModule = self.nixosModules.guests;
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
