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
      addPaths = option (t.enum [
        "off"
        "rx"
        "tx"
        "on"
      ]) "off";
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
  endpoint =
    requireAddress:
    t.submodule {
      options = {
        asn = mkOption { type = types.asn; };
        address = if requireAddress then mkOption { type = t.str; } else address;
        port = nullable types.port;
      };
    };
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
    options.scanTime = option types.uint 10;
  };
  direct.module = {
    options = {
      inherit channels;
      interfaces = option (t.listOf (
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
      scanTime = option types.uint 10;
      learn = option (t.either t.bool (t.enum [ "all" ])) false;
      persist = option t.bool false;
      metric = nullable types.uint;
    };
  };
  static.module = {
    options = {
      inherit channels;
      routes = option (t.listOf (
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
      local = mkOption { type = endpoint false; };
      neighbor = mkOption { type = endpoint true; };
      transport = mkOption {
        default = {
          type = "direct";
        };
        type = t.submodule {
          options = {
            type = mkOption {
              type = t.enum [
                "direct"
                "multihop"
              ];
            };
            hops = nullable (t.ints.between 1 255);
          };
        };
      };
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
      bfd = option t.bool false;
      ttlSecurity = option t.bool false;
      password = nullable types.expression;
    };
  };
}
