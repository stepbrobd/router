{ std, ... }:

let
  # build a set of constant attrsets from a list of names and a key
  mkConstants = key: names:
    builtins.listToAttrs (map (n: { name = n; value = { ${key} = n; }; }) names);

  mkEnumAttrType = name: attrName: validValues:
    std.types.mkOptionType {
      inherit name;
      description = "${name} (one of: ${std.concatStringsSep ", " validValues})";
      check = v: builtins.isAttrs v && v ? ${attrName} && builtins.elem v.${attrName} validValues;
      merge = std.options.mergeEqualOption;
    };

  constants = {
    peering = mkConstants "type" [ "disabled" "direct" "multihop" ];

    policy = mkConstants "decision" [ "accept" "reject" ];

    roa = mkConstants "status" [ "valid" "invalid" "unknown" "notFound" ];

    addPaths = mkConstants "mode" [ "off" "rx" "tx" "switch" ];

    route = mkConstants "action" [ "blackhole" "unreachable" "prohibit" ] // {
      via = addr: { action = "via"; gateway = addr; };
    };

    multiprotocol = mkConstants "mode" [ "v4overV6" "v6overV4" ];

    ospf = mkConstants "version" [ "v2" "v3" ];

    area = mkConstants "type" [ "normal" "stub" "nssa" ];

    # operators map to their symbolic form
    cmp = {
      eq = { op = "="; };
      ne = { op = "!="; };
      lt = { op = "<"; };
      gt = { op = ">"; };
      le = { op = "<="; };
      ge = { op = ">="; };
    };

    af = mkConstants "family" [ "ipv4" "ipv6" ];

    babel = mkConstants "type" [ "wired" "wireless" ];

    bmp = mkConstants "mode" [ "prePolicy" "postPolicy" ];
  };

  types = {
    peeringType = mkEnumAttrType "peeringType" "type"
      [ "disabled" "direct" "multihop" ];

    policyType = mkEnumAttrType "policyType" "decision"
      [ "accept" "reject" ];

    roaStatusType = mkEnumAttrType "roaStatusType" "status"
      [ "valid" "invalid" "unknown" "notFound" ];

    addPathsType = mkEnumAttrType "addPathsType" "mode"
      [ "off" "rx" "tx" "switch" ];

    cmpType = mkEnumAttrType "cmpType" "op"
      [ "=" "!=" "<" ">" "<=" ">=" ];

    multiprotocolType = mkEnumAttrType "multiprotocolType" "mode"
      [ "v4overV6" "v6overV4" ];

    ospfVersionType = mkEnumAttrType "ospfVersionType" "version"
      [ "v2" "v3" ];

    areaTypeType = mkEnumAttrType "areaTypeType" "type"
      [ "normal" "stub" "nssa" ];

    babelChannelType = mkEnumAttrType "babelChannelType" "type"
      [ "wired" "wireless" ];

    bmpModeType = mkEnumAttrType "bmpModeType" "mode"
      [ "prePolicy" "postPolicy" ];

    # via requires a gateway attribute alongside the action
    routeActionType = std.types.mkOptionType {
      name = "routeActionType";
      description = "route action (blackhole, unreachable, prohibit, or via with gateway)";
      check = v:
        builtins.isAttrs v
        && v ? action
        && builtins.elem v.action [ "blackhole" "unreachable" "prohibit" "via" ]
        && (v.action != "via" || v ? gateway);
      merge = std.options.mergeEqualOption;
    };
  };

in
constants // { inherit types; }
