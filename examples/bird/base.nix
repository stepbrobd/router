{ lib, ... }:
let
  bird = lib.router.bird;
in
{
  id = "192.0.2.10";
  includes = [ "/run/bird/example-credentials.conf" ];

  tables = {
    main4.type = "ipv4";
    main6.type = "ipv6";
  };

  defines = {
    OWNED4 = bird.prefixSet [ "203.0.113.0/24" ];
    OWNED6 = bird.prefixSet [ "2001:db8:100::/48" ];
    C_STANDARD = bird.community.standard 65000 100;
    C_LARGE = bird.community.large 65000 100 1;
    C_EXTENDED = bird.community.extended "rt" 65000 100;
  };
}
