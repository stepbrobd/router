{ pkgs
, lib
, router
, self
, crossFamily
}:
let
  source1 = if crossFamily then "2001:db8:1::11" else "192.0.2.11";
  source2 = if crossFamily then "2001:db8:1::12" else "192.0.2.12";
  node =
    args:
    import ./vm-node.nix (
      {
        inherit
          lib
          router
          self
          crossFamily
          ;
      }
      // args
    );
in
pkgs.testers.runNixOSTest {
  name = if crossFamily then "bird-ipv4-over-ipv6" else "bird-bgp";
  nodes = {
    sender = node {
      nodeId = 1;
      owned = "203.0.113.0/24";
      forbidden = "198.51.100.0/24";
    };
    receiver = node {
      nodeId = 2;
      owned = "198.18.0.0/24";
      forbidden = "198.19.0.0/24";
    };
  };
  testScript = ''
    import json

    start_all()
    roles = [
        (sender, "203.0.113.0/24", "198.51.100.0/24", "198.18.0.0/24", "198.19.0.0/24", "${source1}", "${source2}"),
        (receiver, "198.18.0.0/24", "198.19.0.0/24", "203.0.113.0/24", "198.51.100.0/24", "${source2}", "${source1}"),
    ]

    with subtest("authenticated BGP sessions establish with explicit source addresses"):
        for machine, _, _, remote, _, local, peer in roles:
            machine.wait_for_unit("bird.service")
            machine.wait_until_succeeds("birdc 'show protocols all peer' | grep -Eq 'BGP state:[[:space:]]+Established'")
            machine.wait_until_succeeds(f"birdc 'show route table main4 protocol peer' | grep -F '{remote}'")
            sockets = machine.succeed("ss -${
              if crossFamily then "6" else "4"
            }Htn state established '( sport = :179 or dport = :179 )'")
            assert local in sockets and peer in sockets, sockets
            ${lib.optionalString crossFamily ''
              assert machine.succeed("ip -4 -o address show dev eth1").strip() == ""
            ''}

    with subtest("interface patterns exclude eth9 before a wildcard match"):
        for machine, _, _, _, _, _, _ in roles:
            machine.wait_until_succeeds("birdc 'show route table pattern_control protocol pattern_probe' | grep -F '192.0.2.200/32'")
            connected = machine.succeed("birdc 'show route table main4 protocol connected'")
            assert "192.0.2.200/32" not in connected, connected

    with subtest("local static routes exist but export selects only owned prefixes"):
        for machine, owned, forbidden, remote, _, _, _ in roles:
            local_routes = machine.succeed("birdc 'show route table main4 protocol originate4 where (65000, 999) ~ bgp_community'")
            assert owned in local_routes and forbidden in local_routes, local_routes
            exported = machine.succeed("birdc 'show route export peer'")
            assert owned in exported, exported
            assert forbidden not in exported and remote not in exported, exported

    with subtest("static inheritance appends and retains duplicate prefix sources"):
        for machine, owned, _, _, _, _, _ in roles:
            inherited = machine.succeed(
                f"birdc 'show route table main4 all protocol originate4 where net = {owned} && (65000, 901) !~ bgp_community'"
            )
            appended = machine.succeed(
                f"birdc 'show route table main4 all protocol originate4 where net = {owned} && (65000, 901) ~ bgp_community'"
            )
            assert owned in inherited and owned in appended, (inherited, appended)

    with subtest("named functions mutate all three community types and import policy accepts them"):
        for machine, _, _, remote, remote_forbidden, _, _ in roles:
            received = machine.succeed(
                "birdc 'show route table main4 protocol peer where "
                "(65000, 100) ~ bgp_community && "
                "(65000, 100, 1) ~ bgp_large_community && "
                "(rt, 65000, 100) ~ bgp_ext_community && "
                "(65000, 999) !~ bgp_community && "
                "bgp_med = 42 && bgp_local_pref = 250'"
            )
            assert remote in received and remote_forbidden not in received, received
            rib = machine.succeed("birdc 'show route table main4 all'")
            assert remote_forbidden not in rib, rib

    with subtest("kernel receives exactly the allowed remote prefix with the negotiated next hop"):
        for machine, owned, forbidden, remote, remote_forbidden, _, peer in roles:
            machine.wait_until_succeeds(f"ip -4 route show table 200 exact {remote} | grep -F '{remote}'")
            routes = json.loads(machine.succeed("ip -4 -j route show table 200"))
            assert [route["dst"] for route in routes] == [remote], routes
            kernel = machine.succeed("ip -4 route show table 200")
            assert owned not in kernel and forbidden not in kernel and remote_forbidden not in kernel, kernel
            assert f"via ${lib.optionalString crossFamily "inet6 "}{peer} dev eth1" in kernel, kernel
  '';
}
