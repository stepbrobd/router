{ lib }:
let
  extendedLib = lib.extend (_: prev: {
    router = (prev.router or { }) // { bird = backend; };
  });
  backend = import ./runtime.nix {
    lib = extendedLib;
    inventory = lib.importJSON ../../../generated/bird/grammar.json;
  };
in
backend
