# Bird2 BFD protocol compiler
#
# one protocol bfd block per session, since the contract type
# models sessions as attrsOf.

{ std }:

sessionName:

bfdConfig:

let
  body = ''
    protocol bfd ${sessionName} {
      neighbor ${bfdConfig.neighbor} {
        min rx interval ${toString bfdConfig.minRxInterval} ms;
        min tx interval ${toString bfdConfig.minTxInterval} ms;
        multiplier ${toString bfdConfig.multiplier};
    ${std.optionalString (bfdConfig.interface != null) "    interface \"${bfdConfig.interface}\";\n"}  };
    }
  '';

in
[
  {
    order = bfdConfig.order;
    text = std.concatStringsSep "\n" (
      std.optional (bfdConfig.extraConfigBefore != "") bfdConfig.extraConfigBefore
      ++ [ body ]
      ++ std.optional (bfdConfig.extraConfigAfter != "") bfdConfig.extraConfigAfter
    );
  }
]
