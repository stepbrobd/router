{ inputs, lib, ... }:
{
  flake.nixosModules = lib.loadAll {
    dir = ../nixos;
    importer = lib.importApplyWithArgs;
    args = { inherit inputs lib; };
  };
}
