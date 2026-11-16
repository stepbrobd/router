{ lib, bird }:
let
  base = {
    router-id = "192.0.2.1";
    ipv4.table.main4 = { };
    ipv6.table.main6 = { };
    protocol.device.device0 = { };
    define.PASS_AS35661 = "public-inheritance-fixture";
  };
  upstream4 = {
    local.as = 10779;
    source-address = "198.51.100.10";
    direct = true;
    ipv4 = {
      table = "main4";
      import = "none";
      export.where = ''proto = "static4"'';
    };
  };
  upstream6 = {
    local.as = 10779;
    source-address = "2001:db8::10";
    direct = true;
    ipv6 = {
      table = "main6";
      import = "none";
      export.where = ''proto = "static6"'';
    };
  };
  peer = address: as: { neighbor = { inherit address as; }; };
  common = { template.bgp.upstream4 = upstream4; };
  cases = {
    plain = common // {
      protocol.bgp.p1 = { from = "upstream4"; } // peer "192.0.2.1" 36236;
    };
    chain = {
      template.bgp = {
        upstream4 = upstream4;
        virtua4 = {
          from = "upstream4";
          multihop = true;
          password = bird.symbol "PASS_AS35661";
        };
      };
      protocol.bgp.p2 = { from = "virtua4"; } // peer "192.0.2.121" 35661;
    };
    source = common // {
      protocol.bgp = {
        p3 = { from = "upstream4"; source-address = "198.51.100.20"; } // peer "192.0.2.3" 64515;
        p3b = { from = "upstream4"; local = { address = "198.51.100.30"; as = 10779; }; }
          // peer "192.0.2.30" 64515;
        p3c = {
          from = "upstream4";
          source-address = [ "198.51.100.40" "198.51.100.50" ];
        } // peer "192.0.2.50" 64515;
      };
    };
    channel = common // {
      protocol.bgp.p4 = { from = "upstream4"; ipv4.import = "all"; } // peer "192.0.2.4" 3204;
    };
    channel-order = {
      template.bgp.upstream6 = upstream6;
      protocol.bgp.p5 = {
        from = "upstream6";
        multihop = true;
        neighbor = { address = "2001:db8::b19"; as = 212232; };
        ipv6.export = "all";
        ipv4 = { import = "none"; export = "all"; extended-next-hop = true; next-hop-address = "192.0.2.50"; };
      };
    };
    neighbor-as = {
      template.bgp.fixed = {
        local.as = 10779;
        neighbor = { address = "192.0.2.6"; as = 65006; };
        ipv4 = { table = "main4"; import = "none"; export = "none"; };
      };
      protocol.bgp.p6b = { from = "fixed"; neighbor.as = 65008; };
    };
    protocol-parent = common // {
      protocol.bgp = {
        p1 = { from = "upstream4"; } // peer "192.0.2.1" 36236;
        p7 = { from = "p1"; neighbor.as = 65007; };
      };
    };
    routes = {
      template.static.s8 = {
        ipv4.table = "main4";
        route = [{ prefix = "192.0.2.0/24"; blackhole = true; }];
      };
      protocol.static.p8 = {
        from = "s8";
        route = [
          { prefix = "198.51.100.0/24"; blackhole = true; }
          { prefix = "192.0.2.0/24"; unreachable = true; }
        ];
      };
    };
    disabled = {
      template.bgp = {
        upstream4 = upstream4;
        off9 = { from = "upstream4"; disabled = true; };
      };
      protocol.bgp.p9 = { from = "off9"; } // peer "192.0.2.9" 65009;
    };
    dependency-order = {
      template.bgp = {
        z_parent = upstream4;
        a_child = { from = "z_parent"; hold-time = 30; };
      };
      protocol.bgp.ordered_peer = { from = "a_child"; } // peer "192.0.2.11" 65011;
    };
    peer-type = {
      template.bgp = {
        internal_base = { local.as = 65000; neighbor.internal = true; };
        external_base = { local.as = 65000; neighbor.external = true; };
      };
      protocol.bgp = {
        external_peer = {
          from = "internal_base";
          neighbor = { address = "192.0.2.41"; as = 65001; external = true; };
          ipv4 = { table = "main4"; import = "none"; export = "none"; };
        };
        internal_peer = {
          from = "external_base";
          neighbor = { address = "192.0.2.42"; as = 65000; internal = true; };
          ipv4 = { table = "main4"; import = "none"; export = "none"; };
        };
      };
    };
    specialized-channels = {
      mpls.table.validation_labels = { };
      template.bgp.parent = [
        { local.as = 65000; }
        { ipv4-multicast = { table = "main4"; import = "none"; export = "none"; }; }
        { mpls.table = "validation_labels"; }
      ];
      protocol.bgp.child = {
        from = "parent";
        neighbor = { address = "192.0.2.43"; as = 65001; };
      };
    };
    patterns = {
      template.direct.parent = {
        ipv4.table = "main4";
        interface = [{ patterns = [{ pattern = "eth9"; exclude = true; } { pattern = "eth*"; }]; }];
      };
      protocol.direct.child = { from = "parent"; interface = [{ pattern = "en*"; }]; };
    };
    semantic-list = {
      template.bgp.parent = {
        local.as = 10779;
        source-address = "198.51.100.10";
        direct = true;
        passive = true;
        strict-bind = true;
        neighbor = { range = "192.0.2.0/24"; as = 65000; };
        interface-range = [{ pattern = "eth*"; }];
        ipv4 = { table = "main4"; import = "none"; export = "none"; };
      };
      protocol.bgp.child = { from = "parent"; interface-range = [{ pattern = "en*"; }]; };
    };
    bfd-reset = {
      template.bfd.parent = {
        interface = [{ pattern = "eth*"; }];
        neighbor = [{ address = "192.0.2.200"; }];
      };
      protocol.bfd.child = {
        from = "parent";
        interface = [{ pattern = "en*"; }];
        neighbor = [{ address = "192.0.2.201"; }];
      };
    };
    unused-template = {
      template.babel.unused = {
        ipv4 = { table = "main4"; import = "all"; export = "none"; };
        interface = [{ pattern = "eth*"; }];
      };
    };
  };
  evaluated = lib.mapAttrs (_: settings: bird.eval { modules = [ base settings ]; }) cases;
  resolved = name: evaluated.${name}.resolved;
  p1 = (resolved "plain").protocol.bgp.p1;
  p2 = (resolved "chain").protocol.bgp.p2;
  p3 = (resolved "source").protocol.bgp;
  p4 = (resolved "channel").protocol.bgp.p4;
  p5 = (resolved "channel-order").protocol.bgp.p5;
  p6b = (resolved "neighbor-as").protocol.bgp.p6b;
  p7 = (resolved "protocol-parent").protocol.bgp.p7;
  routes = (resolved "routes").protocol.static.p8.route;
  direct = (resolved "patterns").protocol.direct.child.interface;
  bfd = (resolved "bfd-reset").protocol.bfd.child;
  force = value: builtins.tryEval (builtins.deepSeq value true);
in
{
  parserCases = lib.mapAttrs' (name: result: lib.nameValuePair "inheritance-${name}" result.text) evaluated;
  invalidParserCases = {
    inherited-neighbor = (bird.eval {
      modules = [
        base
        {
          template.bgp.fixed = {
            local.as = 10779;
            neighbor = { address = "192.0.2.6"; as = 65006; };
            ipv4 = { table = "main4"; import = "none"; export = "none"; };
          };
          protocol.bgp.invalid = { from = "fixed"; } // peer "192.0.2.7" 65007;
        }
      ];
    }).text;
    unsupported-inheritance = (bird.eval {
      modules = [
        base
        {
          template.babel.b10.interface = [{ pattern = "eth*"; }];
          protocol.babel.p10.from = "b10";
        }
      ];
    }).text;
  };
  check =
    assert p1.neighbor == { address = "192.0.2.1"; as = 36236; };
    assert p1.local.as == 10779;
    assert p1.source-address == "198.51.100.10";
    assert p1.ipv4 == upstream4.ipv4;
    assert p2.local.as == 10779 && p2.source-address == "198.51.100.10";
    assert p2.multihop == true && !(p2 ? direct);
    assert p2.password == bird.symbol "PASS_AS35661";
    assert p3.p3.source-address == "198.51.100.20";
    assert p3.p3b.source-address == "198.51.100.30";
    assert p3.p3c.source-address == "198.51.100.50";
    assert !(p3.p3b.local ? address);
    assert p4.ipv4 == { table = "main4"; import = "all"; export.where = ''proto = "static4"''; };
    assert !(p5 ? _meta);
    assert p5.ipv6.table == "main6" && p5.ipv6.export == "all";
    assert !(p5.ipv4 ? table);
    assert p6b.neighbor == { address = "192.0.2.6"; as = 65008; };
    assert p7.neighbor == { address = "192.0.2.1"; as = 65007; };
    assert map (route: route.prefix) routes == [ "192.0.2.0/24" "198.51.100.0/24" "192.0.2.0/24" ];
    assert (builtins.elemAt routes 2).unreachable == true;
    assert (resolved "disabled").protocol.bgp.p9.disabled == true;
    assert (resolved "dependency-order").protocol.bgp.ordered_peer.hold-time == 30;
    assert (resolved "peer-type").protocol.bgp.external_peer.neighbor == {
      address = "192.0.2.41";
      as = 65001;
      external = true;
    };
    assert (resolved "peer-type").protocol.bgp.internal_peer.neighbor == {
      address = "192.0.2.42";
      as = 65000;
      internal = true;
    };
    assert (resolved "specialized-channels").protocol.bgp.child ? ipv4-multicast;
    assert (resolved "specialized-channels").protocol.bgp.child ? mpls;
    assert direct == [
      { patterns = [{ pattern = "eth9"; exclude = true; } { pattern = "eth*"; }]; }
      { pattern = "en*"; }
    ];
    assert (resolved "semantic-list").protocol.bgp.child.interface-range == [{ pattern = "en*"; }];
    assert bfd.interface == [{ pattern = "en*"; }];
    assert bfd.neighbor == [{ address = "192.0.2.201"; }];
    assert !(force (bird.resolve {
      template.bgp.a.from = "b";
      template.bgp.b.from = "a";
      protocol.bgp.c.from = "a";
    })).success;
    true;
}
