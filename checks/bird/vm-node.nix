{ lib
, router
, self
, crossFamily
, nodeId
, owned
, forbidden
}:
{ pkgs, config, ... }:
let
  bird = router.bird;
  peerId = 3 - nodeId;
  address = id: if crossFamily then "2001:db8:1::${toString id}" else "192.0.2.${toString id}";
  source = id: if crossFamily then "2001:db8:1::1${toString id}" else "192.0.2.1${toString id}";
  prefixLength = if crossFamily then "64" else "24";
  fixture = ../../examples/bird/credentials.example.conf;
  resolved = bird.resolve config.services.bird.settings;
in
{
  imports = [
    self.nixosModules.bird
    (import ./vm-policy.nix { inherit router owned; })
  ];

  virtualisation.vlans = [ 1 ];
  networking = {
    useNetworkd = true;
    useDHCP = false;
    firewall.enable = false;
  };
  systemd.network.networks."01-eth1" = {
    name = "eth1";
    networkConfig = {
      Address = [
        "${address nodeId}/${prefixLength}"
        "${resolved.protocol.bgp.peer.source-address}/${prefixLength}"
      ];
      DHCP = "no";
      IPv6AcceptRA = false;
      LinkLocalAddressing = "no";
    };
  };
  systemd.network.netdevs."02-eth9".netdevConfig = { Name = "eth9"; Kind = "dummy"; };
  systemd.network.networks."02-eth9" = {
    name = "eth9";
    networkConfig = {
      Address = [ "192.0.2.200/32" ];
      DHCP = "no";
      IPv6AcceptRA = false;
      LinkLocalAddressing = "no";
    };
  };

  environment.etc."bird/credentials.conf".source = fixture;
  services.bird = {
    enable = true;
    package = self.packages.${pkgs.stdenv.hostPlatform.system}.bird;
    preCheckConfig = ''
      cp ${fixture} credentials.conf
    '';
    settings = {
      router-id = "192.0.2.${toString nodeId}";
      include = [ "credentials.conf" ];
      ipv4.table.main4 = { };
      ipv4.table.pattern_control = { };
      filter.import_verified.body = lib.mkBefore "bgp_local_pref = 1;";
      template.bgp = {
        z_transport = {
          local.as = 65000 + nodeId;
          source-address = address nodeId;
          direct = true;
          hold-time = 15;
          keepalive-time = 5;
          ipv4 = {
            table = "main4";
            import = "none";
            export = "none";
            gateway = "direct";
            extended-next-hop = crossFamily;
            next-hop-self = true;
            next-hop-address = source nodeId;
          };
        };
        a_policy = {
          from = "z_transport";
          password = bird.symbol "EXAMPLE_PEER_PASSWORD";
          ipv4.export.filter = "export_owned";
        };
      };
      template.static.origin_base = {
        ipv4.table = "main4";
        route = [{ prefix = owned; blackhole = true; body = "bgp_community.add(C_STALE);"; }];
      };
      protocol = {
        device.device0.scan-time = 1;
        direct.connected = {
          interface = [{
            patterns = [
              { pattern = "eth9"; exclude = true; }
              { pattern = "eth*"; }
            ];
          }];
          check-link = true;
          ipv4.table = "main4";
        } // lib.optionalAttrs crossFamily { ipv6.table = "main6"; };
        direct.pattern_probe = {
          interface = [{ pattern = "eth9"; }];
          ipv4.table = "pattern_control";
        };
        static.originate4 = {
          from = "origin_base";
          route = [
            { prefix = forbidden; blackhole = true; body = "bgp_community.add(C_STALE);"; }
            { prefix = owned; blackhole = true; body = "bgp_community.add(C_STALE); bgp_community.add(C_DUPLICATE);"; }
          ];
        };
        kernel.kernel4 = {
          kernel-table = 200;
          scan-time = 1;
          metric = 32;
          ipv4 = {
            table = "main4";
            import = "none";
            export.where = ''proto = "peer"'';
          };
        };
        bgp.peer = {
          from = "a_policy";
          local.address = source nodeId;
          neighbor = { address = source peerId; as = 65000 + peerId; };
          ipv4.import.filter = "import_verified";
        };
      };
    } // lib.optionalAttrs crossFamily { ipv6.table.main6 = { }; };
  };
}
