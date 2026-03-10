{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  filter = import ./filter.nix { inherit std router; };
  inherit (common) blockOptions;
  inherit (filter) filterType;

  ripInstanceType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 90;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      ipv4 = std.mkOption {
        type = std.types.bool;
        default = true;
      };
      ipv6 = std.mkOption {
        type = std.types.bool;
        default = false;
      };
      interfaces = std.mkOption {
        type = std.types.listOf std.types.str;
        default = [ ];
      };
      import.filter = std.mkOption {
        type = std.types.nullOr filterType;
        default = null;
      };
      export.filter = std.mkOption {
        type = std.types.nullOr filterType;
        default = null;
      };
    };
  };

in
{
  inherit ripInstanceType;
}
