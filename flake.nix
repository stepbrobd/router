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

  outputs =
    inputs:
    let
      lib = with inputs; builtins // nixpkgs.lib // parts.lib;
    in
    inputs.parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      flake.nixosModules =
        let
          moduleFrom = path: lib.modules.importApply path {
            std = lib;
            router = import ./lib/router.nix { std = lib; };
          };
        in
        { bird2 = moduleFrom ./modules/providers/bird2; };

      perSystem =
        { pkgs, system, inputs', ... }:
        {
          _module.args = {
            inherit lib;
            pkgs = import inputs.nixpkgs { inherit system; };
          };

          formatter = pkgs.writeShellScriptBin "formatter" ''
            set -eoux pipefail
            shopt -s globstar
            ${lib.getExe pkgs.deno} fmt .
            ${lib.getExe pkgs.nixpkgs-fmt} .
          '';

          checks = {
            bird2 = import ./modules/providers/bird2/tests {
              self = inputs.self;
              inherit pkgs;
              std = lib;
              router = import ./lib/router.nix { std = lib; };
            };
          };

          packages = {
            default =
              let
                mkSearchForModule =
                  modules: baseHref:
                  inputs'.search.packages.mkSearch {
                    inherit modules baseHref;
                    urlPrefix = "https://github.com/stepbrobd/router/blob/master/";
                  };
                mkSite = baseHref:
                  pkgs.linkFarm "ghp" (
                    lib.mapAttrsToList
                      (name: value: {
                        inherit name;
                        path = mkSearchForModule [ value ] "${baseHref}/${name}/";
                      })
                      inputs.self.nixosModules
                  );
              in
              (mkSite "/router").overrideAttrs (_: {
                passthru = { inherit mkSearchForModule mkSite; };
              });
          };
        };
    };
}
