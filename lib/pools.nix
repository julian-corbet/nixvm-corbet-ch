#
# The file-backed storage-pool apply units, as a pure function of `lib`, a `virsh` path and the
# declared pools -- so both backends render the SAME units and only disagree about where `virsh`
# lives (a store path on NixOS, `/usr/bin/virsh` on a distro plane).
#
# It lives here rather than in either backend for the reason the family applies everywhere: a
# behaviour restated in two files is a behaviour free to drift in one of them, and "the pool
# apply unit is idempotent" is exactly the kind of property that rots quietly when only one copy
# gets the fix.
{ lib }:
{
  # Every step is idempotent and non-destructive: `pool-define-as` on an already-defined pool of
  # the same name UPDATES the definition rather than erroring, `|| true` covers "pool already
  # started" / "already autostarted" so a repeat run never fails the unit, and nothing here ever
  # touches a pool's CONTENTS -- only its libvirt-level definition.
  mkPoolUnits = { virsh, pools }:
    lib.mapAttrs'
      (name: pool: {
        name = "nixvm-pool-${name}-apply";
        value = {
          description = "Declare and keep applied the nixvm storage pool '${name}'";
          after = [ "libvirtd.service" ];
          requires = [ "libvirtd.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = ''
            ${virsh} pool-define-as --name '${name}' dir --target '${pool.path}' || true
            ${virsh} pool-build '${name}' --overwrite || true
            ${virsh} pool-start '${name}' || true
            ${virsh} pool-autostart '${name}' ${if pool.autostart then "" else "--disable"}
          '';
        };
      })
      pools;
}
