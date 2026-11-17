{ lib, backend ? import ../../lib/router/bird { inherit lib; } }:
let
  force = value: builtins.tryEval (builtins.deepSeq value value);
  # A host module may read the merged settings while defining them, as inc's routes read a host's function.
  selfReading = lib.evalModules {
    modules = [
      backend.nixosModule
      ({ config, ... }: {
        services.bird.settings = {
          router-id = "192.0.2.1";
          function.origin.body = "bgp_community.add((65000, 1));";
          protocol.static.originate = {
            ipv4 = { };
            route = [
              ({ prefix = "192.0.2.0/24"; unreachable = true; }
                // lib.optionalAttrs (config.services.bird.settings ? function.origin) { body = "origin();"; })
            ];
          };
        };
      })
    ];
  };
  merged = backend.eval {
    modules = [
      {
        protocol.bgp.upstream = {
          local.as = 65000;
          neighbor = { address = "192.0.2.2"; as = 65001; };
          ipv4 = { };
        };
        filter.owned.body = lib.mkAfter "reject;";
        include = lib.mkAfter [ "/run/bird/last.conf" ];
      }
      {
        protocol.bgp.upstream.hold-time = 30;
        filter.owned.body = lib.mkBefore "if net = 192.0.2.0/24 then accept;";
        include = lib.mkBefore [ "/run/bird/first.conf" ];
      }
    ];
  };
  conflict = backend.eval {
    modules = [
      { protocol.bgp.upstream.hold-time = 30; }
      { protocol.bgp.upstream.hold-time = 60; }
    ];
  };
  returnConflict = backend.eval {
    modules = [
      { function.typed = { return = "bool"; body = "return true;"; }; }
      { function.typed.return = "int"; }
    ];
  };
in
assert merged.config.protocol.bgp.upstream.local.as == 65000;
assert merged.config.protocol.bgp.upstream.hold-time == 30;
assert merged.config.include == [ "/run/bird/first.conf" "/run/bird/last.conf" ];
assert merged.config.filter.owned.body == "if net = 192.0.2.0/24 then accept;\nreject;";
assert !(force conflict.config).success;
assert !(force returnConflict.config).success;
assert !(force (backend.render { protocol.bgp.upstream.not-a-bird-option = 1; })).success;
assert !(force (backend.render { protocol.device.d.not-a-bird-option = [ ]; })).success;
assert !(force (backend.render { protocol.device.d.not-a-bird-option = { }; })).success;
assert !(force (backend.render { protocol.device.d._value = "unexpected"; })).success;
assert !(force (backend.eval {
  modules = [{ protocol.bgp.upstream.hold.time = 60; }];
}).config).success;
assert !(force (backend.render { router.id = "192.0.2.1"; })).success;
assert !(force (backend.render { protocol.kernel.k.kernel.table = 200; })).success;
assert !(force (backend.render { protocol.bgp.upstream.neighbor = "192.0.2.2 as 65001"; })).success;
assert !(force (backend.render { protocol.bgp.upstream.hold-time = false; })).success;
assert !(force (backend.render { protocol.bgp.upstream.hold-time = "30"; })).success;
assert !(force (backend.render {
  protocol.bfd.b.interface = [{ pattern = "eth*"; min-rx-interval = 100; }];
})).success;
assert !(force (backend.render { _rule = "conf"; _production = 0; _args = [ 1 ]; })).success;
assert !(force (backend.render { _rule = "cmd"; _production = 0; _args = [ ]; })).success;
assert !(force (backend.render {
  protocol.bgp.upstream.hold-time = {
    _rule = "rtrid";
    _args = [ "192.0.2.1" ];
  };
})).success;
assert !(force (backend.render {
  _rule = backend.inventory.grammar.configuration_start;
  _args = [ ];
  router-id = "192.0.2.1";
})).success;
assert lib.hasInfix "origin();" selfReading.config.services.bird.config;
assert (backend.render { protocol.pipe.p.peer-table = "t2"; }) != "";
assert !(force (backend.render { protocol.pipe.p.peer.table.t2 = { }; })).success;
assert lib.hasInfix "route 192.0.2.0/24 via 192.0.2.1 bfd on weight 2 ;"
  (backend.render {
    protocol.static.s.route = [{ prefix = "192.0.2.0/24"; via = backend.ip "192.0.2.1"; weight = 2; bfd = true; }];
  });
assert lib.hasInfix "route 192.0.2.0/24 via 192.0.2.1 weight 1\nvia 192.0.2.2 ;"
  (backend.render {
    protocol.static.s.route = [{ prefix = "192.0.2.0/24"; via = [{ address = backend.ip "192.0.2.1"; weight = 1; } { address = backend.ip "192.0.2.2"; }]; }];
  });
assert !(force (backend.render {
  protocol.static.s.route = [{ prefix = "192.0.2.0/24"; via = [ (backend.ip "192.0.2.1") (backend.ip "192.0.2.2") ]; }];
})).success;
# BIRD expands include at the start of any line, so blocks and values take one too
assert lib.hasInfix "ipv4 {\n\ninclude \"/run/bird/ipv4.conf\";\n\nexport none ;"
  (backend.render { protocol.bgp.upstream.ipv4 = { include = [ "/run/bird/ipv4.conf" ]; export = "none"; }; });
assert lib.hasInfix "password \ninclude \"/run/bird/password.conf\";\n ;"
  (backend.render { protocol.bgp.upstream.password = backend.include "/run/bird/password.conf"; });
assert !(force (backend.include "")).success;
# values that neither keywords nor bindings name take their registry labels
assert lib.hasInfix "cork threshold 1000 2000 ;"
  (backend.render { ipv4.table.t.cork-threshold = { low = 1000; high = 2000; }; });
# a named entry folds the parts after its name into one record
assert lib.hasInfix "virtual link 0.0.0.9 instance 3 { hello 5 ; } ;"
  (backend.render { protocol.ospf.o.area."0.0.0.1".virtual-link."0.0.0.9" = { instance = 3; hello = 5; }; });
# keyword-led records in a keyless statement are statements of their own
assert lib.hasInfix "watchdog warning 5 s" (backend.render { watchdog-warning = { value = 5; unit = "s"; }; });
# blocks of keyless statements and separated repetitions are lists
assert lib.hasInfix "networks { 10.0.0.0/8 ; 10.1.0.0/16 hidden ; } ;"
  (backend.render { protocol.ospf.o.area."0".networks = [{ prefix = "10.0.0.0/8"; } { prefix = "10.1.0.0/16"; hidden = true; }]; });
assert lib.hasInfix "route aspa 65000 providers 65001, 65002 ;"
  (backend.render { protocol.static.s.route = [{ prefix.aspa = 65000; providers = [ 65001 65002 ]; }]; });
# extended community items take bird.ec with the source's arities
assert lib.hasInfix "import target [ ( rt , 65000 , 1 ), ( rt , 65000 , 2 .. 10 ), ( rt , 65001 , * ) ] ;"
  (backend.render {
    protocol.l3vpn.v.import-target = [ (backend.ec [ "rt" 65000 1 ]) (backend.ec [ "rt" 65000 2 10 ]) (backend.ec [ "rt" 65001 ]) ];
  });
assert !(force (backend.render { protocol.l3vpn.v.import-target = [ "rt" 65000 1 ]; })).success;
# flowspec components are named by their keywords, with operator expressions as native text
assert lib.hasInfix "route flow4 { dst 10.0.0.0/8 ;\nport \n> 24 && < 30\n ; } ;"
  (backend.render { protocol.static.s.route = [{ prefix.flow4 = { dst = "10.0.0.0/8"; port.body = "> 24 && < 30"; }; }]; });
assert !(force (backend.render { protocol.static.s.route = [{ prefix.flow4.not-a-component = "1"; }]; })).success;
# the registry excludes filter unit test directives, which only BIRD's own test program runs
assert !(force (backend.render { bt_test_same = { function = "f"; compare = "g"; result = 1; }; })).success;
assert !(force (backend.render { bt_test_suite = { CF-SYM-KNOWN = "f"; text = "describes f"; }; })).success;
true
