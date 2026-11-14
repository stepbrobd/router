{ lib }:
let
  raw =
    kind: value:
    {
      inherit kind;
      dependsOn = [ ];
    }
    // (if builtins.isString value then { text = value; } else value);
  attribute = name: type: {
    kind = "attribute";
    inherit name type;
  };
  call = function: arguments: {
    kind = "call";
    inherit function arguments;
  };
  compare = op: left: right: {
    kind = "compare";
    inherit op left right;
  };
in
{
  ip = value: {
    kind = "ip";
    inherit value;
  };
  prefix = value: {
    kind = "prefix";
    inherit value;
  };
  prefixSet = prefixes: {
    kind = "prefixSet";
    inherit prefixes;
  };
  external =
    specification:
    (builtins.removeAttrs specification [ "kind" ])
    // {
      kind = "external";
      target = specification.kind;
    };

  community = {
    standard = asn: value: {
      kind = "community";
      type = "standard";
      inherit asn value;
    };
    large = asn: data1: data2: {
      kind = "community";
      type = "large";
      inherit asn data1 data2;
    };
    extended = communityType: key: value: {
      kind = "community";
      type = "extended";
      inherit communityType key value;
    };
  };

  route = {
    net = attribute "net" "prefix";
    proto = attribute "proto" "string";
    source = attribute "source" "enum";
    preference = attribute "preference" "int";
    bgpLocalPref = attribute "bgp_local_pref" "int";
    bgpMed = attribute "bgp_med" "int";
    bgpPath = attribute "bgp_path" "bgppath";
    bgpNextHop = attribute "bgp_next_hop" "ip";
    bgpOrigin = attribute "bgp_origin" "enum";
    bgpCommunity = attribute "bgp_community" "clist";
    bgpLargeCommunity = attribute "bgp_large_community" "lclist";
    bgpExtCommunity = attribute "bgp_ext_community" "eclist";
  };

  expr = {
    inherit call;
    raw = raw "rawExpression";
    local = name: {
      kind = "local";
      inherit name;
    };
    all = values: {
      kind = "all";
      inherit values;
    };
    any = values: {
      kind = "any";
      inherit values;
    };
    not = value: {
      kind = "not";
      inherit value;
    };
    inSet = value: set: {
      kind = "inSet";
      inherit value set;
    };
    eq = compare "=";
    ne = compare "!=";
    lt = compare "<";
    le = compare "<=";
    gt = compare ">";
    ge = compare ">=";
    fromProtocol = protocol: {
      kind = "fromProtocol";
      inherit protocol;
    };
  };

  stmt = {
    inherit call;
    accept = {
      kind = "accept";
    };
    reject = {
      kind = "reject";
    };
    when = condition: body: {
      kind = "when";
      inherit condition body;
    };
    ifElse = condition: body: elseBody: {
      kind = "ifElse";
      inherit condition body elseBody;
    };
    set = attribute: value: {
      kind = "set";
      inherit attribute value;
    };
    return = value: {
      kind = "return";
      inherit value;
    };
    addCommunities = values: {
      kind = "addCommunities";
      inherit values;
    };
    deleteCommunities = values: {
      kind = "deleteCommunities";
      inherit values;
    };
    raw = raw "rawStatement";
  };
}
