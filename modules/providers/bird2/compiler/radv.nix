# Bird2 router advertisement protocol compiler

{ std }:

instanceName:

radvConfig:

let
  mkPrefix = p:
    ''
      prefix ${p.prefix} {
        onlink ${if p.onlink then "yes" else "no"};
        autonomous ${if p.autonomous then "yes" else "no"};
      };'';

  mkRdnss = addrs:
    std.concatMapStringsSep "\n"
      (addr: "      rdnss ${addr};")
      addrs;

  mkInterface = ifName: ifCfg:
    let
      prefixes = std.concatMapStringsSep "\n" mkPrefix ifCfg.prefixes;
    in
    ''
          interface "${ifName}" {
            managed ${if ifCfg.managed then "yes" else "no"};
            other config ${if ifCfg.other then "yes" else "no"};
      ${std.optionalString (ifCfg.mtu != null) "      mtu ${toString ifCfg.mtu};\n"}      max ra interval ${toString ifCfg.maxRtrAdvInterval};
            min ra interval ${toString ifCfg.minRtrAdvInterval};
      ${std.optionalString (ifCfg.rdnss != []) (mkRdnss ifCfg.rdnss + "\n")}${prefixes}
          };'';

  interfaces = std.concatStringsSep "\n"
    (std.mapAttrsToList mkInterface radvConfig.interfaces);

  body = ''
    protocol radv ${instanceName} {
    ${interfaces}
    }
  '';

in
[
  {
    order = radvConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (radvConfig.extraConfigBefore != "") radvConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (radvConfig.extraConfigAfter != "") radvConfig.extraConfigAfter
    );
  }
]
