{ pkgs
, lib
, router
, self
}:
let
  evaluation = import ./evaluation.nix {
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
lib.optionalAttrs (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.bird3) {
  evaluation = evaluation.derivation;
  parser = import ./parser.nix {
    inherit pkgs lib;
    cases = evaluation.parserCases;
  };
  bgp = vm false;
  ipv4-over-ipv6 = vm true;
}
