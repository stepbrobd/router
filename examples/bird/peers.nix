{ lib, ... }:
let bird = lib.router.bird; in
{
  protocol.bgp = {
    upstream4 = {
      local.as = 65000;
      neighbor = { address = "192.0.2.1"; as = 65001; };
      direct = true;
      source-address = "192.0.2.10";
      graceful-restart-aware = true;
      hold-time = 30;
      keepalive-time = 10;
      password = bird.symbol "EXAMPLE_PEER_PASSWORD";
      ipv4 = {
        table = "main4";
        import.filter = "import_peer4";
        export.filter = "export_owned4";
        next-hop-self = true;
      };
    };
    upstream6 = {
      local.as = 65000;
      neighbor = { address = "2001:db8:ffff::1"; as = 65002; };
      direct = true;
      source-address = "2001:db8:ffff::2";
      password = bird.symbol "EXAMPLE_PEER_PASSWORD";
      ipv4 = {
        table = "main4";
        import = "none";
        export.filter = "export_owned4";
        extended-next-hop = true;
        next-hop-self = true;
        next-hop-address = "2001:db8:ffff::2";
      };
      ipv6 = {
        table = "main6";
        import = "none";
        export.filter = "export_owned6";
        next-hop-self = true;
      };
    };
  };
}
