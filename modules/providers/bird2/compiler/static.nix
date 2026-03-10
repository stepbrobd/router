# Bird2 static protocol compiler
#
# emits separate blocks for v4 and v6 route lists.
# skips an address family when its route list is empty.

{ std, router }:

staticConfig:

let
  compileRoute = route:
    let
      actionStr =
        if route.action.action == "via" then "via ${route.action.gateway}"
        else route.action.action;
    in
    "  route ${route.prefix} ${actionStr};";

  mkStatic = name: af: routes:
    let
      routeLines = std.concatMapStringsSep "\n" compileRoute routes;
      body = ''
        protocol static ${name} {
          ${af};
        ${routeLines}
        }
      '';
    in
    {
      order = staticConfig.order;
      text = std.concatStringsSep "\n" (
        std.optional (staticConfig.extraConfigBefore != "") staticConfig.extraConfigBefore
        ++ [ body ]
        ++ std.optional (staticConfig.extraConfigAfter != "") staticConfig.extraConfigAfter
      );
    };

in
std.optional (staticConfig.ipv4.routes != [ ]) (mkStatic "static4" "ipv4" staticConfig.ipv4.routes)
++ std.optional (staticConfig.ipv6.routes != [ ]) (mkStatic "static6" "ipv6" staticConfig.ipv6.routes)
