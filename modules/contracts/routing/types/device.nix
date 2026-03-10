{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  inherit (common) blockOptions;

  deviceType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 30;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      scanTime = std.mkOption {
        type = std.types.int;
        default = 10;
      };
    };
  };

in
{
  inherit deviceType;
}
