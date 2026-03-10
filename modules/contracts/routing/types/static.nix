{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  inherit (common) blockOptions;

  staticRouteType = std.types.submodule {
    options = {
      prefix = std.mkOption { type = std.types.str; };
      action = std.mkOption {
        type = router.types.routeActionType;
        default = router.route.blackhole;
      };
    };
  };

  staticType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 60;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      ipv4.routes = std.mkOption {
        type = std.types.listOf staticRouteType;
        default = [ ];
      };
      ipv6.routes = std.mkOption {
        type = std.types.listOf staticRouteType;
        default = [ ];
      };
    };
  };

in
{
  inherit staticType;
}
