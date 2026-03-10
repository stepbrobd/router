{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  inherit (common) blockOptions;

  bfdSessionType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 80;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      neighbor = std.mkOption { type = std.types.str; };
      minRxInterval = std.mkOption { type = std.types.int; default = 300; };
      minTxInterval = std.mkOption { type = std.types.int; default = 300; };
      multiplier = std.mkOption { type = std.types.int; default = 3; };
      interface = std.mkOption {
        type = std.types.nullOr std.types.str;
        default = null;
      };
    };
  };

in
{
  inherit bfdSessionType;
}
