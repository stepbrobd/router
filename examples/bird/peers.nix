{ config, lib, ... }:
let
  bird = lib.router.bird;
  password = bird.external {
    kind = "value";
    name = "EXAMPLE_PEER_PASSWORD";
    type = "string";
  };
in
{
  protocols = {
    upstream4 = {
      type = "bgp";
      local.asn = 65000;
      neighbor = {
        asn = 65001;
        address = "192.0.2.1";
      };
      transport.type = "direct";
      sourceAddress = "192.0.2.10";
      gracefulRestart = "aware";
      holdTime = 30;
      keepaliveTime = 10;
      inherit password;
      channels.ipv4 = {
        table = config.tables.main4.ref;
        import = config.filters.import_peer4.ref;
        export = config.filters.export_owned4.ref;
        nextHopSelf = true;
      };
    };
    upstream6 = {
      type = "bgp";
      local.asn = 65000;
      neighbor = {
        asn = 65002;
        address = "2001:db8:ffff::1";
      };
      transport.type = "direct";
      sourceAddress = "2001:db8:ffff::2";
      inherit password;
      channels = {
        ipv4 = {
          table = config.tables.main4.ref;
          import = "none";
          export = config.filters.export_owned4.ref;
          extendedNextHop = true;
          nextHopSelf = true;
          nextHopAddress = "2001:db8:ffff::2";
        };
        ipv6 = {
          table = config.tables.main6.ref;
          import = "none";
          export = config.filters.export_owned6.ref;
          nextHopSelf = true;
        };
      };
    };
  };
}
