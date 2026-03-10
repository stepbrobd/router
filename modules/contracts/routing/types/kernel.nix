{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  filter = import ./filter.nix { inherit std router; };
  inherit (common) blockOptions;
  inherit (filter) filterType;

  kernelChannelType = std.types.submodule {
    options = {
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

  kernelType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 50;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      scanTime = std.mkOption {
        type = std.types.int;
        default = 10;
      };
      learn = std.mkOption {
        type = std.types.bool;
        default = false;
      };
      persist = std.mkOption {
        type = std.types.bool;
        default = false;
      };
      ipv4 = std.mkOption {
        type = std.types.nullOr kernelChannelType;
        default = null;
      };
      ipv6 = std.mkOption {
        type = std.types.nullOr kernelChannelType;
        default = null;
      };
    };
  };

in
{
  inherit kernelType;
}
