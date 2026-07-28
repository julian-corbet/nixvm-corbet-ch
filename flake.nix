{
  description = "A declarative home for persistent, hosted VM workloads on NixOS -- libvirt/QEMU-KVM host stance plus guest definitions as data. The peer of nixk3s: nixk3s is bare metal running k3s, nixvm is bare metal running VMs, and neither owns the other.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
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
      nixosModules.guests = ./modules/guests;

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
