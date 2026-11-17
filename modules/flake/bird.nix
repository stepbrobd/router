{ inputs, lib, ... }:
{
  perSystem = { pkgs, ... }: {
    # nixpkgs bird3 built from the pinned source, on the platforms nixpkgs builds bird3 for
    packages = lib.optionalAttrs (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.bird3) {
      bird = pkgs.bird3.overrideAttrs (_: {
        version = lib.removeSuffix "\n" (lib.readFile "${inputs.bird}/VERSION");
        src = inputs.bird;
      });
    };
  };
}
