{ lib, types }:
let
  inherit (lib) mkOption;
  t = lib.types;
  option = type: default: mkOption { inherit type default; };
  nullable = type: option (t.nullOr type) null;
  address = nullable t.str;
  # a limit replaces its template's limit whole, so an unset action is bird's default even under a template
  limit = nullable (
    t.either (t.enum [ "off" ]) (
      t.submodule {
        options = {
          count = mkOption { type = types.uint; };
          action = nullable (
            t.enum [
              "warn"
              "block"
              "restart"
              "disable"
            ]
          );
        };
      }
    )
  );
  channel = t.submodule {
    options = {
      table = nullable (types.referenceTo "table");
      import = nullable types.policy;
      export = nullable types.policy;
      importLimit = limit;
      receiveLimit = limit;
      exportLimit = limit;
      importKeepFiltered = nullable t.bool;
      preference = nullable types.uint;
      addPaths = nullable (
        t.enum [
          "off"
          "rx"
          "tx"
          "on"
        ]
      );
      nextHopSelf = nullable (
        t.either t.bool (
          t.enum [
            "ibgp"
            "ebgp"
          ]
        )
      );
      nextHopKeep = nullable (
        t.either t.bool (
          t.enum [
            "ibgp"
            "ebgp"
          ]
        )
      );
      nextHopAddress = address;
      gateway = nullable (
        t.enum [
          "direct"
          "recursive"
        ]
      );
      extendedNextHop = nullable t.bool;
      importTable = nullable t.bool;
      exportTable = nullable t.bool;
      extraConfig = option t.str "";
    };
  };
  channels = option (t.attrsOf channel) { };
  # templates may leave either endpoint to the declarations derived from them
  endpoint = nullable (
    t.submodule {
      options = {
        asn = mkOption { type = types.asn; };
        address = address;
        port = nullable types.port;
      };
    }
  );
  destination = t.submodule {
    options = {
      type = mkOption {
        type = t.enum [
          "blackhole"
          "unreachable"
          "prohibit"
          "via"
        ];
      };
      gateway = address;
      interface = address;
      onlink = nullable t.bool;
      weight = nullable types.uint;
      bfd = nullable t.bool;
    };
  };
  interfacePattern = t.either t.str (
    t.submodule {
      options = {
        pattern = mkOption { type = t.str; };
        exclude = option t.bool false;
      };
    }
  );
  # bfd timers are whole milliseconds
  bfdOptions = {
    interval = nullable types.uint;
    minRxInterval = nullable types.uint;
    minTxInterval = nullable types.uint;
    idleTxInterval = nullable types.uint;
    multiplier = nullable types.uint;
    passive = nullable t.bool;
    extraConfig = option t.str "";
  };
in
{
  device.module = {
    options.scanTime = nullable types.uint;
  };
  direct.module = {
    options = {
      inherit channels;
      interfaces = option (t.listOf interfacePattern) [ ];
      checkLink = nullable t.bool;
    };
  };
  bfd.module = {
    options = {
      accept = nullable (
        t.submodule {
          options = {
            family = nullable (
              t.enum [
                "ipv4"
                "ipv6"
              ]
            );
            transport = nullable (
              t.enum [
                "direct"
                "multihop"
              ]
            );
          };
        }
      );
      strictBind = nullable t.bool;
      interfaces = option
        (t.listOf (
          t.submodule {
            options = bfdOptions // {
              patterns = mkOption { type = t.listOf interfacePattern; };
            };
          }
        )) [ ];
      multihop = nullable (t.submodule { options = bfdOptions; });
      neighbors = option
        (t.listOf (
          t.submodule {
            options = {
              address = mkOption { type = t.str; };
              interface = address;
              local = address;
              multihop = nullable t.bool;
            };
          }
        )) [ ];
    };
  };
  pipe.module = {
    options = {
      table = nullable (types.referenceTo "table");
      peerTable = nullable (types.referenceTo "table");
      import = nullable types.policy;
      export = nullable types.policy;
      importLimit = limit;
      receiveLimit = limit;
      exportLimit = limit;
      maxGeneration = nullable types.uint;
    };
  };
  kernel.module = {
    options = {
      inherit channels;
      kernelTable = nullable types.uint;
      scanTime = nullable types.uint;
      learn = nullable (t.either t.bool (t.enum [ "all" ]));
      persist = nullable t.bool;
      metric = nullable types.uint;
    };
  };
  static.module = {
    options = {
      inherit channels;
      routes = option
        (t.listOf (
          t.submodule {
            options = {
              prefix = mkOption { type = t.str; };
              destination = mkOption { type = destination; };
              body = option types.body [ ];
            };
          }
        )) [ ];
    };
  };
  bgp.module = {
    options = {
      inherit channels;
      local = endpoint;
      neighbor = endpoint;
      transport = nullable (
        t.submodule {
          options = {
            type = mkOption {
              type = t.enum [
                "direct"
                "multihop"
              ];
            };
            hops = nullable (t.ints.between 1 255);
          };
        }
      );
      sourceAddress = address;
      gracefulRestart = nullable (
        t.enum [
          "aware"
          "on"
          "off"
        ]
      );
      holdTime = nullable types.uint;
      keepaliveTime = nullable types.uint;
      bfd = nullable t.bool;
      ttlSecurity = nullable t.bool;
      password = nullable types.expression;
      # link-local sessions name their interface here or as the neighbor address scope
      interface = address;
      onlink = nullable t.bool;
      passive = nullable t.bool;
      localRole = nullable (
        t.enum [
          "peer"
          "provider"
          "customer"
          "rs_server"
          "rs_client"
        ]
      );
      requireRoles = nullable t.bool;
      # true accepts the local AS any number of times, a count limits it and 0 forbids it
      allowLocalAs = nullable (t.either t.bool types.uint);
      gracefulRestartTime = nullable types.uint;
      enableRouteRefresh = nullable t.bool;
      defaultBgpLocalPref = nullable types.uint;
      enforceFirstAs = nullable t.bool;
    };
  };
}
