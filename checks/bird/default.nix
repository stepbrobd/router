{ pkgs
, lib
, router
, self
}:
let
  evaluation = import ./generated.nix {
    inherit
      pkgs
      lib
      router
      self
      ;
  };
  vm =
    crossFamily:
    import ./vm.nix {
      inherit
        pkgs
        lib
        router
        self
        crossFamily
        ;
    };
in
{
  evaluation = evaluation.derivation;
  generation = import ./generation.nix { inherit pkgs self; };
} // lib.optionalAttrs
  (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.bird3)
  {
    parser = import ./parser.nix {
      inherit pkgs lib;
      package = self.packages.${pkgs.stdenv.hostPlatform.system}.bird;
      cases = evaluation.parserCases;
      invalidCases = evaluation.invalidParserCases;
    };
    bgp = vm false;
    ipv4-over-ipv6 = vm true;
  }
