# Examples

Minimal configurations the `checks` in ../checks use to prove the modules compose into a
real NixOS system. Not machines anyone would run: `fileSystems."/"` is `tmpfs`-on-`nodev`
and the bootloader is a stub, deliberately, so these type-check a module rather than
describe hardware. Nothing here names a real host, bridge, pool, or device -- every value
is generic (`examplebr0`, `/dev/zvol/pool/example-guest`, ...).
