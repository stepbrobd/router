{ router, owned, ... }:
let bird = router.bird; in
{
  services.bird.settings = {
    define = {
      OWNED = [ (bird.prefix owned) ];
      C_STANDARD = bird.tuple [ 65000 100 ];
      C_LARGE = bird.tuple [ 65000 100 1 ];
      C_EXTENDED = bird.ec [ "rt" 65000 100 ];
      C_STALE = bird.tuple [ 65000 999 ];
      C_DUPLICATE = bird.tuple [ 65000 901 ];
    };
    function = {
      owns = {
        args = [{ name = "candidate"; type = "prefix"; }];
        return = "bool";
        body = ''
          return candidate ~ OWNED;
        '';
      };
      tag_origin = {
        args = [ ];
        body = ''
          bgp_community.add(C_STANDARD);
          bgp_large_community.add(C_LARGE);
          bgp_ext_community.add(C_EXTENDED);
          bgp_community.delete(C_STALE);
        '';
      };
      verified = {
        args = [ ];
        return = "bool";
        body = ''
          return (C_STANDARD ~ bgp_community)
            && (C_LARGE ~ bgp_large_community)
            && (C_EXTENDED ~ bgp_ext_community)
            && !(C_STALE ~ bgp_community)
            && (bgp_med = 42);
        '';
      };
    };
    filter = {
      export_owned.body = ''
        if proto = "originate4" && owns(net) then {
          tag_origin();
          bgp_med = 42;
          accept;
        }
        reject;
      '';
      import_verified.body = ''
        if verified() then {
          bgp_local_pref = 250;
          accept;
        }
        reject;
      '';
    };
  };
}
