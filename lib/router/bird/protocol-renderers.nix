{ lib }:
let
  inherit (lib)
    concatMap
    concatMapStringsSep
    imap0
    mapAttrsToList
    optionalString
    ;
  channels = ctx: cfg: ctx.join (mapAttrsToList ctx.channel (cfg.channels or { }));
  validateChannels =
    ctx: name: cfg:
    concatMap (item: item) (
      mapAttrsToList
        (
          family: channel: ctx.channel "protocols.${name}.channels.${family}" cfg.type family channel
        )
        (cfg.channels or { })
    );
  channelCount =
    ctx: name: cfg: expected:
    ctx.error "protocols.${name}.channels"
      (
        lib.length (lib.attrNames (cfg.channels or { })) == expected
      ) "${cfg.type} requires exactly ${toString expected} IPv4 or IPv6 channel";
  familyOf =
    cfg:
    let
      names = lib.attrNames (cfg.channels or { });
    in
    if lib.length names == 1 then lib.head names else null;
  nullableUint =
    ctx: path: bits: value:
    lib.optionals (value != null) (ctx.uint path bits value);
  endpoint =
    ctx: path: required: cfg:
    ctx.uint "${path}.asn" 32 (cfg.asn or null)
    ++ ctx.error "${path}.asn"
      (
        !(lib.isInt (cfg.asn or null)) || cfg.asn != 0
      ) "ASN must be nonzero"
    ++ ctx.error "${path}.address"
      (
        !required || (cfg.address or null) != null
      ) "neighbor address is required"
    ++ lib.optionals ((cfg.address or null) != null) (ctx.ip "${path}.address" cfg.address)
    ++ nullableUint ctx "${path}.port" 16 (cfg.port or null)
    ++ ctx.error "${path}.port"
      (
        (cfg.port or null) == null || !lib.isInt cfg.port || cfg.port > 0
      ) "port must be in 1..65535";
  interfaceList =
    ctx: patterns:
    concatMapStringsSep ", "
      (
        interface:
        if lib.isString interface then
          ctx.quote interface
        else
          "${optionalString interface.exclude "-"}${ctx.quote interface.pattern}"
      )
      patterns;
  validatePatterns =
    ctx: path: patterns:
    concatMap (item: item) (
      imap0
        (
          i: interface:
          let
            p = "${path}[${toString i}]";
            pattern = if lib.isString interface then interface else interface.pattern;
          in
          ctx.string p pattern
          ++ ctx.error p (pattern != "") "interface patterns must not be empty"
          ++ lib.optionals (lib.isAttrs interface) (
            ctx.error "${p}.exclude" (lib.isBool interface.exclude) "expected a boolean"
          )
        )
        patterns
    );
  switchOf =
    ctx: path: value:
    ctx.error path
      (lib.elem value [
        null
        true
        false
      ]) "expected a boolean";
  # bfd sessions need a bfd protocol to exist, whichever protocol requests them
  bfdAvailable =
    ctx:
    lib.any (protocol: (protocol.type or null) == "bfd" && (protocol.disabled or null) != true) (
      lib.attrValues (ctx.config.protocols or { })
    );
  bfdTimers = [
    {
      field = "interval";
      label = "interval";
    }
    {
      field = "minRxInterval";
      label = "min rx interval";
    }
    {
      field = "minTxInterval";
      label = "min tx interval";
    }
    {
      field = "idleTxInterval";
      label = "idle tx interval";
    }
  ];
  bfdItems =
    ctx: options:
    ctx.join (
      map
        (
          timer:
          optionalString (options.${timer.field} != null) "${timer.label} ${toString options.${timer.field}} ms;"
        )
        bfdTimers
      ++ [
        (optionalString (options.multiplier != null) "multiplier ${toString options.multiplier};")
        (optionalString (options.passive != null) "passive ${ctx.switch options.passive};")
        options.extraConfig
      ]
    );
  bfdBlock =
    ctx: header: items:
    if items == "" then "${header};" else "${ctx.block header items};";
  validateBfdOptions =
    ctx: path: options:
    concatMap
      (
        timer:
        let
          value = options.${timer.field};
        in
        lib.optionals (value != null) (
          ctx.uint "${path}.${timer.field}" 32 value
          ++ ctx.error "${path}.${timer.field}"
            (
              !lib.isInt value || (value >= 1 && value <= 4294967)
            ) "BFD intervals must be in 1..4294967 milliseconds"
        )
      )
      bfdTimers
    ++ ctx.error "${path}.interval"
      (
        options.interval == null || (options.minRxInterval == null && options.minTxInterval == null)
      ) "interval sets both directions, so it cannot be combined with minRxInterval or minTxInterval"
    ++ ctx.error "${path}.multiplier"
      (
        options.multiplier == null
        || (lib.isInt options.multiplier && options.multiplier >= 1 && options.multiplier <= 255)
      ) "BFD multiplier must be in 1..255"
    ++ switchOf ctx "${path}.passive" options.passive
    ++ ctx.native "${path}.extraConfig" options.extraConfig;
  validateBfdNeighbor =
    ctx: name: index: neighbor:
    let
      path = "protocols.${name}.neighbors[${toString index}]";
      addressInfo = ctx.ipInfo neighbor.address;
      localInfo = ctx.ipInfo neighbor.local;
    in
    ctx.ip "${path}.address" neighbor.address
    ++ ctx.error "${path}.interface"
      (
        addressInfo.scope == null || neighbor.interface == null || addressInfo.scope == neighbor.interface
      ) "address scope and interface disagree"
    ++ lib.optionals (neighbor.interface != null) (
      ctx.string "${path}.interface" neighbor.interface
      ++ ctx.error "${path}.interface" (neighbor.interface != "") "interface name must not be empty"
    )
    ++ lib.optionals (neighbor.local != null) (
      ctx.ip "${path}.local" neighbor.local
      ++ ctx.error "${path}.local" (localInfo.scope == null) "local address cannot contain an interface scope"
      ++ ctx.error "${path}.local"
        (
          !localInfo.valid || !addressInfo.valid || localInfo.family == addressInfo.family
        ) "local and neighbor addresses must have the same address family"
    )
    ++ switchOf ctx "${path}.multihop" neighbor.multihop
    ++ ctx.error "${path}.multihop"
      (
        neighbor.multihop != true || (neighbor.interface == null && addressInfo.scope == null)
      ) "a multihop neighbor cannot name an interface"
    ++ ctx.error "${path}.local"
      (
        neighbor.multihop != true || neighbor.local != null
      ) "a multihop neighbor requires a local address";
  endpointText =
    ctx: label: cfg:
    "${label}${optionalString ((cfg.address or null) != null) " ${ctx.address cfg.address}"}${
      optionalString ((cfg.port or null) != null) " port ${toString cfg.port}"
    } as ${toString cfg.asn};";
  staticDestination =
    ctx: destination:
    if destination.type != "via" then
      destination.type
    else
      "via ${
        if destination.gateway != null then
          ctx.address destination.gateway
        else
          ctx.quote destination.interface
      }"
      + optionalString
        (
          destination.gateway != null && destination.interface != null
        ) " dev ${ctx.quote destination.interface}"
      + optionalString (destination.onlink != null) " onlink ${ctx.switch destination.onlink}"
      + optionalString (destination.weight != null) " weight ${toString destination.weight}"
      + optionalString (destination.bfd != null) " bfd ${ctx.switch destination.bfd}";
  validateRoute =
    ctx: protocolName: family: index: route:
    let
      path = "protocols.${protocolName}.routes[${toString index}]";
      info = ctx.prefixInfo route.prefix;
      destination = route.destination;
      via = destination.type == "via";
      gateway = destination.gateway or null;
      gatewayInfo = ctx.ipInfo gateway;
      interface = destination.interface or null;
      scope = (ctx.scopeFor "static") // {
        inherit family;
      };
    in
    ctx.prefix "${path}.prefix" route.prefix
    ++ ctx.error "${path}.prefix"
      (
        !info.valid || family == null || info.family == family
      ) "static-route prefix does not match the protocol channel address family"
    ++ ctx.error "${path}.destination.type"
      (lib.elem destination.type [
        "via"
        "blackhole"
        "unreachable"
        "prohibit"
      ]) "unsupported static-route destination"
    ++ ctx.error "${path}.destination"
      (
        !via || gateway != null || interface != null
      ) "via destinations require a gateway or interface"
    ++ ctx.error "${path}.destination"
      (
        via
        || (
          gateway == null
          && interface == null
          && (destination.onlink or null) == null
          && (destination.weight or null) == null
          && (destination.bfd or null) == null
        )
      ) "special destinations cannot have next-hop options"
    ++ lib.optionals (gateway != null) (
      ctx.ip "${path}.destination.gateway" gateway
      ++ ctx.error "${path}.destination.gateway"
        (
          !gatewayInfo.valid || family == null || gatewayInfo.family == family
        ) "static-route gateway does not match the protocol channel address family"
      ++ ctx.error "${path}.destination"
        (
          gatewayInfo.scope == null || interface == null || gatewayInfo.scope == interface
        ) "gateway scope and interface disagree"
    )
    ++ lib.optionals (interface != null) (
      ctx.string "${path}.destination.interface" interface
      ++ ctx.error "${path}.destination.interface" (interface != "") "interface name must not be empty"
    )
    ++ ctx.error "${path}.destination.onlink"
      (lib.elem (destination.onlink or null) [
        null
        true
        false
      ]) "expected a boolean"
    ++ ctx.error "${path}.destination.onlink"
      (
        (destination.onlink or null) != true
        || (gateway != null && (interface != null || gatewayInfo.scope != null))
      ) "onlink requires a gateway and an explicit interface"
    ++ switchOf ctx "${path}.destination.bfd" (destination.bfd or null)
    ++ ctx.error "${path}.destination.bfd"
      (
        (destination.bfd or null) != true || gateway != null
      ) "bfd requires a gateway"
    ++ ctx.error "${path}.destination.bfd"
      (
        (destination.bfd or null) != true || (destination.onlink or null) != true
      ) "bird cannot combine bfd and onlink on one next hop"
    ++ ctx.error "${path}.destination.bfd"
      (
        (destination.bfd or null) != true || bfdAvailable ctx
      ) "bfd requires an enabled bfd protocol"
    ++ lib.optionals ((destination.weight or null) != null) (
      ctx.uint "${path}.destination.weight" 32 destination.weight
      ++ ctx.error "${path}.destination.weight"
        (
          !lib.isInt destination.weight || (destination.weight >= 1 && destination.weight <= 256)
        ) "next-hop weight must be in 1..256"
    )
    ++ ctx.statements "${path}.body" scope (route.body or [ ]);
  kernelConflicts =
    ctx: name: cfg:
    let
      family = familyOf cfg;
      tableName =
        declaration:
        let
          channel = declaration.channels.${family};
        in
        if (channel.table or null) == null then
          (if family == "ipv4" then "master4" else "master6")
        else
          channel.table.name;
      others = lib.filterAttrs
        (
          otherName: other:
            otherName != name && (other.type or null) == "kernel" && family != null && familyOf other == family
        )
        (ctx.config.protocols or { });
    in
    lib.optionals (family != null) (
      concatMap (item: item) (
        mapAttrsToList
          (
            otherName: other:
            ctx.error "protocols.${name}.channels.${family}.table"
              (
                tableName cfg != tableName other
              ) "kernel protocols '${name}' and '${otherName}' cannot share a BIRD routing table"
            ++
            ctx.error "protocols.${name}.kernelTable" ((cfg.kernelTable or null) != (other.kernelTable or null))
              "kernel protocols '${name}' and '${otherName}' cannot share an OS kernel table in the same address family"
          )
          others
      )
    );
in
{
  device = {
    render =
      ctx: name: cfg:
      ctx.protocol name cfg (optionalString (cfg.scanTime != null) "scan time ${toString cfg.scanTime};");
    validate =
      ctx: name: cfg:
      nullableUint ctx "protocols.${name}.scanTime" 32 cfg.scanTime;
  };
  direct = {
    render =
      ctx: name: cfg:
      ctx.protocol name cfg (
        ctx.join [
          (optionalString (cfg.interfaces != [ ]) "interface ${interfaceList ctx cfg.interfaces};")
          (optionalString (cfg.checkLink != null) "check link ${ctx.switch cfg.checkLink};")
          (channels ctx cfg)
        ]
      );
    validate =
      ctx: name: cfg:
      validateChannels ctx name cfg
      ++ validatePatterns ctx "protocols.${name}.interfaces" cfg.interfaces
      ++ ctx.error "protocols.${name}.checkLink"
        (lib.elem cfg.checkLink [
          null
          true
          false
        ]) "expected a boolean";
  };
  bfd = {
    # bfd_copy_config drops the interfaces and neighbors of a template
    inheritable = false;
    render =
      ctx: name: cfg:
      ctx.protocol name cfg (
        ctx.join (
          [
            (optionalString (cfg.accept != null) "accept${
              optionalString (cfg.accept.family != null) " ${cfg.accept.family}"
            }${optionalString (cfg.accept.transport != null) " ${cfg.accept.transport}"};")
            (optionalString (cfg.strictBind != null) "strict bind ${ctx.switch cfg.strictBind};")
          ]
          ++ map
            (
              interface: bfdBlock ctx "interface ${interfaceList ctx interface.patterns}" (bfdItems ctx interface)
            )
            cfg.interfaces
          ++ [ (optionalString (cfg.multihop != null) (bfdBlock ctx "multihop" (bfdItems ctx cfg.multihop))) ]
          ++ map
            (
              neighbor:
              "neighbor ${ctx.address neighbor.address}${
                optionalString (neighbor.interface != null) " dev ${ctx.quote neighbor.interface}"
              }${optionalString (neighbor.local != null) " local ${ctx.address neighbor.local}"}${
                optionalString (neighbor.multihop != null) " multihop ${ctx.switch neighbor.multihop}"
              };"
            )
            cfg.neighbors
        )
      );
    validate =
      ctx: name: cfg:
      switchOf ctx "protocols.${name}.strictBind" cfg.strictBind
      ++ concatMap (item: item) (
        imap0
          (
            i: interface:
            let
              path = "protocols.${name}.interfaces[${toString i}]";
            in
            ctx.error "${path}.patterns" (interface.patterns != [ ]) "a BFD interface block needs at least one pattern"
            ++ validatePatterns ctx "${path}.patterns" interface.patterns
            ++ validateBfdOptions ctx path interface
          )
          cfg.interfaces
      )
      ++ lib.optionals (cfg.multihop != null) (validateBfdOptions ctx "protocols.${name}.multihop" cfg.multihop)
      ++ concatMap (item: item) (imap0 (validateBfdNeighbor ctx name) cfg.neighbors);
  };
  kernel = {
    render =
      ctx: name: cfg:
      ctx.protocol name cfg (
        ctx.join [
          (optionalString (cfg.kernelTable != null) "kernel table ${toString cfg.kernelTable};")
          (optionalString (cfg.scanTime != null) "scan time ${toString cfg.scanTime};")
          (optionalString (cfg.learn != null) "learn ${if lib.isBool cfg.learn then ctx.switch cfg.learn else cfg.learn};")
          (optionalString (cfg.persist != null) "persist ${ctx.switch cfg.persist};")
          (optionalString (cfg.metric != null) "metric ${toString cfg.metric};")
          (channels ctx cfg)
        ]
      );
    validate =
      ctx: name: cfg:
      channelCount ctx name cfg 1
      ++ validateChannels ctx name cfg
      ++ nullableUint ctx "protocols.${name}.scanTime" 32 cfg.scanTime
      ++ nullableUint ctx "protocols.${name}.kernelTable" 32 cfg.kernelTable
      ++ nullableUint ctx "protocols.${name}.metric" 32 cfg.metric
      ++ ctx.error "protocols.${name}.learn"
        (lib.elem cfg.learn [
          null
          false
          true
          "all"
        ]) "learn must be a switch or all"
      ++ ctx.error "protocols.${name}.persist"
        (lib.elem cfg.persist [
          null
          true
          false
        ]) "expected a boolean"
      ++ kernelConflicts ctx name cfg;
  };
  static = {
    render =
      ctx: name: cfg:
      ctx.protocol name cfg (
        ctx.join [
          (channels ctx cfg)
          (concatMapStringsSep "\n"
            (
              route:
              let
                header = "route ${route.prefix} ${staticDestination ctx route.destination}";
              in
              if route.body == [ ] then "${header};" else "${ctx.block header (ctx.body route.body)};"
            )
            cfg.routes)
        ]
      );
    validate =
      ctx: name: cfg:
      channelCount ctx name cfg 1
      ++ validateChannels ctx name cfg
      ++ concatMap (item: item) (imap0 (validateRoute ctx name (familyOf cfg)) cfg.routes);
  };
  bgp = {
    render =
      ctx: name: cfg:
      ctx.protocol name cfg (
        ctx.join [
          (optionalString (cfg.local != null) (endpointText ctx "local" cfg.local))
          (optionalString (cfg.neighbor != null) (endpointText ctx "neighbor" cfg.neighbor))
          (
            if cfg.transport == null then
              ""
            else if cfg.transport.type == "direct" then
              "direct;"
            else
              "multihop${optionalString (cfg.transport.hops != null) " ${toString cfg.transport.hops}"};"
          )
          (optionalString (cfg.sourceAddress != null) "source address ${ctx.address cfg.sourceAddress};")
          (optionalString (cfg.interface != null) "interface ${ctx.quote cfg.interface};")
          (optionalString (cfg.onlink != null) "onlink ${ctx.switch cfg.onlink};")
          (optionalString (cfg.passive != null) "passive ${ctx.switch cfg.passive};")
          (optionalString (cfg.localRole != null) "local role ${cfg.localRole};")
          (optionalString (cfg.requireRoles != null) "require roles ${ctx.switch cfg.requireRoles};")
          (optionalString (cfg.allowLocalAs != null) "allow local as${
            optionalString (lib.isInt cfg.allowLocalAs) " ${toString cfg.allowLocalAs}"
          };")
          (optionalString (cfg.enforceFirstAs != null) "enforce first as ${ctx.switch cfg.enforceFirstAs};")
          (optionalString (cfg.gracefulRestart != null) "graceful restart ${cfg.gracefulRestart};")
          (optionalString (cfg.gracefulRestartTime != null) "graceful restart time ${toString cfg.gracefulRestartTime};")
          (optionalString (cfg.enableRouteRefresh != null) "enable route refresh ${ctx.switch cfg.enableRouteRefresh};")
          (optionalString (cfg.defaultBgpLocalPref != null) "default bgp_local_pref ${toString cfg.defaultBgpLocalPref};")
          (optionalString (cfg.holdTime != null) "hold time ${toString cfg.holdTime};")
          (optionalString (cfg.keepaliveTime != null) "keepalive time ${toString cfg.keepaliveTime};")
          (optionalString (cfg.bfd != null) "bfd ${ctx.switch cfg.bfd};")
          (optionalString (cfg.ttlSecurity != null) "ttl security ${ctx.switch cfg.ttlSecurity};")
          (optionalString (cfg.password != null) "password ${ctx.value cfg.password};")
          (channels ctx cfg)
        ]
      );
    validate =
      ctx: name: cfg:
      let
        path = "protocols.${name}";
        local = if cfg.local == null then { } else cfg.local;
        neighbor = if cfg.neighbor == null then { } else cfg.neighbor;
        localInfo = ctx.ipInfo (local.address or null);
        neighborInfo = ctx.ipInfo (neighbor.address or null);
        sourceInfo = ctx.ipInfo cfg.sourceAddress;
        localSourceMatch =
          !localInfo.valid
          || !sourceInfo.valid
          || (localInfo.family == sourceInfo.family && localInfo.words == sourceInfo.words);
        password = ctx.expression "${path}.password" (ctx.scopeFor "define") cfg.password;
        internal = cfg.local != null && cfg.neighbor != null && local.asn == neighbor.asn;
        # an unset transport is direct for eBGP and multihop for iBGP
        multihop = if cfg.transport != null then cfg.transport.type == "multihop" else internal;
        linkLocal = info: info.valid && info.family == "ipv6" && lib.bitAnd (lib.head info.words) 65472 == 65152;
        interface = if cfg.interface != null then cfg.interface else neighborInfo.scope;
      in
      # endpoints may come from a template, so only the effective declaration must have both
      ctx.error "${path}.local" (cfg.local != null) "BGP requires a local ASN"
      ++ ctx.error "${path}.neighbor" (cfg.neighbor != null) "BGP requires a neighbor"
      ++ lib.optionals (cfg.local != null) (endpoint ctx "${path}.local" false local)
      ++ lib.optionals (cfg.neighbor != null) (endpoint ctx "${path}.neighbor" true neighbor)
      ++ ctx.error "${path}.channels"
        (
          lib.attrNames cfg.channels != [ ]
        ) "BGP requires at least one channel"
      ++ validateChannels ctx name cfg
      ++ ctx.error "${path}.local.address"
        (
          !localInfo.valid || !neighborInfo.valid || localInfo.family == neighborInfo.family
        ) "local and neighbor transport addresses must have the same address family"
      ++ lib.optionals (cfg.sourceAddress != null) (
        ctx.ip "${path}.sourceAddress" cfg.sourceAddress
        ++ ctx.error "${path}.sourceAddress"
          (
            sourceInfo.scope == null
          ) "source address cannot contain an interface scope"
        ++ ctx.error "${path}.sourceAddress"
          (
            !sourceInfo.valid || !neighborInfo.valid || sourceInfo.family == neighborInfo.family
          ) "source and neighbor transport addresses must have the same address family"
        ++
        ctx.error "${path}.sourceAddress" localSourceMatch
          "sourceAddress and local.address must identify the same address when both are set"
      )
      # an unset transport is bird's choice, direct for eBGP and multihop for iBGP
      ++ lib.optionals (cfg.transport != null) (
        ctx.error "${path}.transport.type"
          (lib.elem cfg.transport.type [
            "direct"
            "multihop"
          ]) "transport must be direct or multihop"
        ++ ctx.error "${path}.transport.hops"
          (
            cfg.transport.type == "multihop" || cfg.transport.hops == null
          ) "direct transport cannot specify a multihop limit"
        ++ lib.optionals (cfg.transport.hops != null) (
          ctx.uint "${path}.transport.hops" 8 cfg.transport.hops
          ++ ctx.error "${path}.transport.hops"
            (
              !lib.isInt cfg.transport.hops || cfg.transport.hops >= 1
            ) "multihop limit must be in 1..255"
        )
      )
      ++ ctx.error "${path}.gracefulRestart"
        (lib.elem cfg.gracefulRestart [
          null
          "aware"
          "on"
          "off"
        ]) "invalid graceful-restart mode"
      ++ lib.optionals (cfg.holdTime != null) (
        ctx.uint "${path}.holdTime" 16 cfg.holdTime
        ++ ctx.error "${path}.holdTime"
          (
            !lib.isInt cfg.holdTime || cfg.holdTime == 0 || cfg.holdTime >= 3
          ) "hold time must be zero or in 3..65535"
      )
      ++ lib.optionals (cfg.keepaliveTime != null) (
        ctx.uint "${path}.keepaliveTime" 16 cfg.keepaliveTime
        ++ ctx.error "${path}.keepaliveTime"
          (
            !lib.isInt cfg.keepaliveTime || cfg.keepaliveTime >= 1
          ) "keepalive time must be in 1..65535"
      )
      ++ switchOf ctx "${path}.bfd" cfg.bfd
      ++ switchOf ctx "${path}.ttlSecurity" cfg.ttlSecurity
      ++ ctx.error "${path}.bfd" (cfg.bfd != true || bfdAvailable ctx) "bfd requires an enabled bfd protocol"
      ++ ctx.error "${path}.bfd"
        (
          cfg.bfd != true || !multihop || (local.address or null) != null || cfg.sourceAddress != null
        ) "multihop BGP with bfd requires a local or source address"
      ++ lib.concatMap (field: switchOf ctx "${path}.${field}" cfg.${field}) [
        "onlink"
        "passive"
        "requireRoles"
        "enableRouteRefresh"
        "enforceFirstAs"
      ]
      ++ lib.optionals (cfg.interface != null) (
        ctx.string "${path}.interface" cfg.interface
        ++ ctx.error "${path}.interface" (cfg.interface != "") "interface name must not be empty"
        ++ ctx.error "${path}.interface"
          (
            neighborInfo.scope == null || neighborInfo.scope == cfg.interface
          ) "interface and neighbor address scope disagree"
      )
      ++ ctx.error "${path}.interface"
        (
          interface != null || !(linkLocal localInfo || linkLocal neighborInfo || linkLocal sourceInfo)
        ) "link-local addresses require an interface"
      ++ ctx.error "${path}.transport"
        (
          !multihop || !(linkLocal localInfo || linkLocal neighborInfo || linkLocal sourceInfo)
        ) "multihop BGP cannot use link-local addresses"
      ++ ctx.error "${path}.interface" (!multihop || interface == null) "multihop BGP cannot be bound to an interface"
      ++ ctx.error "${path}.onlink" (!multihop || cfg.onlink != true) "multihop BGP cannot be onlink"
      ++ ctx.error "${path}.onlink"
        (
          cfg.onlink != true || interface != null || cfg.passive == true
        ) "an active onlink session needs an interface"
      ++ ctx.error "${path}.localRole" (!internal || cfg.localRole == null) "a local role cannot be set on an iBGP session"
      ++ ctx.error "${path}.requireRoles"
        (
          cfg.requireRoles != true || cfg.localRole != null
        ) "requiring roles needs a local role"
      ++ ctx.error "${path}.enforceFirstAs"
        (
          !internal || cfg.enforceFirstAs != true
        ) "enforcing the first AS needs an eBGP session"
      ++ ctx.error "${path}.allowLocalAs"
        (
          cfg.allowLocalAs != false
        ) "bird has no off form for allow local as, set 0 to forbid the local AS"
      ++ lib.optionals (lib.isInt cfg.allowLocalAs) (nullableUint ctx "${path}.allowLocalAs" 32 cfg.allowLocalAs)
      ++ lib.optionals (cfg.gracefulRestartTime != null) (
        ctx.uint "${path}.gracefulRestartTime" 32 cfg.gracefulRestartTime
        ++ ctx.error "${path}.gracefulRestartTime"
          (
            !lib.isInt cfg.gracefulRestartTime || cfg.gracefulRestartTime < 4096
          ) "graceful restart time must be less than 4096"
      )
      ++ nullableUint ctx "${path}.defaultBgpLocalPref" 32 cfg.defaultBgpLocalPref
      ++ lib.optionals (cfg.password != null) (
        password.errors
        ++ ctx.error "${path}.password"
          (
            password.type == "string" && password.constant
          ) "password must be a literal string or a constant string-valued define/external reference"
      )
      ++ concatMap (item: item) (
        mapAttrsToList
          (
            family: channel:
            ctx.error "${path}.channels.${family}.extendedNextHop"
              (
                family != "ipv4"
                || neighborInfo.family != "ipv6"
                || (ctx.ipInfo channel.nextHopAddress).family == "ipv4"
                || channel.extendedNextHop == true
              ) "IPv4 routes over an IPv6 transport require extendedNextHop = true or an explicit IPv4 next hop"
          )
          cfg.channels
      );
  };
}
