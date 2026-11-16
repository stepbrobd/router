{ lib
, bird3
, source ? bird3.src
}:
let
  version = lib.removeSuffix "\n" (lib.readFile "${source}/VERSION");
in
bird3.overrideAttrs (_: {
  inherit version;
  src = source;
})
