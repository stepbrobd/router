{ lib, protocols }:
config:
let
  inherit (builtins)
    isAttrs
    isString
    isInt
    isBool
    isList
    attrNames
    length
    ;
  inherit (lib)
    concatMap
    concatStringsSep
    imap0
    mapAttrsToList
    ;
  internal = import ./internal.nix { inherit lib; } config;
  inherit (internal)
    ipInfo
    prefixInfo
    lookup
    infer
    typeOf
    matches
    ;
  error =
    path: condition: message:
    lib.optional (!condition) "${path}: ${message}";
  shape =
    path: required: optional: value:
    if !isAttrs value then
      [ "${path}: expected a tagged attribute set" ]
    else
      concatMap (name: error path (builtins.hasAttr name value) "missing field '${name}'") required
      ++ concatMap
        (
          name:
          error path (builtins.elem name (required ++ optional ++ [ "kind" ])) "unexpected field '${name}'"
        )
        (attrNames value);
  identifier =
    path: value:
    error path (matches "[A-Za-z0-9_.:-]+" value && builtins.stringLength value <= 64)
      "expected a BIRD symbol of at most 64 bytes using letters, digits, underscores, dots, colons or hyphens";
  string =
    path: value:
    error path
      (
        isString value
        && !(lib.hasInfix "\"" value)
        && !(lib.hasInfix "\n" value)
        && !(lib.hasInfix "\r" value)
        && builtins.stringLength value <= 4095
      )
      "expected a BIRD string of at most 4095 bytes without double quotes or newlines (BIRD has no string escapes)";
  native = path: value: error path (isString value) "expected native BIRD text";
  uint =
    path: bits: value:
    error path
      (
        isInt value && value >= 0 && value < internal.pow2 bits
      ) "expected an unsigned ${toString bits}-bit integer";
  ip = path: value: error path (ipInfo value).valid "expected a valid IPv4 or IPv6 address";
  prefix =
    path: value:
    let
      info = prefixInfo value;
    in
    error path info.valid "expected an IPv4 or IPv6 prefix with a valid prefix length"
    ++ error path (!info.valid || info.network) "prefix has nonzero host bits";
  birdTypes = [
    "bool"
    "int"
    "string"
    "ip"
    "prefix"
    "pair"
    "quad"
    "ec"
    "lc"
    "int set"
    "ip set"
    "prefix set"
    "pair set"
    "ec set"
    "lc set"
    "bgppath"
    "clist"
    "eclist"
    "lclist"
    "enum"
  ];
  type = path: value: error path (builtins.elem value birdTypes) "expected a supported BIRD type";
  expectType =
    path: expected: actual:
    error path (expected == null || actual.type == null || expected == actual.type)
      "expected ${if isString expected then expected else "a value"}, got ${
        if isString actual.type then actual.type else "an unknown type"
      }";
  sameFamily =
    path: left: right:
    error path
      (
        left.family == null || right.family == null || left.family == right.family
      ) "address families do not match";
  scopeFor = context: {
    inherit context;
    locals = { };
    returnType = null;
    family = null;
  };
  dependencies =
    path: value:
    if !isList value then
      [ "${path}: expected a list of declaration references" ]
    else
      concatMap (item: item) (
        imap0 (i: dependency: reference "${path}[${toString i}]" internal.targets dependency) value
      );
  signature =
    path: declaration:
    let
      params = declaration.params or [ ];
      names =
        if isList params then
          map
            (
              parameter: if isAttrs parameter && isString (parameter.name or null) then parameter.name else ""
            )
            params
        else
          [ ];
    in
    error "${path}.params" (isList params) "expected a list of typed parameters"
    ++ lib.optionals (isList params) (
      concatMap (item: item) (
        imap0
          (
            i: parameter:
            let
              p = "${path}.params[${toString i}]";
            in
            shape p [ "name" "type" ] [ ] parameter
            ++ identifier "${p}.name" (if isAttrs parameter then parameter.name or null else null)
            ++ type "${p}.type" (if isAttrs parameter then parameter.type or null else null)
            ++ error "${p}.type"
              (
                !isAttrs parameter || (parameter.type or null) != "enum"
              ) "function signatures require a concrete enum subtype, plain enum is only expression metadata"
          )
          params
      )
    )
    ++ error "${path}.params"
      (
        length names == length (lib.unique names)
      ) "parameter names must be unique"
    ++ error "${path}.params" (length names <= 255) "BIRD functions support at most 255 parameters"
    ++ lib.optionals ((declaration.returnType or null) != null) (
      type "${path}.returnType" declaration.returnType
      ++ error "${path}.returnType"
        (
          declaration.returnType != "enum"
        ) "function signatures require a concrete enum subtype, plain enum is only expression metadata"
    );
  reference =
    path: expected: node:
    let
      valid =
        isAttrs node
        && builtins.elem (node.kind or null) [
          "reference"
          "external"
        ];
      external = valid && node.kind == "external";
      target = if valid then node.target or null else null;
      name = if valid then node.name or null else null;
    in
    if !valid then
      [ "${path}: expected a ${concatStringsSep "/" expected} reference" ]
    else
      shape path [ "target" "name" ]
        (
          if external then
            [
              "type"
              "params"
              "returnType"
            ]
          else
            [ ]
        )
        node
      ++ identifier "${path}.name" name
      ++
      error "${path}.target" (builtins.elem target expected)
        "expected reference target ${concatStringsSep "/" expected}"
      ++ (
        if external then
          error "${path}.target"
            (builtins.elem target [
              "value"
              "function"
              "filter"
            ]) "external symbols must be values, functions or filters"
          ++ lib.optionals (target == "value") (type "${path}.type" (node.type or null))
          ++ lib.optionals (target == "function") (
            error "${path}.params"
              (
                node ? params
              ) "an external function requires an explicit parameter signature"
            ++ signature path node
          )
        else
          error path (lookup node != null)
            "reference does not identify a declared ${if isString target then target else "symbol"}"
      );
  attributeTypes = {
    net = "prefix";
    proto = "string";
    source = "enum";
    preference = "int";
    bgp_local_pref = "int";
    bgp_med = "int";
    bgp_path = "bgppath";
    bgp_next_hop = "ip";
    bgp_origin = "enum";
    bgp_community = "clist";
    bgp_large_community = "lclist";
    bgp_ext_community = "eclist";
    gw = "ip";
    ifname = "string";
    ifindex = "int";
    dest = "enum";
    igp_metric = "int";
    krt_metric = "int";
  };
  attributeType =
    node:
    if isString node then
      attributeTypes.${node} or null
    else if isAttrs node then
      node.type or null
    else
      null;
  prefixSet =
    path: node:
    let
      prefixes = node.prefixes or null;
      entries = if isList prefixes then prefixes else [ ];
      info =
        entry:
        prefixInfo (
          if isString entry then
            entry
          else if isAttrs entry then
            entry.prefix or null
          else
            null
        );
      families = lib.unique (
        builtins.filter (family: family != null) (map (entry: (info entry).family) entries)
      );
    in
    error "${path}.prefixes" (isList prefixes) "expected a list of prefixes"
    ++ error path (length families <= 1) "prefix sets must not mix IPv4 and IPv6"
    ++ concatMap (item: item) (
      imap0
        (
          i: entry:
          let
            p = "${path}.prefixes[${toString i}]";
            details = info entry;
            ranged = isAttrs entry && ((entry.ge or null) != null || (entry.le or null) != null);
            ge = if isAttrs entry && (entry.ge or null) != null then entry.ge else details.prefixLength;
            le = if isAttrs entry && (entry.le or null) != null then entry.le else details.maxLength;
            bound = n: isInt n && n >= 0 && n <= details.maxLength;
          in
          (
            if isString entry then
              prefix p entry
            else
              shape p [ "prefix" ] [ "ge" "le" ] entry
              ++ prefix "${p}.prefix" (if isAttrs entry then entry.prefix or null else null)
          )
          ++ lib.optionals ranged (
            error "${p}.ge" (bound ge) "prefix lower bound is outside its address family"
            ++ error "${p}.le" (bound le) "prefix upper bound is outside its address family"
            ++ error p (!(bound ge && bound le) || ge <= le) "prefix lower bound exceeds its upper bound"
          )
        )
        entries
    );
  community =
    path: node:
    let
      kind = node.type or null;
    in
    error "${path}.type"
      (builtins.elem kind [
        "standard"
        "large"
        "extended"
      ]) "unknown community type"
    ++ (
      if kind == "standard" then
        shape path [ "type" "asn" "value" ] [ ] node
        ++ uint "${path}.asn" 16 (node.asn or null)
        ++ uint "${path}.value" 16 (node.value or null)
      else if kind == "large" then
        shape path [ "type" "asn" "data1" "data2" ] [ ] node
        ++ concatMap (name: uint "${path}.${name}" 32 (node.${name} or null)) [
          "asn"
          "data1"
          "data2"
        ]
      else if kind == "extended" then
        let
          key = node.key or null;
          keyIP = ipInfo key;
          ipKey = isString key;
          shortValue = ipKey || (isInt key && key > 65535);
        in
        shape path [ "type" "communityType" "key" "value" ] [ ] node
        ++ error "${path}.communityType"
          (builtins.elem (node.communityType or null) [
            "rt"
            "ro"
          ]) "extended community kind must be rt or ro"
        ++ (
          if ipKey then
            error "${path}.key"
              (
                keyIP.valid && keyIP.family == "ipv4" && keyIP.scope == null
              ) "extended community IP key must be an unscoped IPv4 address"
          else
            uint "${path}.key" 32 key
        )
        ++ uint "${path}.value" (if shortValue then 16 else 32) (node.value or null)
      else
        [ ]
    );
  call =
    path: scope: statement: node:
    let
      function = node.function or null;
      declaration =
        if isAttrs function && (function.kind or null) == "external" then function else lookup function;
      args = node.arguments or null;
      params =
        if declaration != null && isList (declaration.params or null) then declaration.params else [ ];
      returnType = if declaration != null then declaration.returnType or null else null;
      localFunction =
        isAttrs function
        && (function.kind or null) == "reference"
        && (function.target or null) == "function"
        && isString (function.name or null)
        && declaration != null;
      functionKey = if localFunction then internal.key function else "";
      contextual =
        localFunction
        && !(builtins.elem functionKey (scope.calls or [ ]))
        && ((scope.family or null) != null || (scope.routeContext or scope.context) == "static");
      calleeScope = (scopeFor "function") // {
        family = scope.family or null;
        routeContext = scope.routeContext or scope.context;
        calls = (scope.calls or [ ]) ++ [ functionKey ];
        inherit returnType;
        locals = builtins.listToAttrs (
          imap0
            (i: parameter: {
              name = if isAttrs parameter && isString (parameter.name or null) then parameter.name else "";
              value = {
                type = if isAttrs parameter then parameter.type or null else null;
                family =
                  if isList args && i < length args then (infer scope [ ] (builtins.elemAt args i)).family else null;
              };
            })
            params
        );
      };
    in
    shape path [ "function" "arguments" ] [ ] node
    ++ reference "${path}.function" [ "function" ] function
    ++ error "${path}.arguments" (isList args) "expected an ordered argument list"
    ++ error "${path}.arguments"
      (
        declaration == null || !isList args || length args == length params
      ) "argument count does not match the function signature"
    ++ error path
      (
        statement || declaration == null || returnType != null
      ) "a void function cannot be used as an expression"
    ++ lib.optionals (isList args) (
      concatMap (item: item) (
        imap0
          (
            i: argument:
            let
              p = "${path}.arguments[${toString i}]";
              result = expression p scope argument;
              parameter = if i < length params then builtins.elemAt params i else { };
            in
            result.errors ++ expectType p (if isAttrs parameter then parameter.type or null else null) result
          )
          args
      )
    )
    ++ lib.optionals contextual (
      statements "${path}.callee.${function.name}.body" calleeScope (declaration.body or [ ])
    );
  expression =
    path: scope: node:
    let
      kind = if isAttrs node then node.kind or null else null;
      child = name: expression "${path}.${name}" scope (node.${name} or null);
      boolChild =
        name:
        let
          result = child name;
        in
        result.errors ++ expectType "${path}.${name}" "bool" result;
      errors =
        if isBool node then
          [ ]
        else if isInt node then
          uint path 32 node
        else if isString node then
          string path node
        else if !isAttrs node then
          [ "${path}: expected a literal or tagged BIRD expression" ]
        else if kind == "ip" then
          shape path [ "value" ] [ ] node
          ++ ip "${path}.value" (node.value or null)
          ++ error path
            (
              (ipInfo (node.value or null)).scope == null
            ) "IP expressions cannot contain an interface scope"
        else if kind == "prefix" then
          shape path [ "value" ] [ ] node ++ prefix "${path}.value" (node.value or null)
        else if kind == "prefixSet" then
          shape path [ "prefixes" ] [ ] node ++ prefixSet path node
        else if kind == "community" then
          community path node
        else if kind == "reference" then
          reference path [ "define" ] node
        else if kind == "external" then
          reference path [ "value" ] node
        else if kind == "attribute" then
          shape path [ "name" "type" ] [ ] node
          ++ identifier "${path}.name" (node.name or null)
          ++ type "${path}.type" (node.type or null)
          ++ error path
            (
              !(isString (node.name or null))
              || !(builtins.hasAttr node.name attributeTypes)
              || (node.type or null) == attributeTypes.${node.name}
            ) "built-in route attribute has the wrong declared type"
        else if kind == "local" then
          shape path [ "name" ] [ ] node
          ++ identifier "${path}.name" (node.name or null)
          ++ error path
            (
              isString (node.name or null) && builtins.hasAttr node.name (scope.locals or { })
            ) "local does not identify a function parameter in this scope"
        else if kind == "rawExpression" then
          shape path [ "text" ] [ "type" "dependsOn" ] node
          ++ native "${path}.text" (node.text or null)
          ++ error "${path}.text"
            (
              !isString (node.text or null) || node.text != ""
            ) "native expressions must not be empty"
          ++ dependencies "${path}.dependsOn" (node.dependsOn or [ ])
          ++ lib.optionals ((node.type or null) != null) (type "${path}.type" node.type)
        else if kind == "call" then
          call path scope false node
        else if kind == "all" || kind == "any" then
          shape path [ "values" ] [ ] node
          ++ error "${path}.values" (isList (node.values or null)) "expected an ordered expression list"
          ++ lib.optionals (isList (node.values or null)) (
            concatMap (item: item) (
              imap0
                (
                  i: value:
                    let
                      p = "${path}.values[${toString i}]";
                      result = expression p scope value;
                    in
                    result.errors ++ expectType p "bool" result
                )
                node.values
            )
          )
        else if kind == "not" then
          shape path [ "value" ] [ ] node ++ boolChild "value"
        else if kind == "compare" then
          let
            left = child "left";
            right = child "right";
            op = node.op or null;
            ordered = [
              "int"
              "string"
              "ip"
              "prefix"
              "pair"
              "quad"
              "ec"
              "lc"
              "enum"
            ];
          in
          shape path [ "op" "left" "right" ] [ ] node
          ++ error "${path}.op"
            (builtins.elem op [
              "="
              "!="
              "<"
              "<="
              ">"
              ">="
            ]) "unsupported comparison operator"
          ++ left.errors
          ++ right.errors
          ++ expectType path left.type right
          ++ sameFamily path left right
          ++ error path
            (
              builtins.elem op [
                "="
                "!="
              ]
              || left.type == null
              || builtins.elem left.type ordered
            ) "this type does not support ordered comparisons"
        else if kind == "inSet" then
          let
            value = child "value";
            set = child "set";
            members = {
              "prefix set" = [ "prefix" ];
              prefix = [
                "prefix"
                "ip"
              ];
              "ip set" = [ "ip" ];
              "int set" = [ "int" ];
              "pair set" = [
                "pair"
                "clist"
              ];
              "ec set" = [
                "ec"
                "eclist"
              ];
              "lc set" = [
                "lc"
                "lclist"
              ];
              clist = [ "pair" ];
              eclist = [ "ec" ];
              lclist = [ "lc" ];
              bgppath = [ "int" ];
            };
            allowed = if isString set.type then members.${set.type} or [ ] else [ ];
          in
          shape path [ "value" "set" ] [ ] node
          ++ value.errors
          ++ set.errors
          ++ error path
            (
              set.type == null || value.type == null || builtins.elem value.type allowed
            ) "membership operands have incompatible types"
          ++ sameFamily path value set
        else if kind == "fromProtocol" then
          shape path [ "protocol" ] [ ] node
          ++ reference "${path}.protocol" [ "protocol" ] (node.protocol or null)
        else
          [ "${path}: unknown expression kind" ];
    in
    (infer scope [ ] node) // { inherit errors; };
  statements =
    path: scope: nodes:
    if !isList nodes then
      [ "${path}: expected an ordered statement list" ]
    else
      concatMap (item: item) (imap0 (i: node: statement "${path}[${toString i}]" scope node) nodes);
  statement =
    path: scope: node:
    let
      kind = if isAttrs node then node.kind or null else null;
      value = expression "${path}.value" scope (node.value or null);
      condition = expression "${path}.condition" scope (node.condition or null);
    in
    if !isAttrs node then
      [ "${path}: expected a tagged BIRD statement" ]
    else if kind == "accept" || kind == "reject" then
      shape path [ ] [ ] node
      ++ error path
        (
          builtins.elem scope.context [
            "filter"
            "function"
          ]
          && (scope.routeContext or scope.context) != "static"
        ) "filter decisions are not allowed in static-route attribute bodies"
    else if kind == "when" || kind == "ifElse" then
      shape path [ "condition" "body" ] (lib.optional (kind == "ifElse") "elseBody") node
      ++ error path (kind != "ifElse" || node ? elseBody) "ifElse requires an elseBody"
      ++ condition.errors
      ++ expectType "${path}.condition" "bool" condition
      ++ statements "${path}.body" scope (node.body or null)
      ++ lib.optionals (kind == "ifElse") (statements "${path}.elseBody" scope (node.elseBody or null))
    else if kind == "set" then
      let
        attribute = node.attribute or null;
        name =
          if isString attribute then
            attribute
          else if isAttrs attribute then
            attribute.name or null
          else
            null;
      in
      shape path [ "attribute" "value" ] [ ] node
      ++ (
        if isString attribute then
          identifier "${path}.attribute" attribute
        else if isAttrs attribute && (attribute.kind or null) == "attribute" then
          (expression "${path}.attribute" scope attribute).errors
        else
          [ "${path}.attribute: expected an attribute node or native attribute name" ]
      )
      ++ error "${path}.attribute"
        (
          !(builtins.elem name [
            "net"
            "proto"
            "source"
            "ifname"
            "ifindex"
          ])
        ) "route attribute is read-only"
      ++ value.errors
      ++ expectType "${path}.value" (attributeType attribute) value
    else if kind == "return" then
      shape path [ "value" ] [ ] node
      ++ error path (scope.context == "function") "return is only allowed in a function"
      ++ error path
        (
          (node.value or null) != null
        ) "BIRD 3.4 does not support bare return, void functions must fall through"
      ++ error path
        (
          (node.value or null) == null || scope.returnType != null
        ) "a void function cannot return a value"
      ++ lib.optionals ((node.value or null) != null) (
        value.errors ++ expectType "${path}.value" scope.returnType value
      )
    else if kind == "call" then
      call path scope true node
    else if kind == "addCommunities" || kind == "deleteCommunities" then
      shape path [ "values" ] [ ] node
      ++ error "${path}.values" (isList (node.values or null)) "expected an ordered list of communities"
      ++ lib.optionals (isList (node.values or null)) (
        concatMap (item: item) (
          imap0
            (
              i: community:
              let
                p = "${path}.values[${toString i}]";
                result = expression p scope community;
              in
              result.errors
              ++ error p
                (
                  isAttrs community && (community.kind or null) == "community"
                  || (
                    isAttrs community
                    && (community.kind or null) == "reference"
                    && (community.target or null) == "define"
                  )
                ) "expected an individual community or a define reference"
              ++ error p
                (builtins.elem result.type [
                  "pair"
                  "ec"
                  "lc"
                ]) "expected an individual standard, extended or large community"
            )
            node.values
        )
      )
    else if kind == "rawStatement" then
      shape path [ "text" ] [ "dependsOn" ] node
      ++ native "${path}.text" (node.text or null)
      ++ dependencies "${path}.dependsOn" (node.dependsOn or [ ])
    else
      [ "${path}: unknown statement kind" ];
  filter =
    path: family: declaration:
    error "${path}.default"
      (builtins.elem (declaration.default or null) [
        "accept"
        "reject"
      ]) "a filter requires an explicit accept/reject default"
    ++ statements "${path}.body" ((scopeFor "filter") // { inherit family; }) (declaration.body or [ ]);
  policy =
    path: family: value:
    if isString value then
      error path
        (builtins.elem value [
          "all"
          "none"
        ]) "policy strings must be all or none, use a filter reference for a named policy"
    else if
      isAttrs value
      && builtins.elem (value.kind or null) [
        "reference"
        "external"
      ]
    then
      reference path [ "filter" ] value
      ++ (
        let
          declaration = lookup value;
        in
        lib.optionals ((value.target or null) == "filter" && declaration != null) (
          filter "${path}.filter.${value.name}" family declaration
        )
      )
    else if isAttrs value && attrNames value == [ "inline" ] then
      shape "${path}.inline" [ "default" "body" ] [ ] value.inline
      ++ (if isAttrs value.inline then filter "${path}.inline" family value.inline else [ ])
    else if isAttrs value && attrNames value == [ "where" ] then
      let
        result = expression "${path}.where" ((scopeFor "filter") // { inherit family; }) value.where;
      in
      result.errors ++ expectType "${path}.where" "bool" result
    else
      [ "${path}: expected exactly one policy form: all, none, filter reference, inline or where" ];
  channel =
    path: protocolType: family: declaration:
    let
      table = declaration.table or null;
      target = lookup table;
      nextHop = declaration.nextHopAddress or null;
      nextHopInfo = ipInfo nextHop;
      bgpFields = [
        "nextHopSelf"
        "nextHopKeep"
        "nextHopAddress"
        "gateway"
        "extendedNextHop"
        "importTable"
        "exportTable"
      ];
      mode =
        name:
        builtins.elem (declaration.${name} or null) [
          null
          true
          false
          "ibgp"
          "ebgp"
        ];
    in
    error path
      (builtins.elem family [
        "ipv4"
        "ipv6"
      ]) "unsupported channel address family"
    ++ lib.optionals (table != null) (
      reference "${path}.table" [ "table" ] table
      ++ error "${path}.table"
        (
          target == null || (target.type or null) == family
        ) "routing-table type does not match the channel address family"
    )
    ++
    concatMap
      (
        direction:
        let
          selected = declaration.${direction} or null;
        in
        error "${path}.${direction}"
          (
            protocolType != "bgp" || selected != null
          ) "BGP channels require an explicit ${direction} policy"
        ++ lib.optionals (selected != null) (policy "${path}.${direction}" family selected)
      )
      [
        "import"
        "export"
      ]
    ++ error "${path}.addPaths"
      (builtins.elem (declaration.addPaths or "off") [
        "off"
        "on"
        "rx"
        "tx"
      ]) "invalid add-paths mode"
    ++ error "${path}.nextHopSelf" (mode "nextHopSelf") "expected a switch, ibgp or ebgp"
    ++ error "${path}.nextHopKeep" (mode "nextHopKeep") "expected a switch, ibgp or ebgp"
    ++ error "${path}.gateway"
      (builtins.elem (declaration.gateway or null) [
        null
        "direct"
        "recursive"
      ]) "gateway mode must be direct or recursive"
    ++
    concatMap
      (
        field:
        error "${path}.${field}"
          (builtins.elem (declaration.${field} or null) [
            null
            true
            false
          ]) "expected a boolean"
      )
      [
        "extendedNextHop"
        "importTable"
        "exportTable"
      ]
    ++ lib.optionals (nextHop != null) (
      ip "${path}.nextHopAddress" nextHop
      ++ error "${path}.nextHopAddress"
        (
          nextHopInfo.scope == null
        ) "next-hop address cannot contain an interface scope"
      ++ error "${path}.nextHopAddress"
        (
          !nextHopInfo.valid || nextHopInfo.family == family || (declaration.extendedNextHop or null) == true
        ) "a cross-family next hop requires extendedNextHop = true"
    )
    ++ lib.optionals (protocolType != "bgp") (
      concatMap
        (
          field:
          error "${path}.${field}"
            (
              (declaration.${field} or null) == null
            ) "this channel option is only supported by BGP"
        )
        bgpFields
      ++ error "${path}.addPaths"
        (
          (declaration.addPaths or "off") == "off"
        ) "add paths is only supported by BGP"
    )
    ++ native "${path}.extraConfig" (declaration.extraConfig or "");
  ctx = {
    inherit
      config
      error
      reference
      expression
      statements
      channel
      uint
      ip
      prefix
      string
      native
      ipInfo
      prefixInfo
      typeOf
      identifier
      scopeFor
      expectType
      ;
  };
  terminates =
    nodes:
    isList nodes
    && builtins.any
      (
        node:
        isAttrs node
        && (
          builtins.elem (node.kind or null) [
            "return"
            "accept"
            "reject"
            "rawStatement"
          ]
          || (
            (node.kind or null) == "ifElse"
            && terminates (node.body or [ ])
            && terminates (node.elseBody or [ ])
          )
        )
      )
      nodes;
  declarationErrors =
    declaration:
    let
      inherit (declaration) target name definition;
      path = "${internal.collections.${target}}.${name}";
      ref = definition.ref or null;
      common =
        identifier path name
        ++ dependencies "${path}.dependsOn" (definition.dependsOn or [ ])
        ++ lib.optionals (ref != null) (
          reference "${path}.ref" [ target ] ref
          ++ error "${path}.ref"
            (
              isAttrs ref && (ref.name or null) == name && (ref.target or null) == target
            ) "declaration reference has the wrong identity"
        );
    in
    common
    ++ (
      if target == "define" then
        let
          result = expression "${path}.value" (scopeFor "define") (definition.value or null);
        in
        result.errors
        ++
        error "${path}.value" result.constant
          "define values must be constant, not route attributes, locals or function calls"
      else if target == "table" then
        error "${path}.type"
          (builtins.elem (definition.type or null) [
            "ipv4"
            "ipv6"
            "roa4"
            "roa6"
          ]) "unsupported routing-table type"
      else if target == "function" then
        let
          params = if isList (definition.params or null) then definition.params else [ ];
          locals = builtins.listToAttrs (
            map
              (parameter: {
                name = if isAttrs parameter && isString (parameter.name or null) then parameter.name else "";
                value = if isAttrs parameter then parameter.type or null else null;
              })
              params
          );
          scope = (scopeFor "function") // {
            inherit locals;
            returnType = definition.returnType or null;
          };
        in
        signature path definition
        ++ statements "${path}.body" scope (definition.body or [ ])
        ++ error "${path}.body"
          (
            scope.returnType == null || terminates (definition.body or [ ])
          ) "a value-returning function needs a return or terminating branch on every structured path"
      else if target == "filter" then
        filter path null definition
      else if target == "protocol" || target == "template" then
        let
          protocolType = definition.type or null;
          registered = isString protocolType && builtins.hasAttr protocolType protocols;
          from = definition.from or null;
          parent = lookup from;
        in
        error "${path}.type" registered "unknown protocol type"
        ++ error "${path}.disabled" (isBool (definition.disabled or false)) "expected a boolean"
        ++ lib.optionals ((definition.description or null) != null) (
          string "${path}.description" definition.description
        )
        ++ native "${path}.extraConfig" (definition.extraConfig or "")
        ++ lib.optionals (from != null) (
          reference "${path}.from" [ "template" ] from
          ++ error "${path}.from" ((from.kind or null) == "reference") "templates must be declared, not external"
          ++ error "${path}.from"
            (
              parent == null || (parent.type or null) == protocolType
            ) "a ${target} can only derive from a template of the same protocol type"
        )
        # a template is checked through the protocols derived from it, since it may be incomplete on its own
        ++ lib.optionals (registered && target == "protocol") (
          (
            protocols.${protocolType}.validate or (
              _: _: _:
              [ ]
            )
          )
            ctx
            name
            definition
        )
      else
        [ ]
    );
  names = map (declaration: declaration.name) internal.declarations;
  duplicates = builtins.filter (name: length (builtins.filter (other: other == name) names) > 1) (
    lib.unique names
  );
  rootID = ipInfo (config.id or null);
in
error "id"
  (
    rootID.valid && rootID.family == "ipv4" && rootID.scope == null
  ) "router ID must be an IPv4 address"
++ error "includes" (isList (config.includes or [ ])) "expected a list of runtime include paths"
++ lib.optionals (isList (config.includes or [ ])) (
  concatMap (item: item) (
    imap0
      (
        i: path:
          string "includes[${toString i}]" path
          ++ error "includes[${toString i}]" (path != "") "include paths must not be empty"
      )
      (config.includes or [ ])
  )
)
++ map
  (
    name:
    "declarations.${name}: BIRD declarations share one namespace, but this name is declared more than once"
  )
  duplicates
++ concatMap declarationErrors internal.declarations
++ lib.optional (internal.ordering.unresolved != [ ]) (
  "declarations: unsupported declaration dependency cycle prevents ordering: "
  + concatStringsSep ", " (map (declaration: declaration.key) internal.ordering.unresolved)
  + "; direct self-recursive function calls are permitted, mutual cycles are not"
)
