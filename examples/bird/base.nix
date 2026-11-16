{ lib, ... }:
let bird = lib.router.bird; in
{
  router-id = "192.0.2.10";
  include = [ "/run/bird/example-credentials.conf" ];

  ipv4.table.main4 = { };
  ipv6.table.main6 = { };

  define = {
    OWNED4 = [ (bird.prefix "203.0.113.0/24") ];
    OWNED6 = [ (bird.prefix "2001:db8:100::/48") ];
    C_STANDARD = bird.tuple [ 65000 100 ];
    C_LARGE = bird.tuple [ 65000 100 1 ];
    C_EXTENDED = bird.ec [ "rt" 65000 100 ];
  };
}
