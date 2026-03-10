# Bird2 RIP protocol compiler

{ std, compileFilter }:

instanceName:

ripConfig:

let
  af = if ripConfig.ipv4 then "ipv4" else "ipv6";

  filterOrNone = dir: filterVal:
    if filterVal == null then "${dir} none;"
    else
      let cf = compileFilter { roaTable = if ripConfig.ipv4 then "roa4" else "roa6"; };
      in "${dir} filter {\n${cf filterVal}\n};";

  ifList = std.concatMapStringsSep ", "
    (i: ''"${i}"'')
    ripConfig.interfaces;

  body = ''
    protocol rip ${instanceName} {
      ${af};
      interface ${ifList};
      ${filterOrNone "import" ripConfig.import.filter}
      ${filterOrNone "export" ripConfig.export.filter}
    }
  '';

in
[
  {
    order = ripConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (ripConfig.extraConfigBefore != "") ripConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (ripConfig.extraConfigAfter != "") ripConfig.extraConfigAfter
    );
  }
]
