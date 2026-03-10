# Bird2 BGP protocol compiler
#
# for each session, emits up to two protocol blocks (one per address family).
# blocks are skipped when the peering type is disabled or the neighbor
# address for that AF is null.

{ std, router, compileFilter }:

topLevelInput:

sessionName:

sessionConfig:

let
  localAsn =
    if sessionConfig.localAsn != null
    then sessionConfig.localAsn
    else topLevelInput.asn;

  roaTables = topLevelInput.rpki.tables;

  # compile a filter for a specific address family
  mkFilterStr = roaTable: dir: filterVal:
    if filterVal == null then
      "${dir} none;"
    else
      let
        cf = compileFilter { inherit roaTable; };
      in
      "${dir} filter {\n${cf filterVal}\n};";

  # compile a channel block (ipv4 or ipv6)
  mkChannel = af: roaTable: channelCfg:
    if channelCfg == null then ""
    else
      let
        addPathsLine =
          if channelCfg.addPaths.mode != "off"
          then "    add paths ${channelCfg.addPaths.mode};\n"
          else "";
      in
      ''
          ${af} {
        ${addPathsLine}    ${mkFilterStr roaTable "import" channelCfg.import.filter}
            ${mkFilterStr roaTable "export" channelCfg.export.filter}
          };'';

  # build a full protocol block for one AF
  mkBgpBlock = af: neighborAddr: peeringType: sourceAddr: channelCfg: roaTable:
    let
      name = "${sessionName}_${af}";

      connectType =
        if peeringType.type == "multihop" then "multihop;"
        else "direct;";

      grStr = if sessionConfig.gracefulRestart then "on" else "off";

      channelStr = mkChannel af roaTable channelCfg;

      # for v6-over-v4 multiprotocol, add the ipv6 channel to the v4 block
      extraChannel =
        if af == "ipv4" && sessionConfig.multiprotocol != null
          && sessionConfig.multiprotocol.mode == "v6overV4"
          && sessionConfig.ipv6 != null
        then mkChannel "ipv6" roaTables.ipv6 sessionConfig.ipv6
        # for v4-over-v6, add ipv4 channel to the v6 block
        else if af == "ipv6" && sessionConfig.multiprotocol != null
          && sessionConfig.multiprotocol.mode == "v4overV6"
          && sessionConfig.ipv4 != null
        then mkChannel "ipv4" roaTables.ipv4 sessionConfig.ipv4
        else "";

      body = ''
        protocol bgp ${name} {
          graceful restart ${grStr};
          ${connectType}
        ${std.optionalString (sourceAddr != null) "  source address ${sourceAddr};\n"}  local as ${toString localAsn};
          neighbor ${neighborAddr} as ${toString sessionConfig.neighbor.asn};
        ${std.optionalString (sessionConfig.password != null) ''  password "${sessionConfig.password}";\n''}${std.optionalString sessionConfig.bfd "  bfd on;\n"}
        ${channelStr}
        ${extraChannel}
        }
      '';
    in
    {
      order = sessionConfig.order;
      text = std.concatStringsSep "\n" (
        std.optional (sessionConfig.extraConfigBefore != "") sessionConfig.extraConfigBefore
        ++ [ body ]
        ++ std.optional (sessionConfig.extraConfigAfter != "") sessionConfig.extraConfigAfter
      );
    };

  # determine which blocks to emit
  v4Enabled =
    sessionConfig.type.ipv4.type != "disabled"
    && sessionConfig.neighbor.ipv4 != null;

  v6Enabled =
    sessionConfig.type.ipv6.type != "disabled"
    && sessionConfig.neighbor.ipv6 != null
    # skip standalone v6 block when v6-over-v4 -- it is embedded in the v4 block
    && !(sessionConfig.multiprotocol != null && sessionConfig.multiprotocol.mode == "v6overV4");

  # skip standalone v4 block when v4-over-v6 -- it is embedded in the v6 block
  v4StandaloneEnabled = v4Enabled
    && !(sessionConfig.multiprotocol != null && sessionConfig.multiprotocol.mode == "v4overV6");

in
std.optional v4StandaloneEnabled
  (mkBgpBlock "ipv4" sessionConfig.neighbor.ipv4 sessionConfig.type.ipv4
    sessionConfig.source.ipv4
    sessionConfig.ipv4
    roaTables.ipv4)
++ std.optional v6Enabled
  (mkBgpBlock "ipv6" sessionConfig.neighbor.ipv6 sessionConfig.type.ipv6
    sessionConfig.source.ipv6
    sessionConfig.ipv6
    roaTables.ipv6)
