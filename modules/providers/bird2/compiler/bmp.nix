# Bird2 BMP protocol compiler

{ std }:

stationName:

bmpConfig:

let
  modeStr =
    if bmpConfig.mode.mode == "prePolicy" then "pre_policy"
    else "post_policy";

  body = ''
    protocol bmp ${stationName} {
      station address ${bmpConfig.remote} port ${toString bmpConfig.port} {
        monitoring rib in ${modeStr};
      };
    }
  '';

in
[
  {
    order = bmpConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (bmpConfig.extraConfigBefore != "") bmpConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (bmpConfig.extraConfigAfter != "") bmpConfig.extraConfigAfter
    );
  }
]
