{ lib }:
config:
let
  inherit (builtins)
    isAttrs
    isString
    isInt
    isBool
    isList
    attrNames
    elemAt
    length
    ;
  inherit (lib) concatMap mapAttrsToList splitString;
  digits = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
    a = 10;
    b = 11;
    c = 12;
    d = 13;
    e = 14;
    f = 15;
  };
  number =
    base: text:
    builtins.foldl' (n: c: n * base + digits.${lib.toLower c}) 0 (lib.stringToCharacters text);
  matches = pattern: text: isString text && builtins.match pattern text != null;
  pow2 = n: builtins.foldl' (value: _: value * 2) 1 (builtins.genList (x: x) n);
  mod = a: b: a - builtins.div a b * b;
  ipv4 =
    text:
    let
      parts = if isString text then splitString "." text else [ ];
      validParts = length parts == 4 && builtins.all (part: matches "[0-9]{1,3}" part) parts;
      words = if validParts then map (number 10) parts else [ ];
    in
    {
      valid = validParts && builtins.all (n: n <= 255) words;
      inherit words;
    };
  ipv6 =
    text:
    let
      halves = if isString text then splitString "::" text else [ ];
      compressed = length halves == 2;
      tokensFor = part: if part == "" then [ ] else splitString ":" part;
      left = if halves != [ ] then tokensFor (elemAt halves 0) else [ ];
      right = if compressed then tokensFor (elemAt halves 1) else [ ];
      tokens = left ++ right;
      isV4 = token: lib.hasInfix "." token;
      validToken = token: matches "[0-9a-fA-F]{1,4}" token || (ipv4 token).valid;
      wordsFor =
        token:
        if (ipv4 token).valid then
          let
            p = (ipv4 token).words;
          in
          [
            (elemAt p 0 * 256 + elemAt p 1)
            (elemAt p 2 * 256 + elemAt p 3)
          ]
        else if matches "[0-9a-fA-F]{1,4}" token then
          [ (number 16 token) ]
        else
          [ ];
      leftWords = concatMap wordsFor left;
      rightWords = concatMap wordsFor right;
      count = length leftWords + length rightWords;
      v4Tokens = builtins.filter isV4 tokens;
      valid =
        isString text
        && lib.hasInfix ":" text
        && length halves <= 2
        && builtins.all validToken tokens
        && (if compressed then count < 8 else count == 8)
        && (v4Tokens == [ ] || (length v4Tokens == 1 && lib.hasSuffix (builtins.head v4Tokens) text));
      words =
        if valid then
          leftWords ++ builtins.genList (_: 0) (if compressed then 8 - count else 0) ++ rightWords
        else
          [ ];
    in
    {
      inherit valid words;
    };
  ipInfo =
    text:
    let
      parts = if isString text then splitString "%" text else [ ];
      address = if parts == [ ] then "" else builtins.head parts;
      scope = if length parts == 2 then elemAt parts 1 else null;
      v4 = ipv4 address;
      v6 = ipv6 address;
      valid =
        length parts <= 2 && (v4.valid || v6.valid) && (scope == null || matches "[A-Za-z0-9_.:-]+" scope);
    in
    {
      inherit valid address scope;
      family =
        if !valid then
          null
        else if v4.valid then
          "ipv4"
        else
          "ipv6";
      words = if v4.valid then v4.words else v6.words;
    };
  prefixInfo =
    text:
    let
      parts = if isString text then splitString "/" text else [ ];
      address = if parts == [ ] then "" else builtins.head parts;
      ip = ipInfo address;
      lenText = if length parts == 2 then elemAt parts 1 else "";
      prefixLength = if matches "[0-9]{1,3}" lenText then number 10 lenText else null;
      maxLength = if ip.family == "ipv4" then 32 else 128;
      valid =
        length parts == 2
        && ip.valid
        && ip.scope == null
        && prefixLength != null
        && prefixLength <= maxLength;
      wordBits = if ip.family == "ipv4" then 8 else 16;
      network =
        valid
        && builtins.all
          (
            i:
            let
              used = lib.max 0 (lib.min wordBits (prefixLength - i * wordBits));
            in
            mod (elemAt ip.words i) (pow2 (wordBits - used)) == 0
          )
          (builtins.genList (i: i) (length ip.words));
    in
    {
      inherit
        valid
        network
        address
        prefixLength
        maxLength
        ;
      family = ip.family;
    };

  collections = {
    define = "defines";
    table = "tables";
    function = "functions";
    filter = "filters";
    protocol = "protocols";
  };
  targets = attrNames collections;
  lookup =
    reference:
    if
      !isAttrs reference
      || !(reference ? target)
      || !(reference ? name)
      || !isString reference.target
      || !isString reference.name
      || !(builtins.hasAttr reference.target collections)
    then
      null
    else
      (config.${collections.${reference.target}} or { }).${reference.name} or null;
  key = reference: "${reference.target}:${reference.name}";
  declarations =
    concatMap
      (
        target:
        mapAttrsToList
          (name: definition: {
            inherit target name definition;
            key = "${target}:${name}";
          })
          (config.${collections.${target}} or { })
      )
      [
        "define"
        "table"
        "function"
        "filter"
        "protocol"
      ];
  byKey = builtins.listToAttrs (
    map
      (declaration: {
        name = declaration.key;
        value = declaration;
      })
      declarations
  );
  dependencies =
    owner: data:
    if isList data then
      concatMap (dependencies owner) data
    else if !isAttrs data then
      [ ]
    else if (data.kind or null) == "fromProtocol" || (data.kind or null) == "external" then
      [ ]
    else if (data.kind or null) == "reference" then
      lib.optional (data ? target && data ? name && isString data.target && isString data.name) (key data)
    else if (data.kind or null) == "call" then
      (
        if
          isAttrs (data.function or null)
          && (data.function.kind or null) == "reference"
          && (data.function.target or null) == "function"
          && isString (data.function.name or null)
          && owner == key data.function
        then
          [ ]
        else
          dependencies owner (data.function or null)
      )
      ++ dependencies owner (data.arguments or [ ])
    else
      concatMap (dependencies owner) (builtins.attrValues (builtins.removeAttrs data [ "ref" ]));
  dependencyMap = builtins.mapAttrs
    (
      name: declaration: lib.unique (dependencies name declaration.definition)
    )
    byKey;
  sortDeclarations =
    remaining: ordered:
    let
      done = map (declaration: declaration.key) ordered;
      ready = builtins.filter
        (
          declaration:
          builtins.all
            (
              dependency: !(builtins.hasAttr dependency byKey) || builtins.elem dependency done
            )
            dependencyMap.${declaration.key}
        )
        remaining;
      readyKeys = map (declaration: declaration.key) ready;
    in
    if remaining == [ ] || ready == [ ] then
      {
        result = ordered;
        unresolved = remaining;
      }
    else
      sortDeclarations
        (builtins.filter
          (
            declaration: !(builtins.elem declaration.key readyKeys)
          )
          remaining)
        (ordered ++ ready);
  ordering = sortDeclarations declarations [ ];

  emptyInfo = {
    type = null;
    family = null;
    constant = false;
  };
  typeName = value: if isString value then value else null;
  scalarInfo = type: {
    type = typeName type;
    family = null;
    constant = true;
  };
  infer =
    scope: seen: value:
    if isBool value then
      scalarInfo "bool"
    else if isInt value then
      scalarInfo "int"
    else if isString value then
      scalarInfo "string"
    else if !isAttrs value then
      emptyInfo
    else
      let
        kind = value.kind or null;
        info = child: infer scope seen child;
        boolean =
          children:
          (scalarInfo "bool")
          // {
            constant = isList children && builtins.all (child: (info child).constant) children;
          };
        target = lookup value;
      in
      if kind == "ip" then
        (scalarInfo "ip") // { family = (ipInfo (value.value or null)).family; }
      else if kind == "prefix" then
        (scalarInfo "prefix") // { family = (prefixInfo (value.value or null)).family; }
      else if kind == "prefixSet" then
        (scalarInfo "prefix set")
        // {
          family =
            if !(isList (value.prefixes or null)) || value.prefixes == [ ] then
              null
            else
              (prefixInfo (
                let
                  p = builtins.head value.prefixes;
                in
                if isString p then
                  p
                else if isAttrs p then
                  p.prefix or null
                else
                  null
              )).family;
        }
      else if kind == "community" then
        scalarInfo
          (
            {
              standard = "pair";
              extended = "ec";
              large = "lc";
            }.${if isString (value.type or null) then value.type else ""} or null
          )
      else if kind == "reference" && (value.target or null) == "define" && target != null then
        if builtins.elem (key value) seen then
          emptyInfo
        else
          infer { } (seen ++ [ (key value) ]) target.value
      else if kind == "external" && (value.target or null) == "value" then
        (scalarInfo (value.type or null))
      else if kind == "attribute" then
        emptyInfo
        // {
          type = typeName (value.type or null);
          family = if (value.name or null) == "net" then scope.family or null else null;
        }
      else if kind == "local" then
        let
          local = if isString (value.name or null) then (scope.locals or { }).${value.name} or null else null;
        in
        emptyInfo
        // {
          type = typeName (if isAttrs local then local.type or null else local);
          family = if isAttrs local then local.family or null else null;
        }
      else if kind == "rawExpression" then
        {
          type = typeName (value.type or null);
          family = null;
          constant = true;
        }
      else if kind == "call" then
        let
          function = value.function or { };
          declaration = lookup function;
        in
        emptyInfo
        // {
          type = typeName (
            if declaration != null then
              declaration.returnType or null
            else if isAttrs function && (function.kind or null) == "external" then
              function.returnType or null
            else
              null
          );
        }
      else if kind == "all" || kind == "any" then
        boolean (value.values or [ ])
      else if kind == "not" then
        boolean [ (value.value or null) ]
      else if kind == "compare" then
        boolean [
          (value.left or null)
          (value.right or null)
        ]
      else if kind == "inSet" then
        boolean [
          (value.value or null)
          (value.set or null)
        ]
      else if kind == "fromProtocol" then
        emptyInfo // { type = "bool"; }
      else
        emptyInfo;
  typeOf = value: (infer { } [ ] value).type;
in
{
  inherit
    matches
    pow2
    ipInfo
    prefixInfo
    collections
    targets
    lookup
    key
    declarations
    byKey
    dependencyMap
    ordering
    infer
    typeOf
    ;
}
