{ pkgs
, lib
, cases
}:
let
  fixture = ../../examples/bird/credentials.example.conf;
  check =
    name: text:
    let
      original = pkgs.writeText "bird-${name}-emitted.conf" text;
      parseable = pkgs.writeText "bird-${name}-parser.conf" (
        builtins.replaceStrings [ "/run/bird/example-credentials.conf" ] [ "${fixture}" ] text
      );
    in
    ''
      mkdir -p "$out/${name}"
      cp ${original} "$out/${name}/emitted.conf"
      cp ${parseable} "$out/${name}/parser.conf"
      bird -p -c ${parseable}
    '';
in
pkgs.runCommand "bird-parser" { nativeBuildInputs = [ pkgs.bird3 ]; } ''
  export LC_ALL=C
  mkdir -p "$out"
  cp ${fixture} "$out/synthetic-credentials.conf"
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList check cases)}
''
