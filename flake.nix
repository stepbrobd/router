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
          moduleFrom = path: lib.modules.importApply path { inherit lib; };
        in
        {
          default = moduleFrom ./modules;
          alpha = moduleFrom ./modules/alpha;
        };

      perSystem =
        { pkgs, system, inputs', self', ... }:
        {
          _module.args = {
            inherit lib;
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [
                (_: _: {
                  typst =
                    inputs'.nixpkgs.legacyPackages.typst.withPackages
                      (ps: with ps; [ polylux ]);
                })
              ];
            };
          };

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
                  pkgs.linkFarm "ghp" ((
                    lib.mapAttrsToList
                      (name: value: {
                        inherit name;
                        path = mkSearchForModule [ value ] "${baseHref}/${name}/";
                      })
                      inputs.self.nixosModules
                  ) ++ [{ name = "slides.pdf"; path = self'.packages.slides; }]);
              in
              (mkSite "/router").overrideAttrs (_: {
                passthru = { inherit mkSearchForModule mkSite; };
              });

            slides = pkgs.stdenvNoCC.mkDerivation {
              name = "slides";
              version = with inputs; self.shortRev or self.dirtyShortRev;
              src = ./docs;
              nativeBuildInputs = with pkgs; [ typst ];
              buildPhase = "typst compile main.typ main.pdf";
              installPhase = "mv main.pdf $out";
            };
          };
        };
    };
}
