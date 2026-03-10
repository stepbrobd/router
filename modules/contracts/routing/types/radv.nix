{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  inherit (common) blockOptions;

  radvPrefixType = std.types.submodule {
    options = {
      prefix = std.mkOption { type = std.types.str; };
      onlink = std.mkOption { type = std.types.bool; default = true; };
      autonomous = std.mkOption { type = std.types.bool; default = true; };
    };
  };

  radvInterfaceType = std.types.submodule {
    options = {
      prefixes = std.mkOption {
        type = std.types.listOf radvPrefixType;
        default = [ ];
      };
      managed = std.mkOption { type = std.types.bool; default = false; };
      other = std.mkOption { type = std.types.bool; default = false; };
      mtu = std.mkOption { type = std.types.nullOr std.types.int; default = null; };
      maxRtrAdvInterval = std.mkOption { type = std.types.int; default = 600; };
      minRtrAdvInterval = std.mkOption { type = std.types.int; default = 200; };
      rdnss = std.mkOption {
        type = std.types.listOf std.types.str;
        default = [ ];
      };
    };
  };

  radvInstanceType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 90;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      interfaces = std.mkOption {
        type = std.types.attrsOf radvInterfaceType;
        default = { };
      };
    };
  };

in
{
  inherit radvInstanceType;
}
