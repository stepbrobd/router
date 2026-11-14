{ config, lib, ... }:
let
  bird = lib.router.bird;
in
{
  protocols = {
    device0 = {
      type = "device";
      scanTime = 10;
    };
    connected = {
      type = "direct";
      interfaces = [
        "eth*"
        {
          pattern = "eth9";
          exclude = true;
        }
      ];
      checkLink = true;
      channels = {
        ipv4.table = config.tables.main4.ref;
        ipv6.table = config.tables.main6.ref;
      };
    };
    originate4 = {
      type = "static";
      channels.ipv4.table = config.tables.main4.ref;
      routes = [
        {
          prefix = "203.0.113.0/24";
          destination.type = "blackhole";
          body = [ (bird.stmt.call config.functions.tag_origin.ref [ ]) ];
        }
      ];
    };
    originate6 = {
      type = "static";
      channels.ipv6.table = config.tables.main6.ref;
      routes = [
        {
          prefix = "2001:db8:100::/48";
          destination.type = "blackhole";
        }
      ];
    };
    kernel4 = {
      type = "kernel";
      kernelTable = 254;
      persist = true;
      metric = 32;
      channels.ipv4 = {
        table = config.tables.main4.ref;
        import = "none";
        export.where = bird.expr.fromProtocol config.protocols.originate4.ref;
      };
    };
    kernel6 = {
      type = "kernel";
      kernelTable = 254;
      channels.ipv6 = {
        table = config.tables.main6.ref;
        import = "none";
        export.where = bird.expr.fromProtocol config.protocols.originate6.ref;
      };
    };
  };
}
