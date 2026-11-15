{ pkgs
, lib
, router
, self
}:
let
  bird = router.bird;
  inherit (bird) expr stmt;
  base = {
    id = "192.0.2.1";
  };
  reference = target: name: {
    kind = "reference";
    inherit target name;
  };
  evaluate = modules: bird.eval { modules = [ base ] ++ modules; };
  fails = modules: !(lib.tryEval (lib.deepSeq (evaluate modules).text true)).success;
  position =
    needle: text:
    let
      prefix = lib.head (lib.splitString needle text);
    in
    if prefix == text then null else lib.stringLength prefix;

  declarations = { config, ... }: {
    id = lib.mkDefault "192.0.2.9";
    tables.main4.type = "ipv4";
    defines = {
      OWNED = bird.prefixSet [ "203.0.113.0/24" ];
      C_STANDARD = bird.community.standard 65000 100;
      C_LARGE = bird.community.large 65000 100 1;
      C_EXTENDED = bird.community.extended "rt" 65000 100;
      C_IP_EXTENDED = bird.community.extended "ro" "192.0.2.9" 100;
      C_AS4_EXTENDED = bird.community.extended "rt" 65536 100;
      WRAPPED = {
        value = 7;
      };
      ADDRESS = bird.ip "192.0.2.1";
      EXACT_PREFIX = bird.prefix "203.0.113.0/24";
      RANGE4 = bird.prefixSet [
        {
          prefix = "203.0.113.0/24";
          ge = 24;
          le = 32;
        }
      ];
      RANGE4_SUPER = bird.prefixSet [
        {
          prefix = "203.0.113.0/24";
          ge = 16;
          le = 24;
        }
      ];
      RANGE6 = bird.prefixSet [
        {
          prefix = "2001:db8::/32";
          ge = 48;
          le = 128;
        }
      ];
      A_RAW = expr.raw {
        text = "Z_VALUE + 1";
        type = "int";
        dependsOn = [ config.defines.Z_VALUE.ref ];
      };
      Z_VALUE = 9;
    };
    functions = {
      owned = {
        params = [
          {
            name = "candidate";
            type = "prefix";
          }
        ];
        returnType = "bool";
        body = [
          (stmt.return (expr.inSet (expr.local "candidate") config.defines.OWNED.ref))
        ];
      };
      tag.body = [
        (stmt.addCommunities [
          config.defines.C_STANDARD.ref
          config.defines.C_LARGE.ref
          config.defines.C_EXTENDED.ref
        ])
      ];
    };
    filters = {
      export_owned = {
        default = "reject";
        body = [
          (stmt.when
            (expr.all [
              (expr.fromProtocol config.protocols.originate.ref)
              (expr.call config.functions.owned.ref [ bird.route.net ])
            ])
            [
              (stmt.call config.functions.tag.ref [ ])
              stmt.accept
            ]
          )
        ];
      };
      identity = {
        default = "reject";
        body = [
          (stmt.when (expr.fromProtocol config.protocols.peer.ref) [ stmt.accept ])
        ];
      };
    };
    protocols = {
      device0 = {
        type = "device";
        scanTime = lib.mkDefault 11;
      };
      originate = {
        type = "static";
        channels.ipv4.table = config.tables.main4.ref;
        routes = [
          {
            prefix = "203.0.113.0/24";
            destination.type = "blackhole";
          }
          {
            prefix = "198.51.100.0/24";
            destination.type = "unreachable";
          }
          {
            prefix = "198.18.0.0/24";
            destination.type = "prohibit";
          }
          {
            prefix = "198.19.0.0/24";
            destination = {
              type = "via";
              gateway = "192.0.2.2";
              interface = "eth1";
              onlink = true;
              weight = 2;
            };
          }
        ];
      };
      peer = {
        type = "bgp";
        local = {
          asn = 65000;
          port = lib.mkDefault 179;
        };
        neighbor = {
          asn = 65001;
          address = "192.0.2.2";
        };
        sourceAddress = "192.0.2.1";
        password = "synthetic-literal-only";
        channels.ipv4 = {
          table = config.tables.main4.ref;
          import = config.filters.identity.ref;
          export = config.filters.export_owned.ref;
        };
      };
    };
  };
  merged = evaluate [
    declarations
    {
      protocols.device0.scanTime = lib.mkForce 3;
      protocols.peer.local.port = lib.mkForce 1179;
      protocols.peer.description = "merged peer";
      filters.export_owned.body = lib.mkBefore [ (stmt.raw "print \"before\";") ];
    }
    { filters.export_owned.body = lib.mkAfter [ (stmt.raw "print \"after\";") ]; }
  ];
  cfg = merged.config;
  example = bird.eval { modules = [ ../../examples/bird ]; };
  recursive = evaluate [
    ({ config, ... }: {
      functions.countdown = {
        params = [
          {
            name = "remaining";
            type = "int";
          }
        ];
        returnType = "bool";
        body = [
          (stmt.when (expr.gt (expr.local "remaining") 0) [
            (stmt.return (
              expr.call config.functions.countdown.ref [
                (expr.raw {
                  text = "remaining - 1";
                  type = "int";
                })
              ]
            ))
          ])
          (stmt.return true)
        ];
      };
      filters.recursive = {
        default = "reject";
        body = [ (stmt.when (expr.call config.functions.countdown.ref [ 2 ]) [ stmt.accept ]) ];
      };
      protocols.device0.type = "device";
    })
  ];

  templateDeclarations = { config, ... }: {
    tables = {
      main4.type = "ipv4";
      main6.type = "ipv6";
    };
    filters.allow.default = "accept";
    templates = {
      base = {
        type = "bgp";
        local.asn = 65000;
        holdTime = 30;
        ttlSecurity = true;
        extraConfig = "# base";
        channels.ipv4 = {
          table = config.tables.main4.ref;
          import = "none";
          export = config.filters.allow.ref;
          addPaths = "tx";
        };
      };
      peers = {
        type = "bgp";
        from = config.templates.base.ref;
        keepaliveTime = 10;
      };
      routes = {
        type = "static";
        channels.ipv4.table = config.tables.main4.ref;
        routes = [
          {
            prefix = "198.51.100.0/24";
            destination.type = "blackhole";
          }
        ];
      };
    };
    protocols = {
      peer4 = {
        type = "bgp";
        from = config.templates.peers.ref;
        neighbor = {
          asn = 65001;
          address = "192.0.2.2";
        };
        ttlSecurity = false;
        channels.ipv4 = {
          import = "all";
          addPaths = "off";
        };
      };
      peer6 = {
        type = "bgp";
        from = config.templates.base.ref;
        neighbor = {
          asn = 65002;
          address = "2001:db8::2";
        };
        channels = {
          ipv4.extendedNextHop = true;
          ipv6 = {
            table = config.tables.main6.ref;
            import = "none";
            export = "none";
          };
        };
      };
      originate = {
        type = "static";
        from = config.templates.routes.ref;
        routes = [
          {
            prefix = "203.0.113.0/24";
            destination.type = "blackhole";
          }
        ];
      };
    };
  };
  templated = evaluate [ templateDeclarations ];
  bfdDeclarations = {
    protocols = {
      bfd0 = {
        type = "bfd";
        accept = {
          family = "ipv6";
          transport = "direct";
        };
        strictBind = true;
        interfaces = [
          {
            patterns = [
              "eth*"
              {
                pattern = "eth9";
                exclude = true;
              }
            ];
            minRxInterval = 50;
            minTxInterval = 100;
            idleTxInterval = 1000;
            multiplier = 3;
            passive = false;
          }
          { patterns = [ "wg*" ]; }
        ];
        multihop.interval = 300;
        neighbors = [
          {
            address = "192.0.2.2";
            interface = "eth0";
          }
          {
            address = "198.51.100.1";
            local = "192.0.2.1";
            multihop = true;
          }
        ];
      };
      peer = {
        type = "bgp";
        local.asn = 65000;
        neighbor = {
          asn = 65001;
          address = "192.0.2.2";
        };
        bfd = true;
        channels.ipv4 = {
          import = "none";
          export = "none";
        };
      };
      originate = {
        type = "static";
        channels.ipv4 = { };
        routes = [
          {
            prefix = "203.0.113.0/24";
            destination = {
              type = "via";
              gateway = "192.0.2.2";
              bfd = true;
            };
          }
        ];
      };
    };
  };
  bfdCase = evaluate [ bfdDeclarations ];
  globalDeclarations = { config, ... }: {
    log = [
      {
        target = "file";
        path = "/var/log/bird.log";
        size = 1048576;
        backup = "/var/log/bird.log.old";
        classes = [
          "info"
          "warning"
          "error"
        ];
      }
      {
        target = "fixed";
        path = "/var/log/bird.ring";
        size = 65536;
        classes = "all";
      }
      {
        target = "syslog";
        name = "bird";
        classes = "all";
      }
      {
        target = "stderr";
        classes = [ "fatal" ];
      }
      {
        target = "udp";
        address = "192.0.2.50";
        port = 1514;
        classes = [
          "warning"
          "error"
        ];
      }
      {
        target = "udp";
        address = "logs.example.net";
        classes = [ "bug" ];
      }
    ];
    debugProtocols = [
      "states"
      "events"
    ];
    gracefulRestartWait = 120;
    extraConfig = "timeformat protocol iso long;";
    attributes.learned_from.type = "int";
    filters = {
      mark = {
        default = "accept";
        body = [ (stmt.set config.attributes.learned_from.ref 1) ];
      };
      check = {
        default = "reject";
        body = [ (stmt.when (expr.eq config.attributes.learned_from.ref 1) [ stmt.accept ]) ];
      };
    };
    protocols.device0.type = "device";
  };
  globals = evaluate [ globalDeclarations ];
  filterLanguage = { config, ... }: {
    attributes.learned_from.type = "int";
    defines.PRIVATE_ASNS.value = expr.raw {
      text = "[ 64512..65534 ]";
      type = "int set";
    };
    filters.paths = {
      default = "accept";
      body = [
        (stmt.when (expr.gt expr.pathLength 8) [ stmt.reject ])
        (stmt.when (expr.eq expr.pathFirst 64496) [ (stmt.print [ "first hop" expr.pathLast ]) ])
        (stmt.printn [ expr.pathLastNonaggregated ])
        (stmt.deletePath [
          64511
          config.defines.PRIVATE_ASNS.ref
        ])
        (stmt.filterPath config.defines.PRIVATE_ASNS.ref)
        (stmt.set (expr.attribute "learned_from" "int") 2)
        (stmt.set (expr.attribute "krt_prefsrc" "ip") (bird.ip "192.0.2.1"))
      ];
    };
    protocols.originate = {
      type = "static";
      channels.ipv4 = { };
      routes = [
        {
          prefix = "203.0.113.0/24";
          destination.type = "unreachable";
          body = [
            (stmt.prependPath [
              18932
              18932
            ])
          ];
        }
      ];
    };
  };
  filterCase = evaluate [ filterLanguage ];
  # protocols with nothing optional declared next to the same protocols with every off form spelled out
  declared = evaluate [
    ({ config, ... }: {
      protocols = {
        sparse_device.type = "device";
        sparse_kernel = {
          type = "kernel";
          channels.ipv4 = {
            import = "none";
            export = "none";
          };
        };
        sparse_peer = {
          type = "bgp";
          local.asn = 65000;
          neighbor = {
            asn = 65001;
            address = "192.0.2.2";
          };
          channels.ipv4 = {
            import = "none";
            export = "none";
          };
        };
        explicit_kernel = {
          type = "kernel";
          disabled = false;
          kernelTable = 100;
          scanTime = 10;
          learn = false;
          persist = false;
          channels.ipv6 = {
            import = "none";
            export = "none";
          };
        };
        explicit_peer = {
          type = "bgp";
          local.asn = 65000;
          neighbor = {
            asn = 65002;
            address = "192.0.2.3";
          };
          transport.type = "direct";
          bfd = false;
          ttlSecurity = false;
          channels.ipv4 = {
            import = "none";
            export = "none";
            addPaths = "off";
          };
        };
        explicit_static = {
          type = "static";
          channels.ipv4 = { };
          routes = [
            {
              prefix = "198.51.100.0/24";
              destination = {
                type = "via";
                gateway = "192.0.2.2";
                interface = "eth0";
                onlink = false;
              };
            }
          ];
        };
      };
    })
  ];
  effective = bird.resolve templated.config;
  section =
    header: text:
    lib.head (lib.splitString "\n}" (lib.elemAt (lib.splitString header text) 1));

  extension = bird.extend {
    protocols.timerDevice = {
      module = { lib, ... }: {
        options.scanTime = lib.mkOption {
          type = lib.types.ints.positive;
          default = 17;
        };
      };
      render = _ctx: name: config: ''
        protocol device ${name} {
          scan time ${toString config.scanTime};
        }
      '';
      validate =
        _ctx: name: config:
        lib.optional (config.scanTime < 2) "${name}: scanTime must be at least two";
    };
  };
  extended = extension.eval {
    modules = [
      base
      {
        protocols.custom0.type = "timerDevice";
        protocols.originate = {
          type = "static";
          channels.ipv4 = { };
          routes = [
            {
              prefix = "198.18.0.0/24";
              destination.type = "blackhole";
            }
          ];
        };
      }
      { protocols.custom0.scanTime = lib.mkDefault 19; }
      { protocols.custom0.scanTime = lib.mkForce 23; }
    ];
  };
  extensionRejects =
    !(lib.tryEval (
      lib.deepSeq
        (extension.eval {
          modules = [
            base
            {
              protocols.custom0 = {
                type = "timerDevice";
                scanTime = 1;
              };
            }
          ];
        }).text
        true
    )).success;

  nixos =
    modules:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        self.nixosModules.bird
        {
          boot.isContainer = true;
          system.stateVersion = "26.11";
          services.bird = {
            enable = true;
            package = pkgs.bird3;
          };
        }
      ]
      ++ modules;
    };
  structured = {
    services.bird.settings = {
      id = "192.0.2.1";
      protocols.device0.type = "device";
    };
  };
  rawText = "router id 192.0.2.1; protocol device raw_device {}";
  nixosAccepts =
    modules:
    let
      attempt = lib.tryEval (
        let
          config = (nixos modules).config;
        in
        lib.deepSeq config.services.bird.config true
      );
    in
    attempt.success && attempt.value;
  nixosComposed = nixos [
    structured
    ({ config, ... }: {
      services.bird.settings = {
        tables.main4.type = "ipv4";
        filters.allow.default = "accept";
        protocols.peer = {
          type = "bgp";
          local.asn = 65000;
          neighbor = {
            asn = 65001;
            address = "192.0.2.2";
          };
          channels.ipv4 = {
            table = config.services.bird.settings.tables.main4.ref;
            import = "none";
            export = config.services.bird.settings.filters.allow.ref;
          };
        };
      };
    })
    { services.bird.settings.protocols.device0.scanTime = lib.mkForce 4; }
  ];

  invalid = {
    unknownProtocol = [{ protocols.bad.type = "notRegistered"; }];
    unknownExpressionKind = [
      {
        defines.BAD = {
          kind = "notAnExpression";
        };
      }
    ];
    unknownStatementKind = [
      {
        filters.bad = {
          default = "reject";
          body = [{ kind = "notAStatement"; }];
        };
      }
    ];
    conflictingProtocolKinds = [
      { protocols.bad.type = "device"; }
      { protocols.bad.type = "direct"; }
    ];
    missingTable = [
      {
        protocols.bad = {
          type = "direct";
          channels.ipv4.table = reference "table" "missing";
        };
      }
    ];
    wrongReferenceKind = [
      ({ config, ... }: {
        filters.allow.default = "accept";
        protocols.bad = {
          type = "direct";
          channels.ipv4.table = config.filters.allow.ref;
        };
      })
    ];
    protocolAsPolicy = [
      declarations
      ({ config, ... }: {
        protocols.peer.channels.ipv4.export = lib.mkForce config.protocols.originate.ref;
      })
    ];
    missingFunction = [
      {
        filters.bad = {
          default = "reject";
          body = [ (stmt.call (reference "function" "absent") [ ]) ];
        };
      }
    ];
    functionArity = [
      declarations
      ({ config, ... }: {
        filters.bad = {
          default = "reject";
          body = [ (stmt.when (expr.call config.functions.owned.ref [ ]) [ stmt.accept ]) ];
        };
      })
    ];
    functionArgumentType = [
      declarations
      ({ config, ... }: {
        filters.bad = {
          default = "reject";
          body = [ (stmt.when (expr.call config.functions.owned.ref [ 7 ]) [ stmt.accept ]) ];
        };
      })
    ];
    functionReturnType = [
      {
        functions.bad = {
          returnType = "bool";
          body = [ (stmt.return 7) ];
        };
      }
    ];
    voidFunctionAsCondition = [
      declarations
      ({ config, ... }: {
        filters.bad = {
          default = "reject";
          body = [ (stmt.when (expr.call config.functions.tag.ref [ ]) [ stmt.accept ]) ];
        };
      })
    ];
    unboundLocal = [
      {
        functions.bad = {
          returnType = "bool";
          body = [ (stmt.return (expr.local "absent")) ];
        };
      }
    ];
    attributeType = [
      {
        filters.bad = {
          default = "reject";
          body = [ (stmt.set bird.route.bgpLocalPref false) ];
        };
      }
    ];
    returnOutsideFunction = [
      {
        filters.bad = {
          default = "reject";
          body = [ (stmt.return true) ];
        };
      }
    ];
    tableAddressFamily = [
      ({ config, ... }: {
        tables.wrong.type = "ipv6";
        protocols.bad = {
          type = "direct";
          channels.ipv4.table = config.tables.wrong.ref;
        };
      })
    ];
    staticAddressFamily = [
      {
        protocols.bad = {
          type = "static";
          channels.ipv4 = { };
          routes = [
            {
              prefix = "2001:db8::/32";
              destination.type = "blackhole";
            }
          ];
        };
      }
    ];
    kernelChannelCount = [
      {
        protocols.bad = {
          type = "kernel";
          channels = {
            ipv4 = { };
            ipv6 = { };
          };
        };
      }
    ];
    staticChannelCount = [
      {
        protocols.bad = {
          type = "static";
          channels = {
            ipv4 = { };
            ipv6 = { };
          };
        };
      }
    ];
    missingBgpPolicy = [
      {
        protocols.bad = {
          type = "bgp";
          local.asn = 65000;
          neighbor = {
            asn = 65001;
            address = "192.0.2.2";
          };
          channels.ipv4 = { };
        };
      }
    ];
    transportAddressFamily = [
      declarations
      { protocols.peer.local.address = "2001:db8::1"; }
    ];
    sourceAddressFamily = [
      declarations
      { protocols.peer.sourceAddress = lib.mkForce "2001:db8::1"; }
    ];
    ipv4OverIpv6WithoutExtendedNextHop = [
      {
        protocols.bad = {
          type = "bgp";
          local.asn = 65000;
          neighbor = {
            asn = 65001;
            address = "2001:db8::2";
          };
          channels.ipv4 = {
            import = "none";
            export = "none";
            extendedNextHop = false;
          };
        };
      }
    ];
    invalidRouterId = [{ id = lib.mkForce "300.0.0.1"; }];
    ipv6RouterId = [{ id = lib.mkForce "2001:db8::1"; }];
    invalidPrefixLength = [{ defines.BAD = bird.prefix "203.0.113.0/33"; }];
    prefixSetTooLong = [
      {
        defines.BAD = bird.prefixSet [
          {
            prefix = "203.0.113.0/24";
            ge = 24;
            le = 33;
          }
        ];
      }
    ];
    prefixSetInverted = [
      {
        defines.BAD = bird.prefixSet [
          {
            prefix = "203.0.113.0/24";
            ge = 28;
            le = 26;
          }
        ];
      }
    ];
    prefixSetMixedFamilies = [
      {
        defines.BAD = bird.prefixSet [
          "203.0.113.0/24"
          "2001:db8::/32"
        ];
      }
    ];
    standardCommunityRange = [{ defines.BAD = bird.community.standard 65536 1; }];
    largeCommunityRange = [{ defines.BAD = bird.community.large 65000 4294967296 1; }];
    extendedCommunityRange = [{ defines.BAD = bird.community.extended "rt" 65000 4294967296; }];
    extendedAs4CommunityRange = [{ defines.BAD = bird.community.extended "rt" 65536 65536; }];
    extendedIpCommunityRange = [{ defines.BAD = bird.community.extended "rt" "192.0.2.1" 65536; }];
    bgpAsnRange = [
      declarations
      { protocols.peer.local.asn = lib.mkForce 4294967296; }
    ];
    bgpPortRange = [
      declarations
      { protocols.peer.neighbor.port = 65536; }
    ];
    multihopRange = [
      declarations
      {
        protocols.peer.transport = {
          type = "multihop";
          hops = 256;
        };
      }
    ];
    passwordType = [
      declarations
      {
        protocols.peer.password = lib.mkForce (
          bird.external {
            kind = "value";
            name = "BAD_PASSWORD";
            type = "int";
          }
        );
      }
    ];
    externalSymbol = [
      declarations
      {
        protocols.peer.password = lib.mkForce (
          bird.external {
            kind = "value";
            name = "not/a/symbol";
            type = "string";
          }
        );
      }
    ];
    ambiguousPolicy = [
      declarations
      {
        protocols.peer.channels.ipv4.export = lib.mkForce {
          inline = {
            body = [ ];
            default = "reject";
          };
          where = true;
        };
      }
    ];
    missingDependency = [
      {
        defines.BAD = {
          value = 1;
          dependsOn = [ (reference "define" "missing") ];
        };
      }
    ];
    definitionCycle = [
      ({ config, ... }: {
        defines.A = {
          value = config.defines.B.ref;
        };
        defines.B = {
          value = config.defines.A.ref;
        };
      })
    ];
    mutualFunctionCycle = [
      ({ config, ... }: {
        functions.a = {
          returnType = "bool";
          body = [ (stmt.return (expr.call config.functions.b.ref [ ])) ];
        };
        functions.b = {
          returnType = "bool";
          body = [ (stmt.return (expr.call config.functions.a.ref [ ])) ];
        };
      })
    ];
    templateMissing = [
      templateDeclarations
      { protocols.peer4.from = lib.mkForce (reference "template" "missing"); }
    ];
    templateTypeMismatch = [
      templateDeclarations
      ({ config, ... }: { protocols.originate.from = lib.mkForce config.templates.base.ref; })
    ];
    templateCycle = [
      templateDeclarations
      ({ config, ... }: { templates.base.from = config.templates.peers.ref; })
    ];
    templateFromProtocol = [
      templateDeclarations
      { protocols.peer4.from = lib.mkForce (reference "protocol" "peer6"); }
    ];
    templateIncomplete = [
      templateDeclarations
      ({ config, ... }: {
        protocols.lonely = {
          type = "bgp";
          from = config.templates.base.ref;
        };
      })
    ];
    bgpBfdWithoutProtocol = [
      bfdDeclarations
      { protocols.bfd0.disabled = true; }
    ];
    staticBfdWithoutGateway = [
      bfdDeclarations
      {
        protocols.originate.routes = lib.mkForce [
          {
            prefix = "203.0.113.0/24";
            destination = {
              type = "via";
              interface = "eth0";
              bfd = true;
            };
          }
        ];
      }
    ];
    staticBfdWithOnlink = [
      bfdDeclarations
      {
        protocols.originate.routes = lib.mkForce [
          {
            prefix = "203.0.113.0/24";
            destination = {
              type = "via";
              gateway = "192.0.2.2";
              interface = "eth0";
              onlink = true;
              bfd = true;
            };
          }
        ];
      }
    ];
    bfdTemplate = [
      {
        templates.bfd_base.type = "bfd";
        protocols.bfd0 = {
          type = "bfd";
          from = reference "template" "bfd_base";
        };
      }
    ];
    bfdMultiplierRange = [
      bfdDeclarations
      { protocols.bfd0.multihop.multiplier = 256; }
    ];
    bfdIntervalConflict = [
      bfdDeclarations
      { protocols.bfd0.multihop.minRxInterval = 10; }
    ];
    bfdEmptyInterfacePatterns = [
      bfdDeclarations
      { protocols.bfd0.interfaces = [{ patterns = [ ]; }]; }
    ];
    bfdMultihopNeighborInterface = [
      bfdDeclarations
      {
        protocols.bfd0.neighbors = [
          {
            address = "198.51.100.2";
            interface = "eth0";
            local = "192.0.2.1";
            multihop = true;
          }
        ];
      }
    ];
    bfdMultihopNeighborWithoutLocal = [
      bfdDeclarations
      {
        protocols.bfd0.neighbors = [
          {
            address = "198.51.100.2";
            multihop = true;
          }
        ];
      }
    ];
    bfdNeighborFamily = [
      bfdDeclarations
      {
        protocols.bfd0.neighbors = [
          {
            address = "198.51.100.2";
            local = "2001:db8::1";
          }
        ];
      }
    ];
    logRotationWithoutBackup = [
      globalDeclarations
      {
        log = lib.mkForce [
          {
            target = "file";
            path = "/var/log/bird.log";
            size = 1048576;
            classes = "all";
          }
        ];
      }
    ];
    logRotationTooSmall = [
      globalDeclarations
      {
        log = lib.mkForce [
          {
            target = "file";
            path = "/var/log/bird.log";
            size = 1024;
            backup = "/var/log/bird.log.old";
            classes = "all";
          }
        ];
      }
    ];
    logUdpWithoutAddress = [
      globalDeclarations
      {
        log = lib.mkForce [
          {
            target = "udp";
            classes = "all";
          }
        ];
      }
    ];
    logStderrWithPath = [
      globalDeclarations
      {
        log = lib.mkForce [
          {
            target = "stderr";
            path = "/var/log/bird.log";
            classes = "all";
          }
        ];
      }
    ];
    logEmptyClasses = [
      globalDeclarations
      {
        log = lib.mkForce [
          {
            target = "stderr";
            classes = [ ];
          }
        ];
      }
    ];
    debugProtocolsEmpty = [
      globalDeclarations
      { debugProtocols = lib.mkForce [ ]; }
    ];
    attributeBuiltinName = [
      globalDeclarations
      { attributes.bgp_med.type = "int"; }
    ];
    attributeTypeMismatch = [
      globalDeclarations
      ({ config, ... }: {
        filters.wrong = {
          default = "reject";
          body = [ (stmt.when (expr.eq config.attributes.learned_from.ref "peer") [ stmt.accept ]) ];
        };
      })
    ];
    attributeInDefine = [
      globalDeclarations
      ({ config, ... }: { defines.FROM_ATTRIBUTE.value = config.attributes.learned_from.ref; })
    ];
    attributeNameCollision = [
      globalDeclarations
      { defines.learned_from.value = 1; }
    ];
    prependPathType = [
      filterLanguage
      {
        filters.wrong = {
          default = "accept";
          body = [ (stmt.prependPath [ "18932" ]) ];
        };
      }
    ];
    prependPathEmpty = [
      filterLanguage
      {
        filters.wrong = {
          default = "accept";
          body = [ (stmt.prependPath [ ]) ];
        };
      }
    ];
    filterPathType = [
      filterLanguage
      {
        filters.wrong = {
          default = "accept";
          body = [ (stmt.filterPath 64511) ];
        };
      }
    ];
    printEmpty = [
      filterLanguage
      {
        filters.wrong = {
          default = "accept";
          body = [ (stmt.print [ ]) ];
        };
      }
    ];
    pathPropertyUnknown = [
      filterLanguage
      {
        filters.wrong = {
          default = "accept";
          body = [
            (stmt.when
              (expr.gt
                {
                  kind = "pathProperty";
                  property = "width";
                } 1)
              [ stmt.reject ])
          ];
        };
      }
    ];
    customAttributeWrongType = [
      filterLanguage
      {
        filters.wrong = {
          default = "accept";
          body = [ (stmt.set (expr.attribute "learned_from" "string") "peer") ];
        };
      }
    ];
    addPathsOutsideBgp = [
      {
        protocols.originate = {
          type = "static";
          channels.ipv4.addPaths = "off";
        };
      }
    ];
    onlinkOnSpecialDestination = [
      {
        protocols.originate = {
          type = "static";
          channels.ipv4 = { };
          routes = [
            {
              prefix = "198.51.100.0/24";
              destination = {
                type = "blackhole";
                onlink = false;
              };
            }
          ];
        };
      }
    ];
    templateNameCollision = [
      templateDeclarations
      { protocols.base.type = "device"; }
    ];
  };

  assertions = {
    preservesSiblingRoutingNamespaces =
      let
        siteBird = import ../../lib/router/bird {
          lib = lib.extend (_: _: { router.site.id = "198.51.100.19"; });
        };
        generated = siteBird.eval {
          modules = [
            ({ lib, ... }: { id = lib.router.site.id; })
          ];
        };
      in
      lib.hasInfix "router id 198.51.100.19;" generated.text;
    mergeNormalPriority = cfg.id == "192.0.2.1";
    mergeForcePriority = cfg.protocols.device0.scanTime == 3 && cfg.protocols.peer.local.port == 1179;
    mergeProtocolFields =
      cfg.protocols.peer.description == "merged peer" && cfg.protocols.peer.local.asn == 65000;
    mergeBodyOrder =
      (lib.head cfg.filters.export_owned.body).text == "print \"before\";"
        && (lib.last cfg.filters.export_owned.body).text == "print \"after\";"
        && lib.length cfg.filters.export_owned.body == 3;
    derivedReferences =
      cfg.protocols.peer.ref == reference "protocol" "peer"
        && cfg.filters.export_owned.ref == reference "filter" "export_owned"
        && cfg.functions.owned.ref == reference "function" "owned"
        && cfg.tables.main4.ref == reference "table" "main4"
        && cfg.defines.OWNED.ref == reference "define" "OWNED";
    normalizedDefinitions =
      cfg.defines.WRAPPED.value == 7 && cfg.defines.C_STANDARD.value.kind == "community";
    referencesArePlainData =
      lib.fromJSON (lib.toJSON cfg.protocols.peer.ref) == reference "protocol" "peer";
    rawDependencyOrdering = position "define Z_VALUE" merged.text < position "define A_RAW" merged.text;
    identityReferenceHasNoOrderCycle = lib.hasInfix "proto = \"peer\"" merged.text;
    literalPasswordIsQuoted = lib.hasInfix "password \"synthetic-literal-only\";" merged.text;
    externalPasswordIsSymbolic =
      lib.hasInfix "password EXAMPLE_PEER_PASSWORD;" example.text
        && !(lib.hasInfix "password \"EXAMPLE_PEER_PASSWORD\"" example.text)
        && !(lib.hasInfix "synthetic-example-only" example.text);
    includeBeforeDeclarations =
      position "include \"/run/bird/example-credentials.conf\";" example.text
        < position "define " example.text;
    templatesPrecedeDerivations =
      position "template bgp base {" templated.text < position "template bgp peers from base {" templated.text
        && position "template bgp peers from base {" templated.text
        < position "protocol bgp peer4 from peers {" templated.text
        && position "template static routes {" templated.text
        < position "protocol static originate from routes {" templated.text;
    templateRootRendersOnlyDeclared =
      let
        base = section "template bgp base {" templated.text;
      in
      lib.hasInfix "local as 65000;" base
        && lib.hasInfix "ttl security on;" base
        && lib.hasInfix "add paths tx;" base
        && !(lib.hasInfix "direct;" base)
        && !(lib.hasInfix "bfd" base)
        && !(lib.hasInfix "disabled" base);
    undeclaredDefaultsAbsent =
      let
        device = section "protocol device sparse_device {" declared.text;
        kernel = section "protocol kernel sparse_kernel {" declared.text;
        peer = section "protocol bgp sparse_peer {" declared.text;
      in
      !(lib.hasInfix "scan time" device)
        && !(lib.hasInfix "scan time" kernel)
        && !(lib.hasInfix "learn" kernel)
        && !(lib.hasInfix "persist" kernel)
        && !(lib.hasInfix "disabled" kernel)
        && !(lib.hasInfix "direct;" peer)
        && !(lib.hasInfix "multihop" peer)
        && !(lib.hasInfix "bfd" peer)
        && !(lib.hasInfix "ttl security" peer)
        && !(lib.hasInfix "add paths" peer);
    bfdRenders =
      let
        bfd = section "protocol bfd bfd0 {" bfdCase.text;
      in
      lib.hasInfix "accept ipv6 direct;" bfd
        && lib.hasInfix "strict bind on;" bfd
        && lib.hasInfix "interface \"eth*\", -\"eth9\" {" bfd
        && lib.hasInfix "min rx interval 50 ms;" bfd
        && lib.hasInfix "min tx interval 100 ms;" bfd
        && lib.hasInfix "idle tx interval 1000 ms;" bfd
        && lib.hasInfix "multiplier 3;" bfd
        && lib.hasInfix "passive off;" bfd
        && lib.hasInfix "interface \"wg*\";" bfd
        && lib.hasInfix "multihop {\n    interval 300 ms;\n  };" bfd
        && lib.hasInfix "neighbor 192.0.2.2 dev \"eth0\";" bfd
        && lib.hasInfix "neighbor 198.51.100.1 local 192.0.2.1 multihop on;" bfd
        && lib.hasInfix "bfd on;" (section "protocol bgp peer {" bfdCase.text)
        && lib.hasInfix "route 203.0.113.0/24 via 192.0.2.2 bfd on;" bfdCase.text;
    globalsRender =
      lib.hasInfix "log \"/var/log/bird.log\" 1048576 \"/var/log/bird.log.old\" { info, warning, error };" globals.text
        && lib.hasInfix "log fixed \"/var/log/bird.ring\" 65536 all;" globals.text
        && lib.hasInfix "log syslog name \"bird\" all;" globals.text
        && lib.hasInfix "log stderr { fatal };" globals.text
        && lib.hasInfix "log udp 192.0.2.50 port 1514 { warning, error };" globals.text
        && lib.hasInfix "log udp \"logs.example.net\" { bug };" globals.text
        && lib.hasInfix "debug protocols { states, events };" globals.text
        && lib.hasInfix "graceful restart wait 120;" globals.text
        && lib.hasInfix "attribute int learned_from;" globals.text
        && lib.hasInfix "learned_from = 1;" globals.text
        && lib.hasInfix "if (learned_from = 1) then {" globals.text;
    globalsPrecedeDeclarations =
      position "graceful restart wait 120;" globals.text < position "timeformat protocol iso long;" globals.text
        && position "timeformat protocol iso long;" globals.text < position "attribute int learned_from;" globals.text
        && position "attribute int learned_from;" globals.text < position "filter mark" globals.text
        && position "debug protocols" globals.text < position "protocol device device0" globals.text;
    undeclaredGlobalsAbsent =
      !(lib.hasInfix "log " merged.text)
        && !(lib.hasInfix "debug protocols" merged.text)
        && !(lib.hasInfix "graceful restart wait" merged.text)
        && !(lib.hasInfix "attribute " merged.text);
    filterLanguageRenders =
      let
        paths = section "filter paths {" filterCase.text;
      in
      lib.hasInfix "if (bgp_path.len > 8) then {" paths
        && lib.hasInfix "if (bgp_path.first = 64496) then {" paths
        && lib.hasInfix "print \"first hop\", bgp_path.last;" paths
        && lib.hasInfix "printn bgp_path.last_nonaggregated;" paths
        && lib.hasInfix "bgp_path.delete(64511);\n  bgp_path.delete(PRIVATE_ASNS);" paths
        && lib.hasInfix "bgp_path.filter(PRIVATE_ASNS);" paths
        && lib.hasInfix "learned_from = 2;" paths
        && lib.hasInfix "krt_prefsrc = 192.0.2.1;" paths
        && lib.hasInfix "route 203.0.113.0/24 unreachable {\n    bgp_path.prepend(18932);\n    bgp_path.prepend(18932);\n  };" filterCase.text;
    explicitOffRenders =
      let
        kernel = section "protocol kernel explicit_kernel {" declared.text;
        peer = section "protocol bgp explicit_peer {" declared.text;
      in
      lib.hasInfix "disabled off;" kernel
        && lib.hasInfix "learn off;" kernel
        && lib.hasInfix "persist off;" kernel
        && lib.hasInfix "scan time 10;" kernel
        && lib.hasInfix "direct;" peer
        && lib.hasInfix "bfd off;" peer
        && lib.hasInfix "ttl security off;" peer
        && lib.hasInfix "add paths off;" peer
        && lib.hasInfix "route 198.51.100.0/24 via 192.0.2.2 dev \"eth0\" onlink off;" declared.text;
    derivedRendersOnlyItsOwnFields =
      let
        peer4 = section "protocol bgp peer4 from peers {" templated.text;
        peers = section "template bgp peers from base {" templated.text;
      in
      lib.hasInfix "neighbor 192.0.2.2 as 65001;" peer4
        && lib.hasInfix "ttl security off;" peer4
        && lib.hasInfix "import all;" peer4
        && lib.hasInfix "add paths off;" peer4
        && !(lib.hasInfix "local as" peer4)
        && !(lib.hasInfix "hold time" peer4)
        && !(lib.hasInfix "direct;" peer4)
        && !(lib.hasInfix "export" peer4)
        && !(lib.hasInfix "bfd" peer4)
        && lib.hasInfix "keepalive time 10;" peers
        && !(lib.hasInfix "hold time" peers);
    rawTemplateDataStaysOwn =
      templated.config.protocols.peer4.holdTime == null
        && templated.config.protocols.peer4.local == null
        && templated.config.templates.peers.ref == reference "template" "peers";
    templateResolvesChain =
      let
        peer4 = effective.protocols.peer4;
      in
      peer4.local.asn == 65000
        && peer4.holdTime == 30
        && peer4.keepaliveTime == 10
        && peer4.ttlSecurity == false
        && peer4.bfd == null
        && peer4.transport == null
        && peer4.extraConfig == "# base"
        && peer4.ref == reference "protocol" "peer4"
        && peer4.channels.ipv4.import == "all"
        && peer4.channels.ipv4.export == reference "filter" "allow"
        && peer4.channels.ipv4.table == reference "table" "main4"
        && peer4.channels.ipv4.addPaths == "off";
    templateChannelsMerge =
      let
        peer6 = effective.protocols.peer6;
      in
      peer6.channels.ipv4.extendedNextHop == true
        && peer6.channels.ipv4.addPaths == "tx"
        && peer6.channels.ipv4.export == reference "filter" "allow"
        && peer6.channels.ipv6.export == "none"
        && peer6.channels.ipv6.addPaths == null
        && peer6.ttlSecurity == true;
    templateListsAppend =
      map (route: route.prefix) effective.protocols.originate.routes == [
        "198.51.100.0/24"
        "203.0.113.0/24"
      ];
    extensionMergesAndRenders =
      extended.config.protocols.custom0.scanTime == 23
        && extended.config.protocols.custom0.ref == reference "protocol" "custom0"
        && lib.hasInfix "scan time 23;" extended.text;
    extensionValidates = extensionRejects;
    nixosSettingsRender =
      lib.hasInfix "protocol device device0" nixosComposed.config.services.bird.config
        && nixosComposed.config.services.bird.settings.protocols.device0.scanTime == 4;
    nixosTypedReferenceComposition =
      nixosComposed.config.services.bird.settings.protocols.peer.channels.ipv4.export
        == reference "filter" "allow";
    nixosRawOnlyPreserved =
      (nixos [{ services.bird.config = rawText; }]).config.services.bird.config == rawText;
    nixosRawAndSettingsConflict =
      !(nixosAccepts [
        structured
        { services.bird.config = rawText; }
      ]);
    nixosForcedRawAndSettingsConflict =
      !(nixosAccepts [
        structured
        { services.bird.config = lib.mkForce rawText; }
      ]);
  }
  // lib.mapAttrs (_name: modules: fails modules) invalid;
  verified = lib.mapAttrs
    (
      name: passed: if passed then true else throw "BIRD evaluation assertion failed: ${name}"
    )
    assertions;
in
{
  derivation =
    pkgs.runCommand "bird-evaluation"
      {
        results = lib.toJSON verified;
        normalized = lib.toJSON example.config;
        passAsFile = [
          "results"
          "normalized"
        ];
      }
      ''
        mkdir -p "$out"
        cp "$resultsPath" "$out/assertions.json"
        cp "$normalizedPath" "$out/example-normalized.json"
      '';

  parserCases = {
    composed = merged.text;
    example = example.text;
    extended = extended.text;
    recursive = recursive.text;
    templated = templated.text;
    declared = declared.text;
    bfd = bfdCase.text;
    globals = globals.text;
    filters = filterCase.text;
  };
}
