{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    parts.url = "github:hercules-ci/flake-parts";
    parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    systems.url = "github:nix-systems/default";
    search.url = "github:nuschtos/search";
  };

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

        perSystem = { inputs', pkgs, ... }: {
          _module.args = { inherit lib; };

          devShells.default = pkgs.mkShell {
            packages = [ ];
          };

          formatter = pkgs.nixpkgs-fmt;

          packages.default = inputs'.search.packages.mkSearch {
            modules = [ inputs.self.nixosModules.default ];
            urlPrefix = "https://github.com/stepbrobd/router/blob/master/";
            baseHref = "/router/";
          };
        };
      };
}
