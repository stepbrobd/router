{ pkgs, self }:
pkgs.runCommand "bird-generated"
{
  nativeBuildInputs = [ self.packages.${pkgs.stdenv.hostPlatform.system}.default pkgs.diffutils ];
} ''
  router generate ${self.inputs.bird} --output actual
  diff -r ${../../generated/bird} actual
  touch "$out"
''
