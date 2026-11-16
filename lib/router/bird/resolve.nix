# Explicit source-derived data only: no daemon defaults, include reads or native-code evaluation.
{ lib, inventory, formInfo, orderedNames, renderValue, partRule, headerData, matchForm }:
let
  inherit (lib)
    all any attrNames concatStringsSep elem filter hasAttr head
    isAttrs isList isString length removeAttrs tail;
  schema = inventory.schema;
  registry = inventory.registry;
  fail = message: throw "router BIRD resolve: ${message}";
  node = value: isAttrs value && value ? _rule;
  tagged = value: isAttrs value && value ? _bird;
  ordinary = value: isAttrs value && !node value && !tagged value;
  prefixOf = prefix: path: lib.take (length prefix) path == prefix;
  get = path: value: lib.attrByPath path null value;
  present = path: value: lib.hasAttrByPath path value;
  put = path: value: base:
    if path == [ ] then value
    else
      let name = head path; previous = if ordinary base then base else { };
      in previous // { ${name} = put (tail path) value (previous.${name} or { }); };
  remove = path: base:
    if path == [ ] then { }
    else if !ordinary base || !hasAttr (head path) base then base
    else if length path == 1 then removeAttrs base path
    else
      let name = head path; child = remove (tail path) base.${name};
      in if child == { } then removeAttrs base [ name ] else base // { ${name} = child; };
  infos = scope: map formInfo schema.scopes.${scope};
  tailParts = info: if info.named then tail info.rest else info.rest;
  partsOf = kind: info: filter (part: part.kind == kind) (tailParts info);
  withModifiers = header: value:
    if header == null then value
    else
      lib.foldl'
        (current: modifier: if modifier.present then put [ modifier.field ] modifier.value current else current)
        value
        header.modifiers;
  protocolForms = filter
    (info: info.header != null && length info.path == 2
      && elem (head info.path) [ "protocol" "template" ]
      && partsOf "block" info != [ ])
    (infos schema.root);
  namespaces = lib.unique (map (info: head info.path) protocolForms);
  protocolScope = info: (head (partsOf "block" info)).scope;
  effects = scope: written: base:
    lib.foldl'
      (value: effect:
        let
          resets = effect.clears or null;
          target = effect.target or null;
          cleared = lib.foldl' (current: path: remove path current) value (if resets == null then [ ] else resets);
          aliased =
            if target != null then
              put target (get effect.path written) (remove effect.path cleared)
            else cleared;
        in
        aliased)
      base
      (filter (effect: effect.scope == scope && present effect.path written) registry.effects);
  chooseRule = rule: value:
    let
      shape = schema.value_types.${rule};
      alternatives =
        if shape.kind == "choice" then
          filter (candidate: (renderValue candidate value).ok) shape.alternatives else [ ];
    in
    if shape.kind == "choice" && alternatives != [ ] then chooseRule (head alternatives) value else rule;
  overlayValue = rule: base: value:
    let
      selected = chooseRule rule value;
      shape = schema.value_types.${selected};
      forms =
        if shape.kind == "record" && ordinary value then
          filter
            (form:
              let
                fields = filter (part: elem part.kind [ "field" "body" ]) form.parts;
                names = map (part: part.name) fields;
                spreads = filter (part: part.kind == "spread") form.parts;
              in
              all (part: (part.optional or false) || hasAttr part.name value) fields
              && (removeAttrs value names == { } || spreads != [ ]))
            shape.forms else [ ];
      form = if forms == [ ] then null else head forms;
      fields = if form == null then [ ] else filter (part: elem part.kind [ "field" "body" ]) form.parts;
      spreads = if form == null then [ ] else filter (part: part.kind == "spread") form.parts;
      merged = lib.foldl'
        (current: part:
          if !hasAttr part.name value then current
          else put [ part.name ] (overlayValue part.rule (get [ part.name ] current) value.${part.name}) current)
        (if ordinary base then base else { })
        fields;
      remaining = removeAttrs value (map (part: part.name) fields);
    in
    if node value || tagged value then value
    else if shape.kind == "list" && (shape.merge or "replace") == "append" && isList value then
      (if isList base then base else [ ]) ++ value
    else if shape.kind == "record" && shape.merge == "fields" && form != null then
      lib.foldl' (current: part: overlayScope part.scope current remaining) merged spreads
    else value;
  matchingForms = scope: path: filter
    (info: prefixOf info.path path
      && (if info.named then length path == length info.path + 1 else path == info.path))
    (infos scope);
  overlayEntry = scope: path: base: value:
    let
      matching = matchingForms scope path;
      results = map (info: { inherit info; result = matchForm info path value; }) matching;
      accepted = filter (candidate: candidate.result.ok) results;
      best = lib.foldl' (score: candidate: lib.max score (candidate.result.score or 0)) 0 accepted;
      preferred = filter (candidate: (candidate.result.score or 0) == best) accepted;
      info = if preferred != [ ] then (head preferred).info else if matching != [ ] then head matching else null;
      groups = any
        (candidate: prefixOf path candidate.path
          && (length path < length candidate.path || (candidate.named && path == candidate.path)))
        (infos scope);
      blocks = if info == null then [ ] else partsOf "block" info ++ partsOf "options" info;
      values = if info == null then [ ] else partsOf "value" info;
      old = get path base;
      header = if info == null || info.header == null then null else headerData info.header value;
      payload = if header == null then value else header.value;
      rule = if length values == 1 then partRule (head values) else null;
      complete = rule != null && (renderValue rule payload).ok;
      repeated = isList value && length blocks != 1 && !complete;
      updated =
        if info == null && groups then
          if isList value then lib.foldl' (overlayEntry scope path) base value
          else lib.foldl' (current: name: overlayEntry scope (path ++ [ name ]) current value.${name}) base (orderedNames value)
        else if length blocks == 1 then
          put path (withModifiers header (overlayScope (head blocks).scope (if ordinary old then old else { }) payload)) base
        else if rule != null && complete then put path (withModifiers header (overlayValue rule old payload)) base
        else if isList value then lib.foldl' (overlayEntry scope path) base value
        else put path (withModifiers header payload) base;
      written = put path value { };
    in
    if (info == null && groups) || repeated then updated
    else effects scope written updated;
  overlayScope = scope: base: value:
    if isList value then lib.foldl' (overlayScope scope) base value
    else if node value then fail "cannot interpret an exact structural grammar node as explicit inherited data"
    else lib.foldl' (current: name: overlayEntry scope [ name ] current value.${name}) base (orderedNames value);
  collectNamespace = namespace: values: state:
    lib.foldl'
      (current: kind:
        let
          matches = filter (info: info.path == [ namespace kind ]) protocolForms;
          info = if matches == [ ] then fail "unknown declaration kind ${namespace}.${kind}" else head matches;
        in
        lib.foldl'
          (next: name: next // {
            entries = next.entries ++ [{
              inherit namespace kind name info;
              value = values.${kind}.${name};
              key = "${namespace}.${kind}.${name}";
            }];
          })
          current
          (orderedNames values.${kind}))
      state
      (orderedNames values);
  collect = state: settings:
    if isList settings then lib.foldl' collect state settings
    else if node settings then fail "exact configuration nodes have no structured explicit-data view"
    else
      lib.foldl'
        (current: name:
          if elem name namespaces then collectNamespace name settings.${name} current
          else if name == "include" then
            let
              values = if isList settings.${name} then settings.${name} else [ settings.${name} ];
              previous = current.value.include or [ ];
            in
            current // { value = current.value // { include = previous ++ values; }; }
          else current // { value = overlayEntry schema.root [ name ] current.value settings.${name}; })
        state
        (orderedNames settings);
  fromData = entry:
    let
      data = headerData entry.info.header entry.value;
      source = data.source;
      name =
        if source == null || isString source then source
        else if tagged source && source._bird == "symbol" then source.value
        else fail "${entry.key}.${entry.info.header.field} must name a structured template or protocol";
    in
    { inherit name; inherit (data) value modifiers; };
  resolveEntry = entries: stack: entry:
    let
      from = fromData entry;
      parents = if from.name == null then [ ] else
      filter (candidate: candidate.kind == entry.kind && candidate.name == from.name) entries;
      parent =
        if from.name == null then { }
        else if parents == [ ] then fail "${entry.key}.from names unavailable structured parent ${from.name} of kind ${entry.kind}"
        else if length parents != 1 then fail "${entry.key}.from has ambiguous parent ${from.name}"
        else resolveEntry entries (stack ++ [ entry.key ]) (head parents);
      inherited = if from.name == null then parent else
      lib.foldl'
        (value: path: remove path value)
        parent
        registry.protocols.${entry.kind}.reset_paths;
    in
    if elem entry.key stack then fail "cyclic from declarations: ${concatStringsSep " -> " (stack ++ [ entry.key ])}"
    else withModifiers from (overlayScope (protocolScope entry.info) inherited from.value);
in
settings:
let
  collected = collect { value = { }; entries = [ ]; } settings;
in
lib.foldl'
  (value: entry: put [ entry.namespace entry.kind entry.name ]
    (resolveEntry collected.entries [ ] entry)
    value)
  collected.value
  collected.entries
