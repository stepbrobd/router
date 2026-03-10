# Bird2 device protocol compiler

{ std }:

deviceConfig:

let
  body = ''
    protocol device {
      scan time ${toString deviceConfig.scanTime};
    }
  '';
in
[
  {
    order = deviceConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (deviceConfig.extraConfigBefore != "") deviceConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (deviceConfig.extraConfigAfter != "") deviceConfig.extraConfigAfter
    );
  }
]
