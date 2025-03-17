{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    parts.url = "github:hercules-ci/flake-parts";
    parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    systems.url = "github:nix-systems/default";
  };

  outputs = inputs: inputs.parts.lib.mkFlake { inherit inputs; } {
    systems = import inputs.systems;

    perSystem = { pkgs, ... }: {
      _module.args.lib = with inputs; builtins // nixpkgs.lib // parts.lib;

      devShells.default = pkgs.mkShell {
        packages = [ ];
      };

      formatter = pkgs.nixpkgs-fmt;
    };
  };
}
