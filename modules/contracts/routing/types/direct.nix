{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  inherit (common) blockOptions;

  directType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 40;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      interfaces = std.mkOption {
        type = std.types.listOf std.types.str;
        default = [ "*" ];
      };
      ipv4 = std.mkOption {
        type = std.types.bool;
        default = true;
      };
      ipv6 = std.mkOption {
        type = std.types.bool;
        default = true;
      };
    };
  };

in
{
  inherit directType;
}
