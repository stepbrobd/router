# Bird2 Babel protocol compiler

{ std, compileFilter }:

instanceName:

babelConfig:

let
  filterOrNone = roaTable: dir: filterVal:
    if filterVal == null then "${dir} none;"
    else
      let cf = compileFilter { inherit roaTable; };
      in "${dir} filter {\n${cf filterVal}\n};";

  mkInterface = ifName: ifCfg:
    ''
          interface "${ifName}" {
            type ${ifCfg.type.type};
      ${std.optionalString (ifCfg.rxcost != null) "      rxcost ${toString ifCfg.rxcost};\n"}${std.optionalString (ifCfg.hello != null) "      hello ${toString ifCfg.hello};\n"}${std.optionalString (ifCfg.update != null) "      update ${toString ifCfg.update};\n"}    };'';

  interfaces = std.concatStringsSep "\n"
    (std.mapAttrsToList mkInterface babelConfig.interfaces);

  body = ''
    protocol babel ${instanceName} {
      ipv4 {
        ${filterOrNone "roa4" "import" babelConfig.ipv4.import.filter}
        ${filterOrNone "roa4" "export" babelConfig.ipv4.export.filter}
      };
      ipv6 {
        ${filterOrNone "roa6" "import" babelConfig.ipv6.import.filter}
        ${filterOrNone "roa6" "export" babelConfig.ipv6.export.filter}
      };
    ${interfaces}
    }
  '';

in
[
  {
    order = babelConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (babelConfig.extraConfigBefore != "") babelConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (babelConfig.extraConfigAfter != "") babelConfig.extraConfigAfter
    );
  }
]
