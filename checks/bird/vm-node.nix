{ lib
, router
, self
, crossFamily
, nodeId
, owned
, forbidden
}:
{ config, pkgs, ... }:
let
  bird = router.bird;
  settings = config.services.bird.settings;
  peerId = 3 - nodeId;
  address = id: if crossFamily then "2001:db8:1::${toString id}" else "192.0.2.${toString id}";
  source = id: if crossFamily then "2001:db8:1::1${toString id}" else "192.0.2.1${toString id}";
  prefixLength = if crossFamily then "64" else "24";
  fixture = ../../examples/bird/credentials.example.conf;
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
        "${source nodeId}/${prefixLength}"
      ];
      DHCP = "no";
      IPv6AcceptRA = false;
      LinkLocalAddressing = "no";
    };
  };

  environment.etc."bird/credentials.conf".source = fixture;
  services.bird = {
    enable = true;
    package = pkgs.bird3;
    preCheckConfig = ''
      cp ${fixture} credentials.conf
    '';
    settings = {
      id = "192.0.2.${toString nodeId}";
      includes = [ "credentials.conf" ];
      tables = {
        main4.type = "ipv4";
      }
      // lib.optionalAttrs crossFamily { main6.type = "ipv6"; };
      protocols = {
        device0 = {
          type = "device";
          scanTime = 1;
        };
        connected = {
          type = "direct";
          interfaces = [ "eth1" ];
          checkLink = true;
          channels = {
            ipv4.table = settings.tables.main4.ref;
          }
          // lib.optionalAttrs crossFamily { ipv6.table = settings.tables.main6.ref; };
        };
        originate4 = {
          type = "static";
          channels.ipv4.table = settings.tables.main4.ref;
          routes =
            map
              (prefix: {
                inherit prefix;
                destination.type = "blackhole";
                body = [ (bird.stmt.addCommunities [ settings.defines.C_STALE.ref ]) ];
              })
              [
                owned
                forbidden
              ];
        };
        kernel4 = {
          type = "kernel";
          kernelTable = 200;
          scanTime = 1;
          metric = 32;
          channels.ipv4 = {
            table = settings.tables.main4.ref;
            import = "none";
            export.where = bird.expr.fromProtocol settings.protocols.peer.ref;
          };
        };
        peer = {
          type = "bgp";
          local.asn = 65000 + nodeId;
          neighbor = {
            asn = 65000 + peerId;
            address = source peerId;
          };
          sourceAddress = source nodeId;
          holdTime = 15;
          keepaliveTime = 5;
          password = bird.external {
            kind = "value";
            name = "EXAMPLE_PEER_PASSWORD";
            type = "string";
          };
          channels.ipv4 = {
            table = settings.tables.main4.ref;
            import = settings.filters.import_verified.ref;
            export = settings.filters.export_owned.ref;
            gateway = "direct";
            extendedNextHop = crossFamily;
            nextHopSelf = true;
            nextHopAddress = source nodeId;
          };
        };
      };
    };
  };
}
