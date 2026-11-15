{ lib, types }:
let
  inherit (lib) mkOption;
  t = lib.types;
  option = type: default: mkOption { inherit type default; };
  nullable = type: option (t.nullOr type) null;
  address = nullable t.str;
  channel = t.submodule {
    options = {
      table = nullable (types.referenceTo "table");
      import = nullable types.policy;
      export = nullable types.policy;
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
      onlink = option t.bool false;
      weight = nullable types.uint;
    };
  };
in
{
  device.module = {
    options.scanTime = nullable types.uint;
  };
  device.defaults.scanTime = 10;
  direct.module = {
    options = {
      inherit channels;
      interfaces = option
        (t.listOf (
          t.either t.str (
            t.submodule {
              options = {
                pattern = mkOption { type = t.str; };
                exclude = option t.bool false;
              };
            }
          )
        )) [ ];
      checkLink = nullable t.bool;
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
  kernel.defaults = {
    scanTime = 10;
    learn = false;
    persist = false;
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
    };
  };
  bgp.defaults = {
    transport = {
      type = "direct";
      hops = null;
    };
    bfd = false;
    ttlSecurity = false;
  };
}
