# Bird2 direct protocol compiler

{ std }:

directConfig:

let
  ifList = std.concatMapStringsSep ", "
    (i: ''"${i}"'')
    directConfig.interfaces;

  body = ''
    protocol direct {
      interface ${ifList};
    ${std.optionalString directConfig.ipv4 "  ipv4;\n"}${std.optionalString directConfig.ipv6 "  ipv6;\n"}}
  '';
in
[
  {
    order = directConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (directConfig.extraConfigBefore != "") directConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (directConfig.extraConfigAfter != "") directConfig.extraConfigAfter
    );
  }
]
