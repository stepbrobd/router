{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  inherit (common) blockOptions;

  rpkiValidatorType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 20;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      remote = std.mkOption { type = std.types.str; };
      port = std.mkOption { type = std.types.int; };
      refresh = std.mkOption { type = std.types.int; default = 3600; };
      retry = std.mkOption { type = std.types.int; default = 600; };
      expire = std.mkOption { type = std.types.int; default = 7200; };
    };
  };

  rpkiType = std.types.submodule {
    options = {
      validators = std.mkOption {
        type = std.types.attrsOf rpkiValidatorType;
        default = { };
      };
      tables = {
        ipv4 = std.mkOption { type = std.types.str; default = "roa4"; };
        ipv6 = std.mkOption { type = std.types.str; default = "roa6"; };
      };
    };
  };

in
{
  inherit rpkiType;
}
