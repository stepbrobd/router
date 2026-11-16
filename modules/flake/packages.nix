{ inputs, lib, ... }:
{
  perSystem = { pkgs, ... }:
    let
      packages = lib.loadAll {
        dir = ../../pkgs;
        importer = pkgs.callPackage;
      };
    in
    {
      packages = lib.filterAttrs
        (_: package: lib.meta.availableOn pkgs.stdenv.hostPlatform package)
        (packages // {
          bird = packages.bird.override { source = inputs.bird; };
        });
    };
}
