{ std, router, ... }:

let
  common = import ./common.nix { inherit std router; };
  inherit (common) prefixListType;

  matchType = std.types.submodule {
    options = {
      roaStatus = std.mkOption {
        type = std.types.nullOr router.types.roaStatusType;
        default = null;
      };
      prefixIn = std.mkOption {
        type = std.types.nullOr prefixListType;
        default = null;
      };
      bgpAsn = std.mkOption {
        type = std.types.nullOr std.types.int;
        default = null;
      };
      bgpPathLength = std.mkOption {
        type = std.types.nullOr (std.types.submodule {
          options = {
            op = std.mkOption { type = router.types.cmpType; };
            value = std.mkOption { type = std.types.int; };
          };
        });
        default = null;
      };
      communityHas = std.mkOption {
        type = std.types.nullOr (std.types.submodule {
          options = {
            asn = std.mkOption { type = std.types.int; };
            value = std.mkOption { type = std.types.int; };
          };
        });
        default = null;
      };
    };
  };

  actionType = std.types.submodule {
    options = {
      decision = std.mkOption {
        type = std.types.nullOr router.types.policyType;
        default = null;
      };
      setLocalPref = std.mkOption {
        type = std.types.nullOr std.types.int;
        default = null;
      };
      setMed = std.mkOption {
        type = std.types.nullOr std.types.int;
        default = null;
      };
      prependPath = std.mkOption {
        type = std.types.nullOr (std.types.submodule {
          options = {
            asn = std.mkOption { type = std.types.int; };
            count = std.mkOption { type = std.types.int; default = 1; };
          };
        });
        default = null;
      };
      addCommunity = std.mkOption {
        type = std.types.nullOr (std.types.submodule {
          options = {
            asn = std.mkOption { type = std.types.int; };
            value = std.mkOption { type = std.types.int; };
          };
        });
        default = null;
      };
      deleteCommunity = std.mkOption {
        type = std.types.nullOr (std.types.submodule {
          options = {
            asn = std.mkOption { type = std.types.int; };
            value = std.mkOption { type = std.types.int; };
          };
        });
        default = null;
      };
    };
  };

  ruleType = std.types.submodule {
    options = {
      match = std.mkOption {
        type = matchType;
        default = { };
      };
      action = std.mkOption {
        type = actionType;
      };
    };
  };

  filterType = std.types.submodule {
    options.rules = std.mkOption {
      type = std.types.listOf ruleType;
    };
  };

in
{
  inherit matchType actionType ruleType filterType;
}
