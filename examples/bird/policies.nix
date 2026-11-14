{ config, lib, ... }:
let
  bird = lib.router.bird;
  inherit (bird) expr stmt;
in
{
  functions = {
    is_owned4 = {
      params = [
        {
          name = "candidate";
          type = "prefix";
        }
      ];
      returnType = "bool";
      body = [
        (stmt.return (expr.inSet (expr.local "candidate") config.defines.OWNED4.ref))
      ];
    };
    is_owned6 = {
      params = [
        {
          name = "candidate";
          type = "prefix";
        }
      ];
      returnType = "bool";
      body = [
        (stmt.return (expr.inSet (expr.local "candidate") config.defines.OWNED6.ref))
      ];
    };
    tag_origin.body = [
      (stmt.addCommunities [
        config.defines.C_STANDARD.ref
        config.defines.C_LARGE.ref
        config.defines.C_EXTENDED.ref
      ])
    ];
  };

  filters = {
    export_owned4 = {
      default = "reject";
      body = [
        (stmt.when
          (expr.all [
            (expr.fromProtocol config.protocols.originate4.ref)
            (expr.call config.functions.is_owned4.ref [ bird.route.net ])
          ])
          [
            (stmt.call config.functions.tag_origin.ref [ ])
            stmt.accept
          ]
        )
      ];
    };
    export_owned6 = {
      default = "reject";
      body = [
        (stmt.when
          (expr.all [
            (expr.fromProtocol config.protocols.originate6.ref)
            (expr.call config.functions.is_owned6.ref [ bird.route.net ])
          ])
          [
            (stmt.call config.functions.tag_origin.ref [ ])
            stmt.accept
          ]
        )
      ];
    };
    import_peer4 = {
      default = "reject";
      body = [
        (stmt.when
          (expr.inSet bird.route.net (
            bird.prefixSet [
              {
                prefix = "198.51.100.0/24";
                ge = 24;
                le = 28;
              }
            ]
          ))
          [
            (stmt.set bird.route.bgpLocalPref 150)
            stmt.accept
          ]
        )
      ];
    };
  };
}
