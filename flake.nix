{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.systems.url = "github:nix-systems/triplet";
  inputs.parts.url = "github:hercules-ci/flake-parts";
  inputs.parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  inputs.autopilot.url = "github:stepbrobd/autopilot";
  inputs.autopilot.inputs.nixpkgs.follows = "nixpkgs";
  inputs.autopilot.inputs.parts.follows = "parts";
  inputs.autopilot.inputs.systems.follows = "systems";
  inputs.bird.url = "gitlab:labs/bird/thread-next?host=gitlab.nic.cz";
  inputs.bird.flake = false;
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
    };
}
