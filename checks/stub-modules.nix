# checks/stub-modules.nix
#
# A tiny, self-contained stand-in for nixhost -- NOT the real repo -- declaring just enough
# option surface to exercise the "declared" branch of modules/guests's defensive read
# (`config.nixhost.environments or { }`) for real.
#
# WHY A STAND-IN, NOT THE REAL SIBLING REPO. Same reasoning nixlxc's own
# checks/stub-modules.nix gives for its identical stub: nixhost is a real, separate repo,
# routinely under concurrent edit elsewhere in this family, and a `git+file://` flake input
# would resolve against whatever that other session's working tree happens to look like at the
# exact moment `nix flake check` runs here -- exactly the kind of cross-session flakiness this
# repo's own tests must never depend on. A minimal stand-in matching only the fields this
# repo's own code actually reads (`environments.<name>.kind`,
# `.resources.ram.limitMiB`/`.resources.cpu.quotaCores`) proves the resolution/gating logic just
# as faithfully, without caring what the real repo's schema looks like on any given day.
{ lib }:

{
  # Mirrors nixhost's own `modules/nixhost.nix` `environments.<name>` shape, narrowed to the
  # three fields `modules/guests/default.nix` actually reads. `kind` carries a default HERE
  # (unlike the real nixhost, which requires it explicitly with no default) purely so a fixture
  # that only cares about the ram/cpu envelope doesn't also have to restate `kind` every time.
  hostEnvStub = { ... }: {
    options.nixhost.environments = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          kind = lib.mkOption { type = lib.types.str; default = "vm"; };
          resources.ram.limitMiB = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; };
          resources.cpu.quotaCores = lib.mkOption { type = lib.types.nullOr (lib.types.either lib.types.int lib.types.float); default = null; };
        };
      });
      default = { };
    };
  };

  # THE DECOY: nixhost's real option surface, renamed. Composes the SAME top-level `nixhost`
  # namespace the real sibling would (so `config ? nixhost` reads true -- state (a), "not
  # composed at all", must NOT be what this fixture exercises), with the specific path
  # `modules/guests/default.nix`'s own probe reads (`environments`) missing, renamed to a
  # plausible neighbour -- proving state (c), composed-but-moved, actually warns through the
  # real module (see `checks/default.nix`'s `fact-wiring/*` group).
  hostEnvironmentsRenamedStub = { ... }: {
    options.nixhost.workloads = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Stand-in for nixhost having renamed environments to workloads.";
    };
  };
}
