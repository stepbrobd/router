{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  inherit (common) blockOptions;

  mrtDumpType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 110;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      table = std.mkOption { type = std.types.str; };
      filename = std.mkOption { type = std.types.str; };
      period = std.mkOption { type = std.types.int; };
    };
  };

in
{
  inherit mrtDumpType;
}
