# Bird2 MRT protocol compiler

{ std }:

dumpName:

mrtConfig:

let
  body = ''
    protocol mrt ${dumpName} {
      table "${mrtConfig.table}";
      filename "${mrtConfig.filename}";
      period ${toString mrtConfig.period};
    }
  '';

in
[
  {
    order = mrtConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (mrtConfig.extraConfigBefore != "") mrtConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (mrtConfig.extraConfigAfter != "") mrtConfig.extraConfigAfter
    );
  }
]
