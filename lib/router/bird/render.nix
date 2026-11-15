{ lib, protocols }:
config:
let
  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    mapAttrsToList
    optionalString
    ;
  internal = import ./internal.nix { inherit lib; } config;
  quote = text: "\"${text}\"";
  identifier = name: if internal.matches "[A-Za-z_][A-Za-z0-9_]*" name then name else "'${name}'";
  switch = enabled: if enabled then "on" else "off";
  indent =
    text:
    concatStringsSep "\n" (
      map (line: if line == "" then "" else "  ${line}") (lib.splitString "\n" text)
    );
  join = parts: concatStringsSep "\n" (lib.filter (part: part != "") parts);
  block = header: contents: if contents == "" then "${header} {\n}" else "${header} {\n${indent contents}\n}";
  address =
    text:
    let
      info = internal.ipInfo text;
    in
    info.address + optionalString (info.scope != null) "%${identifier info.scope}";
  prefixPattern =
    entry:
    if lib.isString entry then
      entry
    else
      let
        details = internal.prefixInfo entry.prefix;
        ranged = (entry.ge or null) != null || (entry.le or null) != null;
        low = if (entry.ge or null) != null then entry.ge else details.prefixLength;
        high = if (entry.le or null) != null then entry.le else details.maxLength;
      in
      entry.prefix + optionalString ranged "{${toString low},${toString high}}";
  expression =
    node:
    if lib.isBool node then
      (if node then "true" else "false")
    else if lib.isInt node then
      toString node
    else if lib.isString node then
      quote node
    else
      let
        kind = node.kind;
      in
      if kind == "ip" || kind == "prefix" then
        node.value
      else if kind == "prefixSet" then
        "[ ${concatMapStringsSep ", " prefixPattern node.prefixes} ]"
      else if kind == "community" then
        if node.type == "standard" then
          "(${toString node.asn}, ${toString node.value})"
        else if node.type == "large" then
          "(${toString node.asn}, ${toString node.data1}, ${toString node.data2})"
        else
          "(${node.communityType}, ${toString node.key}, ${toString node.value})"
      else if kind == "reference" || kind == "external" || kind == "attribute" || kind == "local" then
        identifier node.name
      else if kind == "rawExpression" then
        "(${node.text})"
      else if kind == "call" then
        "${identifier node.function.name}(${concatMapStringsSep ", " expression node.arguments})"
      else if kind == "all" || kind == "any" then
        if node.values == [ ] then
          (if kind == "all" then "true" else "false")
        else
          "(${concatMapStringsSep (if kind == "all" then " && " else " || ") expression node.values})"
      else if kind == "not" then
        "(!${expression node.value})"
      else if kind == "compare" then
        "(${expression node.left} ${node.op} ${expression node.right})"
      else if kind == "inSet" then
        "(${expression node.value} ~ ${expression node.set})"
      else if kind == "fromProtocol" then
        "(proto = ${quote node.protocol.name})"
      else if kind == "pathProperty" then
        "bgp_path.${node.property}"
      else
        throw "unknown BIRD expression kind '${kind}'";
  value = expression;
  body = nodes: join (map statement nodes);
  statement =
    node:
    let
      kind = node.kind;
    in
    if kind == "accept" || kind == "reject" then
      "${kind};"
    else if kind == "when" then
      block "if ${expression node.condition} then" (body node.body)
    else if kind == "ifElse" then
      "${block "if ${expression node.condition} then" (body node.body)} else {\n${indent (body node.elseBody)}\n}"
    else if kind == "set" then
      "${
        identifier (if lib.isString node.attribute then node.attribute else node.attribute.name)
      } = ${expression node.value};"
    else if kind == "return" then
      if node.value == null then
        throw "BIRD 3.4 does not support bare return, void functions must fall through"
      else
        "return ${expression node.value};"
    else if kind == "call" then
      "${expression node};"
    else if kind == "addCommunities" || kind == "deleteCommunities" then
      concatMapStringsSep "\n"
        (
          community:
          let
            attribute =
              {
                pair = "bgp_community";
                ec = "bgp_ext_community";
                lc = "bgp_large_community";
              }.${internal.typeOf community};
          in
          "${attribute}.${if kind == "addCommunities" then "add" else "delete"}(${expression community});"
        )
        node.values
    else if kind == "prependPath" || kind == "deletePath" then
      concatMapStringsSep "\n"
        (value: "bgp_path.${if kind == "prependPath" then "prepend" else "delete"}(${expression value});")
        node.values
    else if kind == "filterPath" then
      "bgp_path.filter(${expression node.set});"
    else if kind == "print" then
      "${if node.newline then "print" else "printn"} ${concatMapStringsSep ", " expression node.values};"
    else if kind == "rawStatement" then
      node.text
    else
      throw "unknown BIRD statement kind '${kind}'";
  filterBody =
    declaration:
    join [
      (body declaration.body)
      "${declaration.default};"
    ];
  policy =
    selected:
    if lib.isString selected then
      selected
    else if
      lib.elem (selected.kind or null) [
        "reference"
        "external"
      ]
    then
      "filter ${identifier selected.name}"
    else if selected ? inline then
      block "filter" (filterBody selected.inline)
    else
      "where ${expression selected.where}";
  # every field renders exactly when it is set, so a derived block overrides only what it names
  # a pipe writes these items inline, other protocols wrap them in a family block
  channelContents =
    declaration:
    let
      option =
        key: label:
        let
          selected = declaration.${key} or null;
        in
        optionalString (selected != null)
          "${label} ${if lib.isBool selected then switch selected else toString selected};";
    in
    join (
      [
        (optionalString ((declaration.table or null) != null) "table ${identifier declaration.table.name};")
      ]
      ++
      map
        (
          direction:
          optionalString ((declaration.${direction} or null) != null)
            "${direction} ${policy declaration.${direction}};"
        )
        [
          "import"
          "export"
        ]
      ++
      map
        (
          limit:
          let
            selected = declaration.${limit.field} or null;
          in
          optionalString (selected != null) "${limit.label} ${
              if lib.isString selected then
                selected
              else
                "${toString selected.count}${optionalString (selected.action != null) " action ${selected.action}"}"
            };"
        )
        [
          {
            field = "importLimit";
            label = "import limit";
          }
          {
            field = "receiveLimit";
            label = "receive limit";
          }
          {
            field = "exportLimit";
            label = "export limit";
          }
        ]
      ++ [
        (option "importKeepFiltered" "import keep filtered")
        (option "preference" "preference")
        (optionalString ((declaration.addPaths or null) != null) "add paths ${declaration.addPaths};")
        (option "nextHopSelf" "next hop self")
        (option "nextHopKeep" "next hop keep")
        (optionalString
          (
            (declaration.nextHopAddress or null) != null
          ) "next hop address ${address declaration.nextHopAddress};")
        (option "gateway" "gateway")
        (option "extendedNextHop" "extended next hop")
        (option "importTable" "import table")
        (option "exportTable" "export table")
        (declaration.extraConfig or "")
      ]
    );
  channel = family: declaration: "${block family (channelContents declaration)};";
  # the declaration kind decides the keyword, and only a derived declaration names its template
  protocolFor =
    keyword: name: declaration: contents:
    block
      "${keyword} ${declaration.type} ${identifier name}${
        optionalString ((declaration.from or null) != null) " from ${identifier declaration.from.name}"
      }"
      (join [
        (optionalString ((declaration.disabled or null) != null) "disabled ${switch declaration.disabled};")
        (optionalString
          (
            (declaration.description or null) != null
          ) "description ${quote declaration.description};")
        contents
        (declaration.extraConfig or "")
      ]);
  ctxFor = keyword: {
    inherit
      config
      value
      expression
      body
      quote
      identifier
      switch
      indent
      join
      block
      address
      channel
      channelContents
      ;
    inherit (internal) typeOf;
    protocol = protocolFor keyword;
  };
  mask = selected: if lib.isString selected then selected else "{ ${concatStringsSep ", " selected} }";
  log =
    entry:
    let
      destination =
        if entry.target == "file" then
          "${quote entry.path}${optionalString (entry.size != null) " ${toString entry.size} ${quote entry.backup}"}"
        else if entry.target == "fixed" then
          "fixed ${quote entry.path} ${toString entry.size}"
        else if entry.target == "syslog" then
          "syslog${optionalString (entry.name != null) " name ${quote entry.name}"}"
        else if entry.target == "stderr" then
          "stderr"
        else
          "udp ${if (internal.ipInfo entry.address).valid then entry.address else quote entry.address}${
            optionalString (entry.port != null) " port ${toString entry.port}"
          }";
    in
    "log ${destination} ${mask entry.classes};";
  declaration =
    item:
    let
      inherit (item) target name definition;
    in
    if target == "attribute" then
      "attribute ${definition.type} ${identifier name};"
    else if target == "define" then
      "define ${identifier name} = ${value definition.value};"
    else if target == "table" then
      "${definition.type} table ${identifier name};"
    else if target == "function" then
      block "function ${identifier name}(${concatMapStringsSep "; " (parameter: "${parameter.type} ${identifier parameter.name}") definition.params})${optionalString (definition.returnType != null) " -> ${definition.returnType}"}"
        (
          body definition.body
        )
    else if target == "filter" then
      block "filter ${identifier name}" (filterBody definition)
    else
      protocols.${definition.type}.render (ctxFor target) name definition;
in
if internal.ordering.unresolved != [ ] then
  throw "cannot render BIRD declarations with a dependency cycle"
else
  concatStringsSep "\n\n"
    (
      [ "router id ${config.id};" ]
      ++ map (path: "include ${quote path};") (config.includes or [ ])
      # protocols copy the global debug default when they are declared, so globals precede every declaration
      ++ map log (config.log or [ ])
      ++ lib.optional ((config.debugProtocols or null) != null) "debug protocols ${mask config.debugProtocols};"
      ++ lib.optional
        (
          (config.gracefulRestartWait or null) != null
        ) "graceful restart wait ${toString config.gracefulRestartWait};"
      ++ lib.optional ((config.extraConfig or "") != "") config.extraConfig
      ++ map declaration internal.ordering.result
    )
    + "\n"
