{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  filter = import ./filter.nix { inherit std router; };
  inherit (common) blockOptions;
  inherit (filter) filterType;

  channelType = std.types.submodule {
    options = {
      import.filter = std.mkOption {
        type = std.types.nullOr filterType;
        default = null;
        description = "Import filter. null means import none.";
      };
      export.filter = std.mkOption {
        type = std.types.nullOr filterType;
        default = null;
        description = "Export filter. null means export none.";
      };
      addPaths = std.mkOption {
        type = router.types.addPathsType;
        default = router.addPaths.off;
      };
    };
  };

  bgpSessionType = std.types.submodule {
    options = blockOptions // {
      order = std.mkOption {
        type = std.types.int;
        default = 100;
        description = "Numeric priority for ordering in generated config. Lower values appear first.";
      };
      neighbor = {
        asn = std.mkOption { type = std.types.int; };
        ipv4 = std.mkOption { type = std.types.nullOr std.types.str; default = null; };
        ipv6 = std.mkOption { type = std.types.nullOr std.types.str; default = null; };
      };
      source = {
        ipv4 = std.mkOption { type = std.types.nullOr std.types.str; default = null; };
        ipv6 = std.mkOption { type = std.types.nullOr std.types.str; default = null; };
      };
      localAsn = std.mkOption {
        type = std.types.nullOr std.types.int;
        default = null;
        description = "Local ASN override. null inherits from top-level asn.";
      };
      password = std.mkOption {
        type = std.types.nullOr std.types.str;
        default = null;
      };
      type = {
        ipv4 = std.mkOption {
          type = router.types.peeringType;
          default = router.peering.disabled;
        };
        ipv6 = std.mkOption {
          type = router.types.peeringType;
          default = router.peering.disabled;
        };
      };
      multiprotocol = std.mkOption {
        type = std.types.nullOr router.types.multiprotocolType;
        default = null;
      };
      gracefulRestart = std.mkOption {
        type = std.types.bool;
        default = true;
      };
      bfd = std.mkOption {
        type = std.types.bool;
        default = false;
      };
      ipv4 = std.mkOption {
        type = std.types.nullOr channelType;
        default = null;
      };
      ipv6 = std.mkOption {
        type = std.types.nullOr channelType;
        default = null;
      };
    };
  };

in
{
  inherit bgpSessionType;
}
