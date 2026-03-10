# Bird2 OSPF protocol compiler
#
# v2 uses ipv4 channel, v3 uses ipv6 channel.

{ std, router, compileFilter }:

instanceName:

ospfConfig:

let
  isV2 = ospfConfig.version.version == "v2";

  versionStr = if isV2 then "v2" else "v3";
  af = if isV2 then "ipv4" else "ipv6";

  channelCfg = if isV2 then ospfConfig.ipv4 else ospfConfig.ipv6;

  filterOrNone = dir: filterVal:
    if filterVal == null then "${dir} none;"
    else
      let cf = compileFilter { roaTable = if isV2 then "roa4" else "roa6"; };
      in "${dir} filter {\n${cf filterVal}\n};";

  mkInterface = ifName: ifCfg:
    ''
          interface "${ifName}" {
            hello ${toString ifCfg.hello};
            wait ${toString ifCfg.wait};
      ${std.optionalString (ifCfg.cost != null) "      cost ${toString ifCfg.cost};\n"}${std.optionalString (ifCfg.priority != null) "      priority ${toString ifCfg.priority};\n"}    };'';

  mkArea = areaId: areaCfg:
    let
      interfaces = std.concatStringsSep "\n"
        (std.mapAttrsToList mkInterface areaCfg.interfaces);
    in
    ''
        area ${areaId} {
      ${interfaces}
        };'';

  areas = std.concatStringsSep "\n"
    (std.mapAttrsToList mkArea ospfConfig.areas);

  body = ''
    protocol ospf ${versionStr} ${instanceName} {
      ${af} {
        ${filterOrNone "import" channelCfg.import.filter}
        ${filterOrNone "export" channelCfg.export.filter}
      };
    ${areas}
    }
  '';

in
[
  {
    order = ospfConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (ospfConfig.extraConfigBefore != "") ospfConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (ospfConfig.extraConfigAfter != "") ospfConfig.extraConfigAfter
    );
  }
]
