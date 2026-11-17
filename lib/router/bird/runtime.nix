# Runtime authored for router (MIT). The inventory in generated/bird records upstream grammar provenance.
{ lib, inventory }:
let
  grammar = inventory.grammar;
  schema = inventory.schema;
  inherit (lib)
    all any attrNames concatMap concatStringsSep elem elemAt filter hasAttr head
    isAttrs isBool isInt isList isPath isString length listToAttrs
    mapAttrsToList removeAttrs sort tail;
  fail = message: throw "router BIRD: ${message}";
  join = parts: concatStringsSep " " (filter (part: part != "") parts);
  tagged = value: isAttrs value && value ? _bird;
  node = value: isAttrs value && value ? _rule;
  ordinary = value: isAttrs value && !tagged value && !node value;
  prefixOf = prefix: list: lib.take (length prefix) list == prefix;
  isNative = name: elem name schema.native_rules;
  good = text: { ok = true; inherit text; error = ""; };
  # A failure keeps its setting path apart from its message, each enclosing entry prepends its own path.
  bad = { ok = false; text = ""; error = ""; at = [ ]; };
  invalid = error: bad // { inherit error; };
  located = path: result: result // { at = path ++ result.at; };
  indexed = path: index: result:
    if result.ok then result
    else result // { at = path ++ [ "[${toString index}]" ] ++ lib.drop (length path) result.at; };
  location = lib.foldl'
    (text: segment: if text == "" || lib.hasPrefix "[" segment then text + segment else "${text}.${segment}")
    "";
  combine = results:
    if all (result: result.ok) results then
      good (concatStringsSep "\n" (map (result: result.text) results))
    else head (filter (result: !result.ok) results);
  alternatives = results:
    let texts = lib.unique (map (result: result.text) (filter (result: result.ok) results));
    in if length texts == 1 then good (head texts)
    else if texts == [ ] then bad
    else invalid "ambiguous value, wrap it in a constructor such as bird.ip, bird.string or bird.symbol";

  string = value:
    if !isString value || lib.hasInfix ''"'' value || lib.hasInfix "\n" value || lib.hasInfix "\r" value then
      fail "BIRD's lexer has no quoted-string escapes, so text cannot contain quotes or newlines"
    else { _bird = "string"; inherit value; };
  symbol = value:
    if !isString value || builtins.match "[A-Za-z0-9_.:-]+" value == null then
      fail "BIRD symbols may contain only letters, digits, underscore, dot, colon and hyphen"
    else { _bird = "symbol"; inherit value; };
  ip = value:
    if !isString value || builtins.match "[0-9A-Fa-f:.]+" value == null then
      fail "ip expects an IPv4 or IPv6 address"
    else { _bird = "ip"; inherit value; };
  prefix = value:
    if !isString value || builtins.match "[0-9A-Fa-f:.]+/[0-9]+" value == null then
      fail "prefix expects an IP prefix with a prefix length"
    else { _bird = "prefix"; inherit value; };
  tuple = value:
    if !isList value || !any (form: form.arity == length value) inventory.registry.constructors.tuple.forms then
      fail "tuple expects a source-supported ordered tuple"
    else { _bird = "tuple"; inherit value; };
  ec = value:
    if !isList value || !any (form: form.arity == length value) inventory.registry.constructors.ec.forms then
      fail "ec expects a source-supported extended-community tuple"
    else { _bird = "ec"; inherit value; };
  expr = value:
    if !isString value || value == "" then fail "expr expects a nonempty native BIRD expression"
    else { _bird = "expr"; inherit value; };
  # BIRD's lexer replaces an include line with the file, so it can stand in for any value
  includeKeyword = inventory.lexer_include.keyword;
  include = value:
    if !(isString value || isPath value) || toString value == "" then fail "include expects a nonempty filename or glob"
    else { _bird = "include"; value = toString value; };
  includeDirective = value: "${includeKeyword} ${quoted (include value).value};";
  includeLine = value: "\n${includeDirective value}\n";
  quoted = value: ''"${(string value).value}"'';
  reference = value:
    if tagged value && attrNames value != [ "_bird" "value" ] then null
    else if tagged value && value._bird == "symbol" then "'${(symbol value.value).value}'"
    else if isString value && builtins.match "[A-Za-z_][A-Za-z0-9_]*" value != null then value
    else if isString value && builtins.match "[A-Za-z0-9_.:-]+" value != null then "'${value}'"
    else null;
  # Values semantic can write, so an expression slot can decline the rest instead of throwing.
  data = value:
    tagged value || isString value || isBool value || isInt value || (isList value && all data value);
  semantic = value:
    if tagged value then
      if attrNames value != [ "_bird" "value" ] then fail "BIRD data constructors contain exactly _bird and value"
      else if value._bird == "string" then quoted value.value
      else if value._bird == "symbol" then "'${(symbol value.value).value}'"
      else if value._bird == "ip" then (ip value.value).value
      else if value._bird == "prefix" then (prefix value.value).value
      else if value._bird == "expr" then (expr value.value).value
      else if value._bird == "include" then includeLine value.value
      else if elem value._bird [ "tuple" "ec" ] then
        let result = renderConstructor value._bird inventory.registry.bindings."constant.constructor".rule value.value;
        in if result.ok then result.text else fail "invalid source-derived ${value._bird} constructor"
      else fail "unknown BIRD data constructor ${toString value._bird}"
    else if isString value then quoted value
    else if isBool value then (if value then "true" else "false")
    else if isInt value then toString value
    else if isList value then "[ ${concatStringsSep ", " (map semantic value)} ]"
    else fail "expected typed BIRD data, write native expressions with bird.expr";
  # the forms of constructor `name` that render grammar rule `rule`
  renderConstructor = name: rule: value:
    let
      constructor = inventory.registry.constructors.${name};
      forms = if isList value then filter (form: form.rule == rule && form.arity == length value) constructor.forms else [ ];
      renderForm = form:
        let
          results = map
            (part:
              if part.kind == "literal" then good part.text
              else renderValue part.rule (elemAt value (lib.toInt part.name)))
            form.parts;
        in
        if all (result: result.ok) results then good (join (map (result: result.text) results)) else bad;
    in
    alternatives (map renderForm forms);

  keywordTokens = listToAttrs (map
    (keyword: { name = keyword.token; value = keyword.spelling; })
    (filter (keyword: hasAttr keyword.token grammar.tokens) inventory.keywords));
  fixedToken = name:
    if hasAttr name keywordTokens then keywordTokens.${name}
    else null;
  epsilon = name:
    hasAttr name grammar.rules
    && length grammar.rules.${name}.productions == 1
    && (head grammar.rules.${name}.productions).symbols == [ ];
  argument = part:
    part.kind == "reference" && fixedToken part.value == null && !epsilon part.value;
  exactReference = name: value:
    if node value then
      if value._rule == name then exact value
      else fail "expected grammar rule ${name}, not ${value._rule}"
    else if isNative name || elem name schema.program_rules then
      if isString value then value else fail "${name} requires native BIRD code"
    else if hasAttr name schema.value_types then
      let result = renderValue name value;
      in if result.ok then result.text else fail "value does not match grammar rule ${name}"
    else fail ''${name} is structural, write it as { _rule = "${name}"; _production = INDEX; _args = [ ... ]; }'';
  exact = value:
    let
      name = value._rule;
      rule = grammar.rules.${name} or (fail "unknown or CLI-only grammar rule ${name}");
      number = value._production or (if length rule.productions == 1 then 0 else fail "${name} has several productions, so it needs _production");
      production = if isInt number && number >= 0 && number < length rule.productions then elemAt rule.productions number else fail "invalid production index for ${name}";
      args = value._args or [ ];
      count = length (filter argument production.symbols);
      rendered = lib.foldl'
        (state: part:
          if part.kind == "literal" then state // { parts = state.parts ++ [ part.value ]; }
          else if argument part then {
            index = state.index + 1;
            parts = state.parts ++ [ (exactReference part.value (elemAt args state.index)) ];
          }
          else state // { parts = state.parts ++ [ (if epsilon part.value then "" else fixedToken part.value) ]; })
        { index = 0; parts = [ ]; }
        production.symbols;
    in
    if any (field: !elem field [ "_rule" "_production" "_args" ]) (attrNames value) then
      fail "exact grammar nodes cannot contain additional named settings"
    else if elem name schema.program_rules then fail "${name} must be native BIRD code, not instruction nodes"
    else if !isList args || length args != count then
      fail "${name} production ${toString number} (${production.source.file}:${toString production.source.line}) expects ${toString count} positional arguments"
    else join rendered.parts;

  roleField = role: role.field or role.role;
  nativeText = role: value:
    if isString value then value else fail "native ${role} must be a BIRD multiline string";
  renderParameter = role: value:
    if !ordinary value || attrNames value != [ "name" "type" ] then
      fail "native args must contain exactly name and type"
    else
      join (map
        (part:
          if part.kind == "literal" then part.text
          else if part.kind == "name" then
            let name = reference value.name;
            in if name == null then fail "native argument names must be BIRD symbols" else name
          else
            let rendered = renderValue part.rule value.type;
            in if rendered.ok then rendered.text else fail "invalid native argument type")
        role.parts);
  renderDeclaration = declaration: input:
    let
      bodyRoles = filter (role: role.role == "body") declaration.roles;
      value =
        if (declaration.kind or "") == "body" && isString input && length bodyRoles == 1 then
          { ${roleField (head bodyRoles)} = input; }
        else input;
      allowed = map roleField declaration.roles;
      unknown = if ordinary value then filter (name: !elem name allowed) (attrNames value) else [ ];
      renderRole = role:
        let fieldName = roleField role;
        in if !hasAttr fieldName value then
          if role.role == "args" then
            if role.empty == null then fail "native declaration requires ${fieldName}" else join role.empty
          else ""
        else
          let field = value.${fieldName};
          in if role.role == "args" then
            if !isList field then fail "native declaration ${fieldName} must be an ordered list"
            else if field == [ ] then
              if role.empty == null then fail "this declaration requires arguments" else join role.empty
            else
              join (role.prefix ++ [
                (concatStringsSep "${join role.separator} " (map (renderParameter role) field))
              ] ++ role.suffix)
          else if role.role == "return" then
            let result = renderValue role.value_rule field;
            in if result.ok then join (role.prefix ++ [ result.text ] ++ role.suffix)
            else fail "invalid native declaration ${fieldName}"
          else if role.role == "variables" then "${nativeText fieldName field}\n"
          else join (role.prefix ++ [ "\n${nativeText fieldName field}\n" ] ++ role.suffix);
    in
    if !ordinary value then bad
    else if unknown != [ ] then invalid "unknown native fields: ${concatStringsSep ", " unknown}"
    else if any (role: !hasAttr (roleField role) value) bodyRoles then invalid "native declarations require a body field"
    else good (join (map renderRole declaration.roles));

  matchesFamily = shape: address:
    let family = shape.family or null;
    in if family == null then true
    else if family == "ipv4" then builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" address != null
    else if family == "ipv6" then lib.hasInfix ":" address
    else fail "unsupported generated address family ${family}";
  renderPrimitive = shape: value:
    let
      representation = shape.representation;
      tag = if tagged value then value._bird else null;
      raw = if tagged value then value.value or null else value;
      text = predicate: constructor:
        if (tag == null || tag == constructor) && isString raw && predicate raw then good raw else bad;
      ref = reference value;
      expressionRule = shape.expression_rule or null;
      durationOperand = operand:
        if isInt operand then good (toString operand)
        else if expressionRule != null && tagged operand && elem operand._bird [ "symbol" "expr" ] then
          renderValue expressionRule operand
        else bad;
    in
    if tagged value && attrNames value != [ "_bird" "value" ] then bad
    else if representation != "expression" && expressionRule != null && elem tag [ "symbol" "expr" ]
      && (representation != "duration" || shape.bare) then
      renderValue expressionRule value
    else if representation == "expression" then
      if !data value then bad
      # every reader of a parenthesized config expression asserts a scalar type, never a set
      else if isList value && (shape.expression_prefix or [ ]) != [ ] then bad
      else if tag == "symbol" then good (semantic value)
      else good (join ((shape.expression_prefix or [ ]) ++ [ (semantic value) ] ++ (shape.expression_suffix or [ ])))
    else if representation == "number-expression" then
      if isInt value then good (toString value) else bad
    else if representation == "duration" then
      if isInt value && shape.bare then good (toString value)
      else if ordinary value && attrNames value == [ "unit" "value" ]
        && isString value.unit && hasAttr value.unit (shape.units or { }) then
        let operand = durationOperand value.value;
        in if operand.ok then good (join ([ operand.text ] ++ shape.units.${value.unit})) else bad
      else bad
    else if representation == "integer" then if isInt value then good (toString value) else bad
    else if representation == "switch" then
      if isBool value then good (join shape.values.${if value then "true" else "false"}) else bad
    else if representation == "string" then
      if isString value then good (quoted value)
      else if tag == "string" then good (quoted raw) else bad
    else if representation == "symbol" then if ref != null then good ref else bad
    else if representation == "ip-address" then
      text (s: builtins.match "[0-9A-Fa-f:.]+" s != null && matchesFamily shape s) "ip"
    else if representation == "prefix" then
      text
        (s:
          let matched = builtins.match "([0-9A-Fa-f:.]+)/[0-9]+" s;
          in matched != null && matchesFamily shape (head matched))
        "prefix"
    else if representation == "type-name" then renderType shape value
    else fail "unsupported generated primitive representation ${representation}";
  renderType = shape: value:
    if !isString value then bad
    else
      let
        values = shape.values or { };
        tokens = map (name: join values.${name}) (attrNames values);
        suffixes = filter (suffix: suffix != [ ]) (shape.suffixes or [ ]);
        recursive = map
          (suffix:
            let
              text = join suffix;
              ending = " ${text}";
              result = renderType shape (lib.removeSuffix ending value);
            in
            if lib.hasSuffix ending value && result.ok then good (join [ result.text text ]) else bad)
          suffixes;
      in
      if hasAttr value values then good (join values.${value})
      else if elem value tokens then good value
      else alternatives recursive;
  entryNames = lib.mapAttrs (_: forms: map (form: head form.path) (filter (form: form.path != [ ]) forms)) schema.scopes;
  # options outside braces continue their statement on its line
  renderOptions = scope: value:
    let results = map (name: renderEntry scope [ name ] value.${name}) (orderedNames value);
    in if all (result: result.ok) results then good (join (map (result: result.text) results))
    else head (filter (result: !result.ok) results);
  renderRecord = shape: value:
    if !ordinary value then bad
    else
      let
        attempts = map
          (form:
            let
              fields = filter (part: elem part.kind [ "field" "body" ]) form.parts;
              names = map (part: part.name) fields;
              spreads = filter (part: part.kind == "spread") form.parts;
              remaining = removeAttrs value names;
              # a setting no spread knows goes to the first, whose error then names it
              owner = name: (lib.findFirst (part: elem name entryNames.${part.scope}) (head spreads) spreads).scope;
              share = scope: lib.filterAttrs (name: _: owner name == scope) remaining;
              required = all (part: (part.optional or false) || hasAttr part.name value) fields;
              braced = index: index > 0 && elemAt form.parts (index - 1) == { kind = "literal"; text = "{"; };
              results = lib.imap0
                (index: part:
                  if part.kind == "literal" then good part.text
                  else if part.kind == "spread" then
                    if braced index then renderScope part.scope (share part.scope) else renderOptions part.scope (share part.scope)
                  else if !hasAttr part.name value then good ""
                  else located [ part.name ] (renderValue part.rule value.${part.name}))
                form.parts;
              reasons = filter (result: !result.ok && result.error != "") results;
            in
            if !required || (remaining != { } && spreads == [ ]) then bad
            else if all (result: result.ok) results then good (join (map (result: result.text) results))
            else if reasons != [ ] then head reasons
            else bad)
          shape.forms;
        result = alternatives attempts;
        reasons = filter (attempt: !attempt.ok && attempt.error != "") attempts;
      in
      # a form that holds every given field explains the failure better than a generic mismatch
      if result.ok || result.error != "" || reasons == [ ] then result else head reasons;
  hasSymbolAlternative = name:
    let shape = schema.value_types.${name};
    in if shape.kind == "choice" then any hasSymbolAlternative shape.alternatives
    else shape.kind == "primitive" && shape.representation == "symbol";
  renderValue = renderTypedValue true;
  renderTypedValue = allowBodyString: name: value:
    let shape = schema.value_types.${name} or (fail "generated value type ${name} is missing");
    in if value == null then if shape.nullable or false then good "" else bad
    else if tagged value && value._bird == "include" then good (includeLine value.value)
    else if node value then
      if value._rule == (shape.rule or name) || value._rule == name then good (exact value) else bad
    else if shape.kind == "primitive" then renderPrimitive shape value
    else if shape.kind == "enum" then
      let label = if isBool value then (if value then "true" else "false") else value;
      in if isString label && hasAttr label shape.values then good (join shape.values.${label}) else bad
    else if shape.kind == "record" then renderRecord shape value
    else if shape.kind == "list" then
      if !isList value || (value == [ ] && !(shape.nullable or false)) then bad
      else
        let
          results = map (renderValue shape.item_rule) value;
          failed = lib.findFirst (entry: !entry.result.ok) null
            (lib.imap0 (index: result: { inherit index result; }) results);
          reason =
            if failed.result.error != "" then failed.result
            else invalid "invalid value, expected ${describeValue 0 shape.item_rule}";
        in
        if failed == null then
          good
            (join (shape.prefix ++ [
              (concatStringsSep "${join shape.separator} " (map (result: result.text) results))
            ] ++ shape.suffix))
        else reason // { at = [ "[${toString failed.index}]" ] ++ reason.at; }
    else if shape.kind == "choice" then
      let
        allowString = allowBodyString && !(isString value && any hasSymbolAlternative shape.alternatives);
        results = map (rule: { inherit rule; result = renderTypedValue allowString rule value; }) shape.alternatives;
        direct = filter
          (candidate:
            let alternative = schema.value_types.${candidate.rule};
            in candidate.result.ok && !(alternative.kind == "primitive" && alternative.representation == "expression"))
          results;
        # BIRD reserves keywords, so a plain string that spells one is the keyword and bird.string forces text
        keywords = filter (candidate: candidate.result.ok && schema.value_types.${candidate.rule}.kind == "enum") results;
        # Prefer dedicated literal syntax over the same value wrapped in a general expression.
        preferred = if isString value && keywords != [ ] then keywords else if direct != [ ] then direct else results;
      in
      alternatives (map (candidate: candidate.result) preferred)
    else if shape.kind == "body" then
      if isString value && !allowBodyString then bad else renderDeclaration shape value
    else if shape.kind == "constructor" then
      if tagged value && value._bird == shape.id then renderConstructor shape.id name value.value else bad
    else if shape.kind == "exact" then bad
    else fail "unsupported generated value kind ${shape.kind}";
  partRule = part: if (part.value_type or null) != null then part.value_type else part.rule;
  renderPartValue = part: value:
    if node value && value._rule == part.rule then good (exact value)
    else renderValue (partRule part) value;
  captureValue = part: name:
    if part.value_kind == "symbol" then
      let value = reference name;
      in if value == null then fail "declaration names must be symbols, write from as its own field" else value
    else
      let
        numeric =
          if builtins.match "(0|[1-9][0-9]*)" name != null then
            renderPartValue part (lib.toInt name) else bad;
        textual = renderPartValue part name;
      in
      if numeric.ok then numeric.text else if textual.ok then textual.text
      else fail "invalid captured name ${name} for grammar rule ${part.rule}";
  literals = parts: map (part: part.text) (filter (part: part.kind == "literal") parts);
  hasKind = kind: parts: any (part: part.kind == kind) parts;
  punctuation = text: elem text [ ";" "=" ":" "," "(" ")" "[" "]" "{" "}" "" ];
  takeWhile = predicate: parts:
    let
      size = length parts;
      end = index: if index < size && predicate (elemAt parts index) then end (index + 1) else index;
    in
    lib.take (end 0) parts;
  leading = parts: takeWhile (part: part.kind == "literal" && !punctuation part.text) parts;
  formInfo = form:
    let
      prefix = map (part: part.text) (leading form.parts);
      rest = lib.drop (length prefix) form.parts;
      first = if rest == [ ] then null else head rest;
      header = form.header or null;
      named = header != null || (form.named or false) || (first != null && first.kind == "value" && (
        hasKind "block" (tail rest) || hasKind "declaration" (tail rest)
          || hasKind "body" (tail rest)
          || any (part: part.kind == "literal" && part.text == "=") (tail rest)
      ));
    in
    { inherit prefix rest first header named; path = form.path; };
  headerData = header: value:
    let
      groups = if isList value then value else [ value ];
      readField = field:
        let
          supplied = filter (group: ordinary group && hasAttr field group) groups;
          values = lib.unique (map (group: group.${field}) supplied);
        in
        if length values > 1 then fail "a declaration may have only one ${field} header value"
        else { present = supplied != [ ]; value = if values == [ ] then null else head values; };
      from = readField header.field;
      modifiers = map (modifier: modifier // readField modifier.field) (header.modifiers or [ ]);
      fields = [ header.field ] ++ map (modifier: modifier.field) modifiers;
      stripped = map (group: if ordinary group then removeAttrs group fields else group) groups;
    in
    {
      inherit modifiers;
      present = from.present;
      source = from.value;
      value = if isList value then stripped else head stripped;
    };
  renderTail = parts: value:
    let
      blocks = filter (part: part.kind == "block") parts;
      options = filter (part: part.kind == "options") parts;
      bodies = filter (part: part.kind == "body") parts;
      declarations = filter (part: part.kind == "declaration") parts;
      values = filter (part: part.kind == "value") parts;
      renderParts = f: join (map (part: if part.kind == "literal" then part.text else f part) parts);
    in
    if length declarations == 1 && values == [ ] && blocks == [ ] && bodies == [ ] && options == [ ] then
      let result = renderDeclaration (head declarations) value;
      in if result.ok then good (renderParts (_: result.text)) else result
    else if length blocks == 1 && values == [ ] && bodies == [ ] && options == [ ] && declarations == [ ] then
      let result = renderScope (head blocks).scope value;
      in if result.ok then good (renderParts (_: "{\n${result.text}\n}")) else result
    else if length options == 1 && values == [ ] && blocks == [ ] && bodies == [ ] && declarations == [ ] then
      let result = renderScope (head options).scope value;
      in if result.ok then good (renderParts (_: result.text)) else result
    else if length bodies == 1 && values == [ ] && blocks == [ ] && options == [ ] && declarations == [ ] then
      let result = renderValue (head bodies).rule value;
      in if result.ok then good (renderParts (_: result.text)) else result
    else if length values == 1 && blocks == [ ] && bodies == [ ] && options == [ ] && declarations == [ ] then
      let result = renderPartValue (head values) value;
      in if result.ok then good (renderParts (_: result.text)) else result
    else if values == [ ] && blocks == [ ] && bodies == [ ] && options == [ ] && declarations == [ ] then
      if value == true || value == { } then good (join (literals parts)) else bad
    else bad;
  matchForm = info: path: value:
    let
      remaining = lib.drop (length info.path) path;
      captures = info.named && length remaining == 1;
      tailParts = if info.named then tail info.rest else info.rest;
      header = if info.header == null then { source = null; present = false; modifiers = [ ]; inherit value; } else headerData info.header value;
      name = if captures then head remaining else "";
      captured = if captures then captureValue info.first name else "";
      source =
        if !header.present then good ""
        else if (info.header.from_rule or null) == null then invalid "this declaration has no source-derived from header"
        else renderValue info.header.from_rule header.source;
      modifiersValid = all (modifier: !modifier.present || isBool modifier.value) header.modifiers;
      modifierParts = concatMap (modifier: if modifier.present && modifier.value then modifier.parts else [ ]) header.modifiers;
      result = renderTail tailParts header.value;
    in
    if !prefixOf info.path path || (info.named && !captures) || (!info.named && remaining != [ ]) then bad
    else if !source.ok then source
    else if !modifiersValid then invalid "declaration header modifiers must be booleans"
    else if result.ok then (good (join (
      info.prefix ++ [ captured ]
        ++ (if !header.present then [ ] else info.header.from_prefix ++ [ source.text ])
        ++ modifierParts
        ++ [ result.text ]
    ))) // {
      score =
        if value == true && all (part: part.kind == "literal") tailParts then 1
        else if ordinary value || isList value then
          length (filter (part: elem part.kind [ "block" "options" "declaration" ]) tailParts)
        else 0;
    } else result;
  canonicalHint = scope: path:
    let
      spelling = concatStringsSep "-" path;
      paths = lib.unique (map (form: form.path) schema.scopes.${scope});
      hints = filter
        (candidate:
          let canonical = concatStringsSep "-" candidate;
          in canonical == spelling || lib.hasPrefix "${spelling}-" canonical)
        paths;
    in
    if hints == [ ] then "" else " (canonical spelling ${concatStringsSep "." (head hints)})";
  # the Nix values a primitive takes, as describe in src/values/settings.rs names them
  describePrimitive = shape:
    let
      family = { ipv4 = "IPv4"; ipv6 = "IPv6"; }.${shape.family or ""} or "IP";
      listed = names: concatStringsSep ", " names;
      suffixes = map join (shape.suffixes or [ ]);
    in
    {
      switch = "boolean";
      integer = "integer";
      number-expression = "integer";
      string = "string";
      symbol = "symbol name";
      expression = "expression";
      ip-address = "${family} address";
      prefix = "${family} prefix";
      duration = "{ value, unit } with unit one of ${listed (attrNames (shape.units or { }))}";
      type-name = "one of ${listed (attrNames (shape.values or { }))}"
        + lib.optionalString (suffixes != [ ]) ", optionally followed by ${concatStringsSep " or " suffixes}";
    }.${shape.representation};
  describeValue = depth: name:
    let
      shape = schema.value_types.${name};
      fields = form: map (part: part.name) (filter (part: elem part.kind [ "field" "body" ]) form.parts);
    in
    if shape.kind == "primitive" then describePrimitive shape
    else if shape.kind == "enum" then "one of ${concatStringsSep ", " (attrNames shape.values)}"
    else if shape.kind == "record" then "{ ${concatStringsSep ", " (lib.unique (concatMap fields shape.forms))} }"
    else if shape.kind == "list" then if depth > 1 then "a list" else "[ ${describeValue (depth + 1) shape.item_rule} ]"
    else if shape.kind == "choice" then
      if depth > 1 then "one of several forms"
      else concatStringsSep " or " (lib.unique (map (describeValue (depth + 1)) shape.alternatives))
    else if shape.kind == "body" then "native BIRD text"
    else if shape.kind == "constructor" then "bird.${shape.id} [ ... ]"
    else ''an exact { _rule = "${shape.rule}"; } node'';
  describeSetting = scope: path:
    let
      infos = filter
        (info: prefixOf info.path path
          && (if info.named then length path == length info.path + 1 else path == info.path))
        (map formInfo schema.scopes.${scope});
      parts = info: filter (part: part.kind != "literal") (if info.named then tail info.rest else info.rest);
      # renderTail writes a form with at most one value part, the others need exact nodes
      describeForm = info:
        if parts info == [ ] then "true"
        else
          let part = head (parts info);
          in if part.kind == "value" then describeValue 0 (partRule part)
          else if elem part.kind [ "block" "options" ] then "an attribute set of settings"
          else if part.kind == "body" then "native BIRD text"
          else "a declaration record";
      texts = lib.unique (map describeForm (filter (info: length (parts info) <= 1) infos));
    in
    if texts == [ ] then "" else ", expected ${concatStringsSep " or " texts}";
  renderEntry = scope: path: value:
    let
      infos = map formInfo schema.scopes.${scope};
      matching = filter
        (info: prefixOf info.path path
          && (if info.named then length path == length info.path + 1 else path == info.path))
        infos;
      results = map (info: matchForm info path value) matching;
      candidates = filter (result: result.ok) results;
      best = lib.foldl' (score: result: lib.max score (result.score or 0)) 0 candidates;
      texts = lib.unique (map (result: result.text) (filter (result: (result.score or 0) == best) candidates));
      groups = filter
        (info: prefixOf path info.path
          && (length path < length info.path || (info.named && path == info.path)))
        infos;
      known = matching != [ ] || groups != [ ];
      nested = ordinary value && groups != [ ];
      errors = filter (result: result.error != "") results;
    in
    builtins.addErrorContext "while rendering BIRD setting ${concatStringsSep "." path}" (
      if length texts == 1 then good (head texts)
      else if length texts > 1 then located path (invalid "ambiguous serialization, write it as an exact grammar node")
      else if isList value && known then
        let statements = combine (lib.imap0 (index: item: indexed path index (renderEntry scope path item)) value);
        in if statements.ok || errors == [ ] then statements else located path (head errors)
      else if nested then
        combine
          (map
            (name: renderEntry scope (path ++ [ name ]) value.${name})
            (orderedNames value))
      else if errors != [ ] then located path (head errors)
      else if known then located path (invalid "invalid value${describeSetting scope path}")
      else located path (invalid "unknown setting${canonicalHint scope path}")
    );

  # Native bodies stay opaque, so the registry's declaration order decides what BIRD reads first.
  phase = name:
    let
      order = inventory.registry.declaration_order;
      position = list: lib.lists.findFirstIndex (entry: entry == name) null list;
      first = position order.first;
      last = position order.last;
    in
    if name == includeKeyword then 0
    else if first != null then 1 + first
    else if last != null then 2 + length order.first + last
    else 1 + length order.first;
  orderedNames = value: sort (a: b: if phase a == phase b then a < b else phase a < phase b) (attrNames value);
  dataReferences = value:
    if tagged value then
      if value._bird == "symbol" then [ value.value ]
      else if elem value._bird [ "tuple" "ec" ] then concatMap dataReferences value.value
      else [ ]
    else if isList value then concatMap dataReferences value
    else [ ];
  valueReferences = rule: value:
    let
      shape = schema.value_types.${rule};
      fields =
        if shape.kind == "record" then
          concatMap
            (form: filter (part: elem part.kind [ "field" "body" ]) form.parts)
            shape.forms else [ ];
      names = map (part: part.name) fields;
      spreads =
        if shape.kind == "record" then
          concatMap
            (form: filter (part: part.kind == "spread") form.parts)
            shape.forms else [ ];
    in
    if tagged value then dataReferences value
    else if node value then [ ]
    else if shape.kind == "primitive" then
      if shape.representation == "symbol" && isString value then [ value ]
      else if elem shape.representation [ "expression" "number-expression" ] then dataReferences value
      else if shape.representation == "duration" && ordinary value && value ? value then dataReferences value.value
      else [ ]
    else if shape.kind == "choice" then
      concatMap
        (alternative: if (renderValue alternative value).ok then valueReferences alternative value else [ ])
        shape.alternatives
    else if shape.kind == "list" && isList value then concatMap (valueReferences shape.item_rule) value
    else if shape.kind == "record" && ordinary value then
      concatMap (part: if hasAttr part.name value then valueReferences part.rule value.${part.name} else [ ]) fields
      ++ concatMap (part: scopeReferences part.scope (removeAttrs value names)) spreads
    else [ ];
  entryReferences = scope: path: value:
    let
      infos = map formInfo schema.scopes.${scope};
      matching = filter
        (info: prefixOf info.path path
          && (if info.named then length path == length info.path + 1 else path == info.path))
        infos;
      accepted = filter (info: (matchForm info path value).ok) matching;
      groups = any
        (info: prefixOf path info.path
          && (length path < length info.path || (info.named && path == info.path)))
        infos;
      references = info:
        let
          header =
            if info.header == null then { source = null; inherit value; }
            else headerData info.header value;
          source = if isString header.source then [ header.source ] else dataReferences header.source;
          parts = if info.named then tail info.rest else info.rest;
        in
        source ++ concatMap
          (part:
            if part.kind == "value" then valueReferences (partRule part) header.value
            else if elem part.kind [ "block" "options" ] then scopeReferences part.scope header.value
            else [ ])
          parts;
    in
    if accepted != [ ] then concatMap references accepted
    else if isList value then concatMap (entryReferences scope path) value
    else if ordinary value && groups then
      concatMap
        (name: entryReferences scope (path ++ [ name ]) value.${name})
        (attrNames value)
    else [ ];
  scopeReferences = scope: value:
    if isList value then concatMap (scopeReferences scope) value
    else if ordinary value then concatMap (name: entryReferences scope [ name ] value.${name}) (attrNames value)
    else [ ];
  namedForms = filter (info: info.named && info.path != [ ] && info.first.value_kind == "symbol")
    (map formInfo schema.scopes.${schema.root});
  declarations = settings: concatMap
    (path:
      let
        info = head (filter (candidate: candidate.path == path) namedForms);
        values = lib.attrByPath path { } settings;
      in
      if !ordinary values then [ ] else
      map
        (name: { inherit info name; path = path ++ [ name ]; value = values.${name}; })
        (attrNames values))
    (lib.unique (map (info: info.path) namedForms));
  removeSetting = path: value:
    if path == [ ] || !ordinary value || !hasAttr (head path) value then value
    else if length path == 1 then removeAttrs value path
    else
      let name = head path; child = removeSetting (tail path) value.${name};
      in if child == { } then removeAttrs value [ name ] else value // { ${name} = child; };
  orderDeclarations = entries:
    let
      key = entry: concatStringsSep "." entry.path;
      baseline = sort
        (a: b:
          let left = phase (head a.path); right = phase (head b.path);
          in if left == right then key a < key b else left < right)
        entries;
      visit = stack: state: entry:
        let
          id = key entry;
          references = lib.unique (entryReferences schema.root entry.path entry.value);
          parents = filter (candidate: candidate.name != null && elem candidate.name references) baseline;
          next = lib.foldl' (visit (stack ++ [ id ])) state parents;
        in
        if elem id state.seen then state
        else if elem id stack then fail "cyclic typed declaration references: ${concatStringsSep " -> " (stack ++ [ id ])}"
        else { seen = next.seen ++ [ id ]; entries = next.entries ++ [ entry ]; };
    in
    (lib.foldl' (visit [ ]) { seen = [ ]; entries = [ ]; } baseline).entries;
  renderRoot = value:
    let
      named = declarations value;
      remaining = lib.foldl' (settings: entry: removeSetting entry.info.path settings) value named;
      entries = named ++ map (name: { path = [ name ]; name = null; value = remaining.${name}; }) (attrNames remaining);
    in
    combine (map
      (entry:
        if entry.path == [ includeKeyword ] then good (includeText entry.value)
        else renderEntry schema.root entry.path entry.value)
      (orderDeclarations entries));
  renderScope = scope: value:
    if node value then
      if scope == schema.root && value._rule == grammar.configuration_start then good (exact value) else bad
    else if isList value then combine (map (renderScope scope) value)
    else if ordinary value then
      if scope == schema.root then renderRoot value
      else
        combine (map
          (name: if name == includeKeyword then good (includeText value.${name}) else renderEntry scope [ name ] value.${name})
          (orderedNames value))
    else bad;
  includeText = values:
    let paths = lib.toList values;
    in if paths == [ ] then "" else "\n" + concatStringsSep "\n" (map includeDirective paths) + "\n";
  render = settings:
    if !ordinary settings && !isList settings && !node settings then fail "settings must be named attributes or ordered declaration groups"
    else
      let result = renderScope schema.root settings;
      in if !result.ok then
        fail
          (
            if result.error == "" then "settings do not match the source grammar (${inventory.source.fingerprint})"
            else if result.at == [ ] then result.error
            else "${location result.at}: ${result.error}"
          )
      else result.text + (if result.text == "" then "" else "\n");
  validate = settings: builtins.deepSeq (render settings) settings;

  valueMerge = rule: path:
    let
      shape = schema.value_types.${rule};
      roles = if shape.kind == "body" then filter (role: roleField role == head path) shape.roles else [ ];
      fields =
        if shape.kind == "record" then
          concatMap
            (form: filter (part: elem part.kind [ "field" "body" ] && part.name == head path) form.parts)
            shape.forms else [ ];
      spreads =
        if shape.kind == "record" then
          concatMap
            (form: filter (part: part.kind == "spread") form.parts)
            shape.forms else [ ];
    in
    if path == [ ] then {
      kind =
        if shape.kind == "body" || (shape.kind == "record" && shape.merge == "fields") then "fields"
        else if shape.kind == "list" then "append" else "replace";
      inherit rule;
    }
    else if shape.kind == "choice" then chooseMerge (map (alternative: valueMerge alternative path) shape.alternatives)
    else if roles != [ ] then {
      kind = if elem (head roles).role [ "variables" "body" ] then "lines" else "replace";
    }
    else if fields != [ ] then chooseMerge (map (part: valueMerge part.rule (tail path)) fields)
    else if spreads != [ ] then chooseMerge (map (part: scopeMerge part.scope path) spreads)
    else { kind = "replace"; };
  chooseMerge = candidates:
    let kinds = lib.unique (map (candidate: candidate.kind) candidates);
    in if elem "fields" kinds then { kind = "fields"; }
    else if candidates == [ ] || length kinds != 1 then { kind = "replace"; }
    else head candidates;
  tailMerge = parts: path:
    let
      blocks = filter (part: elem part.kind [ "block" "options" ]) parts;
      values = filter (part: part.kind == "value") parts;
      native = filter (part: part.kind == "declaration") parts;
      bodies = filter (part: part.kind == "body") parts;
    in
    if length blocks == 1 then scopeMerge (head blocks).scope path
    else if length values == 1 then valueMerge (partRule (head values)) path
    else if length bodies == 1 then valueMerge (head bodies).rule path
    else if length native == 1 then
      if path == [ ] then { kind = "fields"; }
      else
        let roles = filter (role: roleField role == head path) (head native).roles;
        in { kind = if roles != [ ] && elem (head roles).role [ "variables" "body" ] then "lines" else "replace"; }
    else { kind = "replace"; };
  scopeMerge = scope: path:
    let
      infos = map formInfo schema.scopes.${scope};
      groups = any
        (info: prefixOf path info.path
          && (length path < length info.path || (info.named && path == info.path)))
        infos;
      matching = filter
        (info: (info.path != [ ] || info.named || path == [ ]) && prefixOf info.path path
          && (!info.named || length path > length info.path))
        infos;
      longest = lib.foldl' (size: info: lib.max size (length info.path)) 0 matching;
      matches = filter (info: length info.path == longest) matching;
      candidates = map
        (info:
          let
            remaining = lib.drop (length info.path + (if info.named then 1 else 0)) path;
            parts = if info.named then tail info.rest else info.rest;
            headerFields =
              if info.header == null then [ ]
              else [ info.header.field ] ++ map (modifier: modifier.field) (info.header.modifiers or [ ]);
          in
          if remaining != [ ] && elem (head remaining) headerFields then { kind = "replace"; }
          else tailMerge parts remaining)
        matches;
    in
    (if path == [ ] || groups then { kind = "fields"; } else chooseMerge candidates)
    // { known = path == [ ] || groups || matches != [ ]; };
  locationMerge = location:
    let
      candidates = map (index: scopeMerge schema.root (lib.drop index location))
        (if location == [ ] then [ 0 ] else lib.range 0 (length location - 1));
      useful = filter (candidate: candidate.known or false) candidates;
    in
    if useful == [ ] then { kind = "replace"; } else head useful;
  valueType = lib.types.mkOptionType {
    name = "bird-typed-value";
    description = "source-derived BIRD data, native body, declaration map or ordered statement list";
    check = value: value == null || isString value || isInt value || isBool value || isPath value || isList value || isAttrs value;
    merge = location: definitions:
      let
        values = map (definition: definition.value) definitions;
        strategy = locationMerge location;
      in
      if strategy.kind == "lines" && all isString values then lib.types.lines.merge location definitions
      else if strategy.kind == "fields" && all ordinary values then (lib.types.attrsOf valueType).merge location definitions
      else if all isList values then (lib.types.listOf valueType).merge location definitions
      else lib.mergeEqualOption location definitions;
    emptyValue = { value = { }; };
  };
  settingsAttrs = lib.types.attrsOf valueType;
  settingsType = lib.types.either settingsAttrs (lib.types.listOf valueType);
  settingsModule = { freeformType = settingsAttrs; };
  resolveData = import ./resolve.nix { inherit lib inventory formInfo orderedNames renderValue partRule headerData matchForm; };
  resolve = settings: resolveData (validate settings);
  eval = { modules, specialArgs ? { } }:
    let
      evaluated = lib.evalModules { inherit specialArgs; modules = [ settingsModule ] ++ modules; };
      raw = removeAttrs evaluated.config [ "_module" ];
      text = render raw;
      config = builtins.deepSeq text raw;
    in
    { inherit config text; resolved = resolveData config; };
  check = { pkgs, modules, package, specialArgs ? { }, name ? "bird.conf" }:
    let
      evaluated = eval { inherit modules specialArgs; };
      configuration = pkgs.writeText "unchecked-${name}" evaluated.text;
    in
    pkgs.runCommand name { nativeBuildInputs = [ package ]; passthru = evaluated // { inherit inventory; }; } ''
      bird -p -c ${configuration}
      cp ${configuration} "$out"
    '';
in
{
  inherit settingsModule settingsType render validate resolve eval check
    string symbol ip prefix tuple ec expr include inventory;
  toText = semantic;
  nixosModule = ./module.nix;
}
