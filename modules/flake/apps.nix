{ inputs, ... }:
{
  perSystem = { config, lib, pkgs, ... }: {
    apps.generate.program = pkgs.writeShellApplication {
      name = "generate";
      runtimeInputs = [ pkgs.git ];
      text = ''
        cd "$(git rev-parse --show-toplevel)"
        ${lib.getExe config.packages.default} generate ${inputs.bird} --output generated/bird
      '';
    };
  };
}
