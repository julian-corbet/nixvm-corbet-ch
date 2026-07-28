# lib/domain-xml.nix
#
# Pure rendering: (name, guest, bridge) -> a libvirt domain XML document, as a plain
# string. No `config`, no NixOS module system, no derivations -- this file only ever sees
# plain Nix values, so it is testable in total isolation (see checks/default.nix's
# "xml-render/*" group, which calls it directly with hand-built fixtures and never builds
# a NixOS system to do it) and reusable by anything that wants to hand libvirt a domain
# definition, not only modules/guests. Same reasoning as nixfs's lib/catalogue.nix: a
# `lib`-only file is cheap enough that nothing importing it pays for a NixOS evaluation it
# doesn't need.
#
# modules/guests/default.nix is the one caller in this repo. It supplies the realized
# guest submodule value (every option already resolved to a concrete value -- this file
# never sees an unset option) and the ALREADY-RESOLVED bridge name (the guest's own
# `network.bridge` override, or `nixvm.host.bridge`, resolved by the caller -- this file
# does not repeat that fallback decision).
{ lib }:

let
  esc = lib.escapeXML;

  diskEntry = devName: disk:
    if disk.sourceType == "zvol" then ''
      <disk type='block' device='disk'>
        <driver name='qemu' type='raw' cache='none' io='native'/>
        <source dev='${esc disk.source}'/>
        <target dev='${esc devName}' bus='${esc disk.bus}'/>
      </disk>
    '' else ''
      <disk type='file' device='disk'>
        <driver name='qemu' type='qcow2' cache='none'/>
        <source file='${esc disk.source}'/>
        <target dev='${esc devName}' bus='${esc disk.bus}'/>
      </disk>
    '';

  macLine = mac: lib.optionalString (mac != null) "<mac address='${esc mac}'/>\n";

  # No GPU passthrough anywhere in this template, on purpose -- see modules/guests'
  # own SCOPE block for why. tpm-crb + the "2.0" backend version is what a guest
  # OS that gates its own install on a TPM (Windows 11 being the concrete case
  # this repo was built against) actually looks for.
  tpmBlock = enable: lib.optionalString enable ''
    <tpm model='tpm-crb'>
      <backend type='emulator' version='2.0'/>
    </tpm>
  '';

  # Loopback-only by construction (see the option doc): this is a fallback
  # console for installing the guest OS and configuring its OWN remote-access
  # story (RDP or otherwise) -- never the guest's ongoing remote-access path.
  graphicsBlock = g: lib.optionalString g.enable ''
    <graphics type='${esc g.type}' listen='${esc g.listenAddress}' autoport='yes'/>
  '';

  # libvirt's own firmware auto-select syntax (`<os firmware='efi'>`) -- this
  # avoids hand-pointing at an OVMF_CODE/OVMF_VARS pair ourselves, which is a
  # nixpkgs-version-specific path this module has no business hardcoding.
  osFirmwareAttr = firmware: lib.optionalString (firmware == "uefi") " firmware='efi'";
in
{
  mkDomainXML = { name, guest, bridge }:
    ''
      <domain type='kvm'>
        <name>${esc name}</name>
        <memory unit='MiB'>${toString guest.memoryMiB}</memory>
        <currentMemory unit='MiB'>${toString guest.memoryMiB}</currentMemory>
        <vcpu placement='static'>${toString guest.cpu.cores}</vcpu>
        <os${osFirmwareAttr guest.firmware}>
          <type arch='x86_64' machine='q35'>hvm</type>
        </os>
        <features>
          <acpi/>
          <apic/>
        </features>
        <cpu mode='${esc guest.cpu.model}'/>
        <clock offset='${esc guest.clockOffset}'/>
        <on_poweroff>destroy</on_poweroff>
        <on_reboot>restart</on_reboot>
        <on_crash>restart</on_crash>
        <devices>
      ${lib.concatStringsSep "" (lib.mapAttrsToList diskEntry guest.disks)}
          <interface type='bridge'>
            <source bridge='${esc bridge}'/>
            <model type='${esc guest.network.model}'/>
            ${macLine guest.network.macAddress}</interface>
          <rng model='virtio'>
            <backend model='random'>/dev/urandom</backend>
          </rng>
          <video>
            <model type='virtio'/>
          </video>
      ${tpmBlock guest.tpm.enable}${graphicsBlock guest.graphics}    </devices>
      ${guest.extraDomainXML}
      </domain>
    '';
}
