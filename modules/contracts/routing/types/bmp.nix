{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  inherit (common) blockOptions;

  bmpStationType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 110;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      remote = std.mkOption { type = std.types.str; };
      port = std.mkOption { type = std.types.int; };
      mode = std.mkOption {
        type = router.types.bmpModeType;
        default = router.bmp.prePolicy;
      };
    };
  };

in
{
  inherit bmpStationType;
}
