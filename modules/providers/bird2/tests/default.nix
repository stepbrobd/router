# NixOS VM test for the Bird2 provider module
#
# spins up two hosts on a shared VLAN, each running Bird2 with OSPF v2/v3
# and static routes. verifies that OSPF propagates routes between hosts
# by checking for the remote host's static blackhole routes in the
# kernel routing table.

{ self, pkgs, std, router }:

let
  makeBirdHost = hostId: { pkgs, ... }: {
    imports = [ self.nixosModules.bird2 ];

    virtualisation.vlans = [ 1 ];
    environment.systemPackages = [ pkgs.jq ];

    networking = {
      useNetworkd = true;
      useDHCP = false;
      firewall.enable = false;
    };

    systemd.network.networks."01-eth1" = {
      name = "eth1";
      networkConfig.Address = "10.0.0.${hostId}/24";
    };

    services.bird2 = {
      enable = true;
      # build sandbox cannot run bird for config validation
      checkConfig = false;
      routing = {
        routerId = "10.0.0.${hostId}";
        asn = 65535;
        device.scanTime = 5;
        direct = {
          interfaces = [ "eth1" ];
        };
        kernel = {
          scanTime = 5;
          learn = true;
          ipv4 = {
            import.filter = null;
            export.filter = {
              rules = [{ action = router.policy.accept; }];
            };
          };
          ipv6 = {
            import.filter = null;
            export.filter = {
              rules = [{ action = router.policy.accept; }];
            };
          };
        };
        static = {
          ipv4.routes = [
            { prefix = "10.10.0.${hostId}/32"; action = router.route.blackhole; }
          ];
          ipv6.routes = [
            { prefix = "fdff::${hostId}/128"; action = router.route.blackhole; }
          ];
        };
        ospf.instances = {
          backbone = {
            version = router.ospf.v2;
            areas."0" = {
              interfaces.eth1 = {
                hello = 5;
                wait = 5;
              };
            };
            ipv4.export.filter = {
              rules = [{ action = router.policy.accept; }];
            };
          };
          backbone6 = {
            version = router.ospf.v3;
            areas."0" = {
              interfaces.eth1 = {
                hello = 5;
                wait = 5;
              };
            };
            ipv6.export.filter = {
              rules = [{ action = router.policy.accept; }];
            };
          };
        };
      };
    };
  };
in
pkgs.testers.nixosTest {
  name = "bird2-contract";

  nodes.host1 = makeBirdHost "1";
  nodes.host2 = makeBirdHost "2";

  testScript = ''
    start_all()

    host1.wait_for_unit("bird.service")
    host2.wait_for_unit("bird.service")

    # show generated config for debugging on failure
    host1.succeed("cat /etc/bird/bird.conf >&2")

    with subtest("Waiting for advertised IPv4 routes via OSPF"):
      host1.wait_until_succeeds("ip --json r | jq -e 'map(select(.dst == \"10.10.0.2\")) | any'")
      host2.wait_until_succeeds("ip --json r | jq -e 'map(select(.dst == \"10.10.0.1\")) | any'")

    with subtest("Waiting for advertised IPv6 routes via OSPF"):
      host1.wait_until_succeeds("ip --json -6 r | jq -e 'map(select(.dst == \"fdff::2\")) | any'")
      host2.wait_until_succeeds("ip --json -6 r | jq -e 'map(select(.dst == \"fdff::1\")) | any'")
  '';
}
