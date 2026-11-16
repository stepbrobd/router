{ pkgs
, lib
, cases
, invalidCases
, package
}:
let
  fixture = ../../examples/bird/credentials.example.conf;
  check =
    name: text:
    let
      original = pkgs.writeText "bird-${name}-emitted.conf" text;
      parseable = pkgs.writeText "bird-${name}-parser.conf" (
        lib.replaceStrings [ "/run/bird/example-credentials.conf" ] [ "${fixture}" ] text
      );
    in
    ''
      mkdir -p "$out/${name}"
      cp ${original} "$out/${name}/emitted.conf"
      cp ${parseable} "$out/${name}/parser.conf"
      bird -p -c ${parseable}
    '';
in
pkgs.runCommand "bird-parser" { nativeBuildInputs = [ package ]; } ''
  export LC_ALL=C
  mkdir -p "$out"
  cp ${fixture} "$out/synthetic-credentials.conf"
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList check cases)}
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: text:
      let source = pkgs.writeText "bird-invalid-${name}.conf" text;
      in ''
        if bird -p -c ${source} > "$out/rejected-${name}.log" 2>&1; then
          status=0
        else
          status=$?
        fi
        if [ "$status" -ne 1 ]; then
          cat "$out/rejected-${name}.log" >&2
          echo "BIRD returned $status instead of a configuration error for ${name}" >&2
          exit 1
        fi
      '')
    invalidCases)}
''
