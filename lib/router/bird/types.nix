{ lib }:
let
  inherit (lib) types mkOptionType mergeEqualOption;
  expressionKinds = [
    "ip"
    "prefix"
    "prefixSet"
    "community"
    "reference"
    "external"
    "attribute"
    "local"
    "rawExpression"
    "call"
    "all"
    "any"
    "not"
    "inSet"
    "compare"
    "fromProtocol"
  ];
  statementKinds = [
    "accept"
    "reject"
    "when"
    "ifElse"
    "set"
    "return"
    "call"
    "addCommunities"
    "deleteCommunities"
    "rawStatement"
  ];
  tagged = kinds: value: lib.isAttrs value && value ? kind && lib.elem value.kind kinds;
  atomic =
    name: check:
    mkOptionType {
      inherit name check;
      description = name;
      merge = mergeEqualOption;
    };
  primitive = value: lib.isString value || lib.isInt value || lib.isBool value;
  referenceCheck =
    value:
    tagged [ "reference" ] value
    && value ? target
    && lib.isString value.target
    && value ? name
    && lib.isString value.name;
in
rec {
  expression = atomic "BIRD expression" (value: primitive value || tagged expressionKinds value);
  statement = atomic "BIRD statement" (tagged statementKinds);
  body = types.listOf statement;
  reference = atomic "BIRD declaration reference" referenceCheck;
  referenceTo =
    target: atomic "BIRD ${target} reference" (value: referenceCheck value && value.target == target);
  dependencies = types.listOf reference;
  uint = types.ints.between 0 4294967295;
  asn = types.ints.between 1 4294967295;
  port = types.ints.between 1 65535;
  birdType = types.enum [
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
  policy = atomic "BIRD channel policy" (
    value:
    (
      lib.isString value
      && lib.elem value [
        "all"
        "none"
      ]
    )
    || (referenceCheck value && value.target == "filter")
    || (
      lib.isAttrs value
      && ((lib.attrNames value == [ "inline" ]) || (lib.attrNames value == [ "where" ]))
    )
  );
}
