{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.systems.url = "github:nix-systems/triplet";
  inputs.parts.url = "github:hercules-ci/flake-parts";
  inputs.parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  inputs.autopilot.url = "github:stepbrobd/autopilot";
  inputs.autopilot.inputs.nixpkgs.follows = "nixpkgs";
  inputs.autopilot.inputs.parts.follows = "parts";
  inputs.autopilot.inputs.systems.follows = "systems";
  inputs.bird.url = "github:cz-nic/bird/thread-next";
  inputs.bird.flake = false;
  inputs.utils.url = "github:numtide/flake-utils";
  inputs.utils.inputs.systems.follows = "systems";
  inputs.ixx.url = "github:nuschtos/ixx";
  inputs.ixx.inputs.nixpkgs.follows = "nixpkgs";
  inputs.ixx.inputs.flake-utils.follows = "utils";
  inputs.search.url = "github:nuschtos/search";
  inputs.search.inputs.nixpkgs.follows = "nixpkgs";
  inputs.search.inputs.flake-utils.follows = "utils";
  inputs.search.inputs.ixx.follows = "ixx";
  inputs.search.inputs.nix-index-database.inputs.nixpkgs.follows = "nixpkgs";
  outputs = inputs: inputs.autopilot.lib.mkFlake
    {
      inherit inputs;

      autopilot = {
        lib = {
          path = ./lib;
          extender = inputs.nixpkgs.lib;
          extensions = with inputs; [ autopilot.lib parts.lib ];
        };
        nixpkgs.instances.pkgs = inputs.nixpkgs;
        parts.path = ./modules/flake;
      };
    }
    {
      systems = import inputs.systems;
      perSystem = { pkgs, ... }: {
        packages.default = pkgs.callPackage ./. { };
      };
    };
}
