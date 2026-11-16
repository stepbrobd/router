{ pkgs, lib, router, ... }:
let
  bird = router.bird;
  base = {
    router-id = "192.0.2.1";
    ipv4.table.main4 = { };
    ipv6.table.main6 = { };
    protocol.device.device0 = { };
  };
  inheritance = import ./inheritance.nix { inherit lib bird; };
  evaluate = modules: bird.eval { modules = [ base ] ++ modules; };
  composed = evaluate [
    {
      protocol.bgp.peer = {
        local.as = lib.mkDefault 65000;
        neighbor = { address = "192.0.2.2"; as = 65001; };
        hold-time = lib.mkDefault 15;
        ipv4 = {
          table = "main4";
          import = "none";
        };
      };
      filter.accept_owned.body = "accept;";
      include = lib.mkAfter [ "${../../examples/bird/credentials.example.conf}" ];
    }
    {
      protocol.bgp.peer = {
        hold-time = lib.mkForce 30;
        ipv4.export.filter = "accept_owned";
      };
      filter.accept_owned.body = lib.mkBefore "bgp_local_pref = 250;";
    }
  ];
  exactNode = name: predicate: args:
    let
      candidates = lib.imap0 (index: production: { inherit index production; })
        bird.inventory.grammar.rules.${name}.productions;
      selected = lib.findFirst (entry: predicate entry.production)
        (throw "missing BIRD fixture production ${name}")
        candidates;
    in
    { _rule = name; _production = selected.index; _args = args; };
  refers = name: production:
    lib.any (part: part.kind == "reference" && part.value == name) production.symbols;
  emptyEntries = exactNode "conf_entries" (production: production.symbols == [ ]) [ ];
  variables = exactNode bird.inventory.grammar.configuration_start (refers "conf_entries") [
    (exactNode "conf_entries" (refers "conf") [
      emptyEntries
      (exactNode "conf" (refers "filter_def") [
        (exactNode "filter_def" (refers "filter_body")
          [ "with_variables" "int x; { x = 1; accept; }" ])
      ])
    ])
  ];
  cases = {
    composed = composed.text;
    example = (bird.eval { modules = [ ../../examples/bird ]; }).text;
    native-variables = bird.render [ base variables ];
    native-variables-record = (evaluate [{
      function.copy_value = {
        args = [{ name = "input_value"; type = "int"; }];
        return = "int";
        variables = "int result; # local storage";
        body = ''
          result = input_value;
          return result;
        '';
      };
      filter.with_variables = {
        variables = "int x;";
        body = ''
          x = copy_value(seed);
          if x = 1 then accept;
          reject;
        '';
      };
    }
      {
        filter.with_variables = {
          variables = lib.mkBefore "int seed;";
          body = lib.mkBefore "seed = 1;";
        };
      }]).text;
    keyword-name = (evaluate [{
      filter.stacks.body = "accept;";
    }]).text;
    roa-routes = (evaluate [{
      roa4.table.roa_v4 = { };
      protocol.static.roa_static = {
        roa4.table = "roa_v4";
        route = [{ prefix = { prefix = "192.0.2.0/24"; max = 24; as = 65000; }; }];
      };
    }]).text;
    static-next-hops = (evaluate [{
      protocol.static.next_hops4 = {
        ipv4.table = "main4";
        route = [
          { prefix = "198.51.100.0/24"; via = bird.ip "192.0.2.2"; weight = 2; bfd = true; }
          {
            prefix = "203.0.113.0/24";
            via = [
              { address = bird.ip "192.0.2.2"; weight = 1; }
              { address = bird.ip "192.0.2.3"; weight = 3; onlink = true; }
            ];
          }
        ];
      };
      protocol.static.next_hops6 = {
        ipv6.table = "main6";
        route = [{ prefix = "2001:db8::/32"; via = { address = bird.ip "fe80::1"; interface = "eth0"; }; }];
      };
    }]).text;
    table-references = (evaluate [{
      ipv4.table.peer4 = { };
      protocol.pipe.mirror = {
        table = "main4";
        peer-table = "peer4";
        import = "all";
        export = "all";
      };
      protocol.bgp.internal = {
        local.as = 65000;
        neighbor = { address = "192.0.2.3"; as = 65000; };
        ipv4 = {
          table = "main4";
          igp-table = "peer4";
          import = "all";
          export = "none";
        };
      };
    }]).text;
    positional-records = (evaluate [{
      ipv4.table.peer4 = { };
      attribute = [{ type = "int"; name = "local_mark"; }];
      log-syslog = { name = "bird"; classes = "all"; };
      filter.mark.body = "local_mark = 1; accept;";
      protocol = {
        kernel.kernel0 = {
          ipv4 = { table = "main4"; export = "all"; };
          merge-paths = { enabled = true; limit = 16; };
        };
        ospf.ospf1 = {
          ecmp = { enabled = true; limit = 8; };
          ipv4 = { table = "main4"; import = "all"; export = "none"; };
          area."0".interface = [{ pattern = "eth*"; }];
        };
        pipe.mirror = {
          table = "main4";
          peer-table = "peer4";
          export-in = { prefix = "192.0.2.0/24"; policy = "all"; };
        };
      };
    }]).text;
    empty-signatures = (evaluate [{
      function.implicit_empty_args = { return = "bool"; body = "return true;"; };
      function.explicit_empty_args = { args = [ ]; return = "bool"; body = "return true;"; };
      filter.use_empty_args.body = ''
        if implicit_empty_args() && explicit_empty_args() then accept;
        reject;
      '';
    }]).text;
    ordered = bird.render [
      base
      { define.Z_VALUE = 1; }
      { define.A_VALUE = bird.expr "(Z_VALUE + 1)"; }
      { filter.ordered.body = "if A_VALUE = 2 then accept; reject;"; }
    ];
    ordered-block = (evaluate [{
      protocol.bgp.peer = [
        {
          local.as = 65000;
          neighbor = { address = "192.0.2.2"; as = 65001; };
          ipv4 = { table = "main4"; import = "none"; export = "none"; };
        }
        { hold-time = 30; }
        { hold-time = 60; }
      ];
    }]).text;
    inline-filter = (evaluate [{
      protocol.bgp.peer = {
        local.as = 65000;
        neighbor = { address = "192.0.2.2"; as = 65001; };
        ipv4 = {
          table = "main4";
          import.filter.body = "if net = 203.0.113.0/24 then accept; reject;";
          export.filter.body = "reject;";
        };
      };
    }]).text;
    roa-policy = (evaluate [{
      roa4.table.roas = { };
      function.roa_valid = {
        args = [
          { name = "candidate"; type = "prefix"; }
          { name = "asn"; type = "int"; }
        ];
        return = "bool";
        body = ''
          return roa_check(roas, candidate, asn) = ROA_VALID;
        '';
      };
      filter.check_roa.body = ''
        if roa_valid(192.0.2.0/24, 65000) then accept;
        reject;
      '';
    }]).text;
    templates = (evaluate [{
      template.bgp.base = {
        local.as = 65000;
        hold-time = 30;
        ipv4 = {
          table = "main4";
          import = "none";
          export = "none";
        };
      };
      protocol.bgp.peer = {
        from = "base";
        neighbor = { address = "192.0.2.2"; as = 65001; };
      };
    }]).text;
    protocols = (evaluate [{
      roa4.table.validation_roas = { };
      protocol = {
        babel.babel0 = {
          ipv4 = { table = "main4"; import = "all"; export = "none"; };
          interface = [
            { pattern = "eth*"; type = "wired"; hello-interval = { value = 1; unit = "s"; }; }
            { pattern = "wlan*"; type = "wireless"; }
          ];
        };
        bfd.bfd0.interface = [{
          pattern = "eth*";
          interval = { value = 100; unit = "ms"; };
          multiplier = 3;
        }];
        bfd.bfd0.neighbor = [{ address = "192.0.2.2"; interface = "eth0"; }];
        bmp.bmp0 = {
          station-address = { address = "192.0.2.20"; port = 5000; };
          system-name = "router";
          system-description = "generated grammar fixture";
        };
        ospf.ospf0 = {
          ipv4 = { table = "main4"; import = "all"; export = "none"; };
          area."0".interface = [{ pattern = "eth*"; type = "broadcast"; }];
        };
        rpki.rpki0 = {
          roa4.table = "validation_roas";
          remote = { address = bird.ip "192.0.2.10"; port = 3323; };
          transport-tcp = true;
        };
        radv.radv0 = {
          ipv6 = { table = "main6"; import = "all"; export = "none"; };
          interface = [{ pattern = "eth*"; min-ra-interval = 3; max-ra-interval = 10; }];
        };
      };
    }]).text;
    typed-constants = (evaluate [{
      define = {
        ENABLED = true;
        ADDRESS = bird.ip "192.0.2.1";
        ADDRESS_TEXT = "192.0.2.1";
        EMPTY = [ ];
      };
      filter.constant_types.body = ''
        if ENABLED && ADDRESS = 192.0.2.1 && ADDRESS_TEXT = "192.0.2.1" && !(1 ~ EMPTY) then accept;
        reject;
      '';
    }]).text;
  } // inheritance.parserCases;
in
{
  parserCases = cases;
  invalidParserCases = {
    hold-time = (evaluate [{
      protocol.bgp.peer = {
        local.as = 65000;
        neighbor = { address = "192.0.2.2"; as = 65001; };
        hold-time = 1;
        ipv4 = { table = "main4"; import = "none"; export = "none"; };
      };
    }]).text;
    table-reference = (evaluate [{
      protocol.static.static0.ipv4.table = "undeclared_table";
    }]).text;
    program = (evaluate [{
      filter.invalid.body = "this is not a BIRD instruction;";
    }]).text;
  } // inheritance.invalidParserCases;
  derivation = assert import ./runtime.nix { inherit lib; backend = bird; };
    assert inheritance.check;
    assert composed.config.protocol.bgp.peer.hold-time == 30;
    assert composed.config.protocol.bgp.peer.ipv4.import == "none";
    assert composed.config.protocol.bgp.peer.ipv4.export.filter == "accept_owned";
    pkgs.runCommand "bird-evaluation" { } ''
      mkdir -p "$out"
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList
        (name: text: ''cp ${pkgs.writeText "bird-${name}.conf" text} "$out/${name}.conf"'')
        cases)}
    '';
}
