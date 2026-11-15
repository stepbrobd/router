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
        builtins.length (builtins.attrNames (cfg.channels or { })) == expected
      ) "${cfg.type} requires exactly ${toString expected} IPv4 or IPv6 channel";
  familyOf =
    cfg:
    let
      names = builtins.attrNames (cfg.channels or { });
    in
    if builtins.length names == 1 then builtins.head names else null;
  nullableUint =
    ctx: path: bits: value:
    lib.optionals (value != null) (ctx.uint path bits value);
  endpoint =
    ctx: path: required: cfg:
    ctx.uint "${path}.asn" 32 (cfg.asn or null)
    ++ ctx.error "${path}.asn"
      (
        !(builtins.isInt (cfg.asn or null)) || cfg.asn != 0
      ) "ASN must be nonzero"
    ++ ctx.error "${path}.address"
      (
        !required || (cfg.address or null) != null
      ) "neighbor address is required"
    ++ lib.optionals ((cfg.address or null) != null) (ctx.ip "${path}.address" cfg.address)
    ++ nullableUint ctx "${path}.port" 16 (cfg.port or null)
    ++ ctx.error "${path}.port"
      (
        (cfg.port or null) == null || !builtins.isInt cfg.port || cfg.port > 0
      ) "port must be in 1..65535";
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
      + optionalString destination.onlink " onlink on"
      + optionalString (destination.weight != null) " weight ${toString destination.weight}";
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
      (builtins.elem destination.type [
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
          && !(destination.onlink or false)
          && (destination.weight or null) == null
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
      (builtins.isBool (
        destination.onlink or false
      )) "expected a boolean"
    ++ ctx.error "${path}.destination.onlink"
      (
        !(destination.onlink or false)
        || (gateway != null && (interface != null || gatewayInfo.scope != null))
      ) "onlink requires a gateway and an explicit interface"
    ++ lib.optionals ((destination.weight or null) != null) (
      ctx.uint "${path}.destination.weight" 32 destination.weight
      ++ ctx.error "${path}.destination.weight"
        (
          !builtins.isInt destination.weight || (destination.weight >= 1 && destination.weight <= 256)
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
      ctx.uint "protocols.${name}.scanTime" 32 cfg.scanTime;
  };
  direct = {
    render =
      ctx: name: cfg:
      ctx.protocol name cfg (
        ctx.join [
          (optionalString (cfg.interfaces != [ ])
            "interface ${
              concatMapStringsSep ", " (
                interface:
                if builtins.isString interface then
                  ctx.quote interface
                else
                  "${optionalString interface.exclude "-"}${ctx.quote interface.pattern}"
              ) cfg.interfaces
            };"
          )
          (optionalString (cfg.checkLink != null) "check link ${ctx.switch cfg.checkLink};")
          (channels ctx cfg)
        ]
      );
    validate =
      ctx: name: cfg:
      validateChannels ctx name cfg
      ++ concatMap (item: item) (
        imap0
          (
            i: interface:
            let
              path = "protocols.${name}.interfaces[${toString i}]";
              pattern = if builtins.isString interface then interface else interface.pattern;
            in
            ctx.string path pattern
            ++ ctx.error path (pattern != "") "interface patterns must not be empty"
            ++ lib.optionals (builtins.isAttrs interface) (
              ctx.error "${path}.exclude" (builtins.isBool interface.exclude) "expected a boolean"
            )
          )
          cfg.interfaces
      )
      ++ ctx.error "protocols.${name}.checkLink"
        (builtins.elem cfg.checkLink [
          null
          true
          false
        ]) "expected a boolean";
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
      ++ ctx.uint "protocols.${name}.scanTime" 32 cfg.scanTime
      ++ nullableUint ctx "protocols.${name}.kernelTable" 32 cfg.kernelTable
      ++ nullableUint ctx "protocols.${name}.metric" 32 cfg.metric
      ++ ctx.error "protocols.${name}.learn"
        (builtins.elem cfg.learn [
          false
          true
          "all"
        ]) "learn must be a switch or all"
      ++ ctx.error "protocols.${name}.persist" (builtins.isBool cfg.persist) "expected a boolean"
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
          (optionalString (cfg.gracefulRestart != null) "graceful restart ${cfg.gracefulRestart};")
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
      in
      # endpoints may come from a template, so only the effective declaration must have both
      ctx.error "${path}.local" (cfg.local != null) "BGP requires a local ASN"
      ++ ctx.error "${path}.neighbor" (cfg.neighbor != null) "BGP requires a neighbor"
      ++ lib.optionals (cfg.local != null) (endpoint ctx "${path}.local" false local)
      ++ lib.optionals (cfg.neighbor != null) (endpoint ctx "${path}.neighbor" true neighbor)
      ++ ctx.error "${path}.channels"
        (
          builtins.attrNames cfg.channels != [ ]
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
      ++ ctx.error "${path}.transport.type"
        (builtins.elem cfg.transport.type [
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
            !builtins.isInt cfg.transport.hops || cfg.transport.hops >= 1
          ) "multihop limit must be in 1..255"
      )
      ++ ctx.error "${path}.gracefulRestart"
        (builtins.elem cfg.gracefulRestart [
          null
          "aware"
          "on"
          "off"
        ]) "invalid graceful-restart mode"
      ++ lib.optionals (cfg.holdTime != null) (
        ctx.uint "${path}.holdTime" 16 cfg.holdTime
        ++ ctx.error "${path}.holdTime"
          (
            !builtins.isInt cfg.holdTime || cfg.holdTime == 0 || cfg.holdTime >= 3
          ) "hold time must be zero or in 3..65535"
      )
      ++ lib.optionals (cfg.keepaliveTime != null) (
        ctx.uint "${path}.keepaliveTime" 16 cfg.keepaliveTime
        ++ ctx.error "${path}.keepaliveTime"
          (
            !builtins.isInt cfg.keepaliveTime || cfg.keepaliveTime >= 1
          ) "keepalive time must be in 1..65535"
      )
      ++ ctx.error "${path}.bfd" (builtins.isBool cfg.bfd) "expected a boolean"
      ++ ctx.error "${path}.ttlSecurity" (builtins.isBool cfg.ttlSecurity) "expected a boolean"
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
