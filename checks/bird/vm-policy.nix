{ router, owned }:
{ config, ... }:
let
  bird = router.bird;
  inherit (bird) expr stmt;
  settings = config.services.bird.settings;
  member =
    name: attribute:
    expr.raw {
      text = "${name} ~ ${attribute}";
      type = "bool";
      dependsOn = [ settings.defines.${name}.ref ];
    };
in
{
  services.bird.settings = {
    defines = {
      OWNED = bird.prefixSet [ owned ];
      C_STANDARD = bird.community.standard 65000 100;
      C_LARGE = bird.community.large 65000 100 1;
      C_EXTENDED = bird.community.extended "rt" 65000 100;
      C_STALE = bird.community.standard 65000 999;
    };
    functions = {
      owns = {
        params = [
          {
            name = "candidate";
            type = "prefix";
          }
        ];
        returnType = "bool";
        body = [
          (stmt.return (expr.inSet (expr.local "candidate") settings.defines.OWNED.ref))
        ];
      };
      tag_origin.body = [
        (stmt.addCommunities [
          settings.defines.C_STANDARD.ref
          settings.defines.C_LARGE.ref
          settings.defines.C_EXTENDED.ref
        ])
        (stmt.deleteCommunities [ settings.defines.C_STALE.ref ])
      ];
      verified = {
        returnType = "bool";
        body = [
          (stmt.return (
            expr.all [
              (member "C_STANDARD" "bgp_community")
              (member "C_LARGE" "bgp_large_community")
              (member "C_EXTENDED" "bgp_ext_community")
              (expr.not (member "C_STALE" "bgp_community"))
              (expr.eq bird.route.bgpMed 42)
            ]
          ))
        ];
      };
    };
    filters = {
      export_owned = {
        default = "reject";
        body = [
          (stmt.when
            (expr.all [
              (expr.fromProtocol settings.protocols.originate4.ref)
              (expr.call settings.functions.owns.ref [ bird.route.net ])
            ])
            [
              (stmt.call settings.functions.tag_origin.ref [ ])
              (stmt.set bird.route.bgpMed 42)
              stmt.accept
            ]
          )
        ];
      };
      import_verified = {
        default = "reject";
        body = [
          (stmt.when (expr.call settings.functions.verified.ref [ ]) [
            (stmt.set bird.route.bgpLocalPref 250)
            stmt.accept
          ])
        ];
      };
    };
  };
}
