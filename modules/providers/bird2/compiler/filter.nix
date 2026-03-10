# filter AST to Bird2 filter body syntax
#
# curried: { std, router } -> { roaTable } -> filterValue -> string
#
# the roaTable argument controls which ROA table is referenced in
# roa_check() calls.  the BGP compiler passes the correct table
# for each address family.

{ std, router }:

{ roaTable ? "roa4" }:

filterValue:

let
  roaStatusMap = {
    valid = "ROA_VALID";
    invalid = "ROA_INVALID";
    unknown = "ROA_UNKNOWN";
    notFound = "ROA_UNKNOWN";
  };

  # fill in defaults for match/action so callers need not supply every key
  defaultMatch = {
    roaStatus = null;
    prefixIn = null;
    bgpAsn = null;
    bgpPathLength = null;
    communityHas = null;
  };

  defaultAction = {
    decision = null;
    setLocalPref = null;
    setMed = null;
    prependPath = null;
    addCommunity = null;
    deleteCommunity = null;
  };

  # extract the prefix length from a CIDR string (e.g. "10.0.0.0/8" -> 8)
  parsePrefixLen = cidr:
    let
      parts = std.splitString "/" cidr;
    in
    std.toInt (std.elemAt parts 1);

  # Bird2 prefix set notation
  compilePrefixEntry = entry:
    if entry.ge == null && entry.le == null then
      entry.prefix
    else
      let
        geVal = if entry.ge != null then entry.ge else parsePrefixLen entry.prefix;
        leVal = if entry.le != null then entry.le else 128;
      in
      "${entry.prefix}{${toString geVal},${toString leVal}}";

  # compile a single action attrset into a list of Bird2 statements
  compileAction = rawAction:
    let
      action = defaultAction // rawAction;
      parts =
        std.optional (action.setLocalPref != null)
          "bgp_local_pref = ${toString action.setLocalPref};"
        ++ std.optional (action.setMed != null)
          "bgp_med = ${toString action.setMed};"
        ++ std.optional (action.prependPath != null)
          (std.concatStringsSep "\n"
            (std.genList
              (_: "bgp_path.prepend(${toString action.prependPath.asn});")
              action.prependPath.count))
        ++ std.optional (action.addCommunity != null)
          "bgp_community.add((${toString action.addCommunity.asn}, ${toString action.addCommunity.value}));"
        ++ std.optional (action.deleteCommunity != null)
          "bgp_community.delete((${toString action.deleteCommunity.asn}, ${toString action.deleteCommunity.value}));"
        ++ std.optional (action.decision != null)
          # decision may be a string ("accept") or a policyType attrset ({ decision = "accept"; })
          (
            let
              d =
                if builtins.isString action.decision then action.decision
                else action.decision.decision;
            in
            if d == "accept" then "accept;" else "reject;"
          );
    in
    std.concatStringsSep "\n" parts;

  # compile match conditions into a list of Bird2 boolean expressions
  compileConditions = rawMatch:
    let
      match = defaultMatch // rawMatch;
      parts =
        std.optional (match.roaStatus != null)
          "roa_check(${roaTable}, net, bgp_path.last) = ${roaStatusMap.${match.roaStatus.status}}"
        ++ std.optional (match.prefixIn != null)
          "net ~ [ ${std.concatMapStringsSep ", " compilePrefixEntry match.prefixIn.prefixes} ]"
        ++ std.optional (match.bgpAsn != null)
          "bgp_path.last = ${toString match.bgpAsn}"
        ++ std.optional (match.bgpPathLength != null)
          "bgp_path.len ${match.bgpPathLength.op.op} ${toString match.bgpPathLength.value}"
        ++ std.optional (match.communityHas != null)
          "(${toString match.communityHas.asn}, ${toString match.communityHas.value}) ~ bgp_community";
    in
    parts;

  compileRule = rule:
    let
      conditions = compileConditions rule.match;
      actionBody = compileAction rule.action;
      condStr = std.concatStringsSep " && " conditions;
    in
    if conditions == [ ] then
    # unconditional -- emit actions directly
      actionBody
    else
      "if (${condStr}) then {\n${actionBody}\n}";

in
std.concatMapStringsSep "\n" compileRule filterValue.rules
