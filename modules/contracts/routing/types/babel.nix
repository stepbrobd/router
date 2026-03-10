{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  filter = import ./filter.nix { inherit std router; };
  inherit (common) blockOptions;
  inherit (filter) filterType;

  babelInterfaceType = std.types.submodule {
    options = {
      type = std.mkOption {
        type = router.types.babelChannelType;
        default = router.babel.wired;
      };
      rxcost = std.mkOption { type = std.types.nullOr std.types.int; default = null; };
      hello = std.mkOption { type = std.types.nullOr std.types.int; default = null; };
      update = std.mkOption { type = std.types.nullOr std.types.int; default = null; };
    };
  };

  babelInstanceType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 90;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      interfaces = std.mkOption {
        type = std.types.attrsOf babelInterfaceType;
        default = { };
      };
      ipv4 = {
        import.filter = std.mkOption {
          type = std.types.nullOr filterType;
          default = null;
        };
        export.filter = std.mkOption {
          type = std.types.nullOr filterType;
          default = null;
        };
      };
      ipv6 = {
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
  };

in
{
  inherit babelInstanceType;
}
