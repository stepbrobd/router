{ std, router, ... }:

let
  filter = import ./filter.nix { inherit std router; };
  common = import ./common.nix { inherit std router; };
  inherit (common) blockOptions;
  inherit (filter) filterType;

  ospfInterfaceType = std.types.submodule {
    options = {
      hello = std.mkOption { type = std.types.int; default = 10; };
      wait = std.mkOption { type = std.types.int; default = 40; };
      cost = std.mkOption { type = std.types.nullOr std.types.int; default = null; };
      priority = std.mkOption { type = std.types.nullOr std.types.int; default = null; };
    };
  };

  ospfAreaType = std.types.submodule {
    options = {
      type = std.mkOption {
        type = router.types.areaTypeType;
        default = router.area.normal;
      };
      interfaces = std.mkOption {
        type = std.types.attrsOf ospfInterfaceType;
        default = { };
      };
    };
  };

  ospfInstanceType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 90;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      version = std.mkOption {
        type = router.types.ospfVersionType;
      };
      areas = std.mkOption {
        type = std.types.attrsOf ospfAreaType;
        default = { };
      };
      ipv4 = {
        export.filter = std.mkOption {
          type = std.types.nullOr filterType;
          default = null;
        };
        import.filter = std.mkOption {
          type = std.types.nullOr filterType;
          default = null;
        };
      };
      ipv6 = {
        export.filter = std.mkOption {
          type = std.types.nullOr filterType;
          default = null;
        };
        import.filter = std.mkOption {
          type = std.types.nullOr filterType;
          default = null;
        };
      };
    };
  };

in
{
  inherit ospfInstanceType;
}
