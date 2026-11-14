{ lib }:
lib.loadAll {
  dir = ./.;
  transformer = lib.kebabToCamel;
  excludes = [ "default.nix" ];
  args = { inherit lib; };
}
