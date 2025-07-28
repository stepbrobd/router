{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.systems.url = "github:nix-systems/default";
  inputs.parts.url = "github:hercules-ci/flake-parts";
  inputs.parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  inputs.utils.url = "github:numtide/flake-utils";
  inputs.utils.inputs.systems.follows = "systems";
  inputs.ixx.url = "github:nuschtos/ixx";
  inputs.ixx.inputs.nixpkgs.follows = "nixpkgs";
  inputs.ixx.inputs.flake-utils.follows = "utils";
  inputs.search.url = "github:nuschtos/search";
  inputs.search.inputs.nixpkgs.follows = "nixpkgs";
  inputs.search.inputs.flake-utils.follows = "utils";
  inputs.search.inputs.ixx.follows = "ixx";

  outputs = inputs:
    let
      lib = with inputs; builtins // nixpkgs.lib // parts.lib;
    in
    inputs.parts.lib.mkFlake
      { inherit inputs; }
      {
        systems = import inputs.systems;

        flake.nixosModules.default =
          lib.modules.importApply
            ./module.nix
            { inherit lib; };

        flake.nixosModules.alpha =
          lib.modules.importApply
            ./alpha
            { inherit lib; };

        perSystem = { inputs', pkgs, ... }: {
          _module.args = { inherit lib; };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [ typst ];
          };

          formatter = pkgs.writeShellScriptBin "formatter" ''
            set -eoux pipefail
            shopt -s globstar
            ${lib.getExe pkgs.deno} fmt .
            ${lib.getExe pkgs.nixpkgs-fmt} .
            ${lib.getExe pkgs.typstfmt} **/*.typ
          '';

          packages.default = inputs'.search.packages.mkSearch {
            modules = [ inputs.self.nixosModules.default ];
            urlPrefix = "https://github.com/stepbrobd/router/blob/master/";
            baseHref = "/router/";
          };
        };
      };
}
