{
  protocol = {
    device.device0.scan-time = 10;
    direct.connected = {
      interface = [{
        patterns = [
          { pattern = "eth9"; exclude = true; }
          { pattern = "eth*"; }
        ];
      }];
      check-link = true;
      ipv4.table = "main4";
      ipv6.table = "main6";
    };
    static = {
      originate4 = {
        ipv4.table = "main4";
        route = [{ prefix = "203.0.113.0/24"; blackhole = true; body = "tag_origin();"; }];
      };
      originate6 = {
        ipv6.table = "main6";
        route = [{ prefix = "2001:db8:100::/48"; blackhole = true; }];
      };
    };
    kernel = {
      kernel4 = {
        kernel-table = 254;
        persist = true;
        metric = 32;
        ipv4 = {
          table = "main4";
          import = "none";
          export.where = ''proto = "originate4"'';
        };
      };
      kernel6 = {
        kernel-table = 254;
        ipv6 = {
          table = "main6";
          import = "none";
          export.where = ''proto = "originate6"'';
        };
      };
    };
  };
}
