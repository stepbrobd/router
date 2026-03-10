{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  filter = import ./filter.nix { inherit std router; };
  inherit (common) blockOptions;
  inherit (filter) filterType;

  aggregatorType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 70;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      table = std.mkOption { type = std.types.str; };
      peer = std.mkOption { type = std.types.str; };
      export.filter = std.mkOption {
        type = std.types.nullOr filterType;
        default = null;
      };
    };
  };

in
{
  inherit aggregatorType;
}
