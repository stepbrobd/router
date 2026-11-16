{
  function = {
    is_owned4 = {
      args = [{ name = "candidate"; type = "prefix"; }];
      return = "bool";
      body = ''
        return candidate ~ OWNED4;
      '';
    };
    is_owned6 = {
      args = [{ name = "candidate"; type = "prefix"; }];
      return = "bool";
      body = ''
        return candidate ~ OWNED6;
      '';
    };
    tag_origin = {
      args = [ ];
      body = ''
        bgp_community.add(C_STANDARD);
        bgp_large_community.add(C_LARGE);
        bgp_ext_community.add(C_EXTENDED);
      '';
    };
  };

  filter = {
    export_owned4.body = ''
      if proto = "originate4" && is_owned4(net) then {
        tag_origin();
        accept;
      }
      reject;
    '';
    export_owned6.body = ''
      if proto = "originate6" && is_owned6(net) then {
        tag_origin();
        accept;
      }
      reject;
    '';
    import_peer4.body = ''
      if net ~ [ 198.51.100.0/24{24,28} ] then {
        bgp_local_pref = 150;
        accept;
      }
      reject;
    '';
  };
}
