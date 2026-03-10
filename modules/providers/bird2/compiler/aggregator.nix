# Bird2 aggregator protocol compiler

{ std, compileFilter }:

instanceName:

aggConfig:

let
  filterOrNone = dir: filterVal:
    if filterVal == null then "${dir} none;"
    else
      let cf = compileFilter { roaTable = "roa4"; };
      in "${dir} filter {\n${cf filterVal}\n};";

  body = ''
    protocol aggregator ${instanceName} {
      table ${aggConfig.table};
      peer table ${aggConfig.peer};
      ${filterOrNone "export" aggConfig.export.filter}
    }
  '';

in
[
  {
    order = aggConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (aggConfig.extraConfigBefore != "") aggConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (aggConfig.extraConfigAfter != "") aggConfig.extraConfigAfter
    );
  }
]
