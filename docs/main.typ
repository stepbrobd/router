#import "@preview/polylux:0.4.0": *

#let title = "Internet scale routing with NixOS"
#let author = "Yifei Sun"
#let date = datetime(year: 2025, month: 9, day: 5)

#set document(title: title, author: author, date: date)

#set text(size: 20pt)
#set page(paper: "presentation-16-9", margin: 2cm, footer: [
  #set text(size: 12pt)
  #set align(horizon)
  NixCon 2025 - #author
  #h(1fr)
  #toolbox.slide-number / #toolbox.last-slide-number
])

#slide[
  #set align(horizon)
  = Experience report:\ #title

  #date.display("[month repr:long] [day padding:none], [year]")
]

#slide[
  == Acquisition

  #toolbox.side-by-side[
    *ASN*:
    - DN42/experimental networks (reserved)
    - RIR direct assignment or LIR sponsorship
  ][
    *IP address*:
    - DN42/experimental networks (reserved)
    - ARDC 44NET (AR callsign required)
    - Lease/purchase from third-party
  ]

  #set align(center)
  #image("rir.jpg", width: 60%)
]

#slide[
  == Routing security

  #toolbox.side-by-side[
    *RPKI*: cryptographically signed authorization objects based on chain of trust
    hosted by registries

    *IRR*: database of routing policies, hosted by registries and other entities

    #v(3.25em)
    - Add object to new prefix
      - ROA (RPKI)
      - ROUTE/ROUTE6, AS-SET, etc. (IRR)
  ][
    *ROA*
    - Which AS can announce the prefix under some max length
    - Only registries can host ROAs
    - X.509 cert signed objects

    *IRR objects*
    - Mostly who can announce the prefix, who is customer, who is provider, etc.
    - Queryable
    - Aside from registries, known entities can also host IRR (NTT, RADB, etc.)
  ]
]

#slide[
  == Getting connected

  #toolbox.side-by-side[
    - Physical presence in datacenter
      - Cogent
      - Equinix
      - Hurricane Electric
      - ...
  ][
    - Virtual presence at cloud provider that provide IP transit
      - Vultr, V.PS, Neptune Networks, etc.
      - https://bgp.services

    #v(3em)

    - Any VPS + virtual IX or transit providers
      - https://bgp.exchange
      - https://evix.org
      - https://route64.org
  ]
]

#slide[
  == Going live

  - Setting up BGP session
    - Get routes from upstream
      - Default route (0.0.0.0/0, ::/0)
      - Full table
        - BIRD: 250MB+ for \~1M IPv4 routes + \~230K IPv6 routes)
        - May be smaller or larger depending on routing daemon

  - Routing policies
    - Import/export
    - Filtering
    - ...

  - Add address within announced prefix to interface
]

#slide[
  == Prerequisites

  - The Nix templating engine ;) and NixOS

  #v(1em)

  - Some netwoking knowledge
    - systemd-networkd
    - nftables

  #v(1em)

  - BIRD Internet Routing Daemon
  - Tailscale
]

#slide[
== Wrapping `services.bird`

- `services.bird.config` text config only
- Solution:
  - Use Nix as a templating engine
]

#slide[
== RPKI setup

#toolbox.side-by-side[
- Bird `rpki` protocol and `roa` table
- Delcaritive filter
- Defining `options.router.rpki`
  - v4/v6 table and filter names
  - retry, refresh, expire times
  - validators
][
```nix
router.rpki.validators = [{
  id = 0;
  remote = "rtr.rpki.cloudflare.com";
  port = 8282;
}];
```
]
]

#slide[
== RPKI setup

```nix
services.bird.config = ''
  ${lib.concatMapStringsSep
  "\n\n"
  (validator: ''
    protocol rpki rpki${lib.toString validator.id} {
      remote "${validator.remote}" port ${lib.toString validator.port};

      retry keep ${lib.toString cfg.router.rpki.retry};
      refresh keep ${lib.toString cfg.router.rpki.refresh};
      expire ${lib.toString cfg.router.rpki.expire};
    }'')
  cfg.router.rpki.validators}
'';
```
]

#slide[
== Kernel protocol

#toolbox.side-by-side[
  - Export full table to kernel
    - 250MB+ from Bird, and another copy in kernel
  - Don't export but manually add routes
    - Might break if upstream router have unusual configuration
][
```nix
options.router.kernel = {
  ipv4 = {
    import = lib.mkOption { ... };
    export = lib.mkOption { ... };
  };
  ipv6 = {
    import = lib.mkOption { ... };
    export = lib.mkOption { ... };
  };
};
```
]
]

#slide[
== Static routes

#toolbox.side-by-side[
- Manually configured routes

#set text(size: 15pt)
```nix
router.static = {
  ipv4.routes = [
    { prefix = "0.0.0.0/0"; option = "via 198.51.100.130"; }
    { prefix = "203.0.113.0/24"; option = "blackhole"; }
  ];
  ipv6.routes = [{ prefix = "2001:db8::/32"; option = "reject"; }];
};
```
][
#set text(size: 15pt)
```nix
options.router.static.ipv4.routes = lib.mkOption {
  type = lib.types.listOf (lib.types.submodule {
    options = {
      prefix = ...;
      option = ...;
    };
  });
};

# config.services.bird.config
lib.concatMapStringsSep
  "\n  "
  (r: "route ${r.prefix} ${r.option};")
  cfg.router.static.ipv4.routes
```
]
]

#slide[
== BPG sessions

#toolbox.side-by-side[
- The usual: 1 session per protocol
- MP-BGP: 1 session for both v4 and v6

#set text(size: 15pt)
```nix
options.router.sessions = lib.mkOption {
  type = lib.types.listOf (lib.types.submodule {
    options = {
      name = ...;
      type = ...; # disable, direct, multihop
      mp = ...; # null, v4 over v6, v6 over v4
      neighbor = ...; # ASN, IPv4, IPv6
      import = ...#; IPv4/IPv6 import filter
      export = ...#; IPv4/IPv6 export filter
      ...
    };
  });
};
```
][
#set text(size: 15pt)
```nix
# example
router.sessions = [{
  name = "bgptools";
  password = null;
  type = { ipv4 = "disabled"; ipv6 = "multihop"; };
  mp = "v4 over v6";
  neighbor = {
    asn = 212232;
    ipv4 = null;
    ipv6 = "2a0c:2f07:9459::b6";
  };
  import.ipv4 = "import none;";
  import.ipv6 = "import none;";
  export.ipv4 = "export all;";
  export.ipv6 = "export all;";
}];
```
]
]

#slide[
== Adding announced prefixes to interfaces

#toolbox.side-by-side[
- Enable forwarding
- Use `dummy` interface (or use the main interface or whatever)
- Disable `ManageForeignRoutes` in systemd-networkd (will delete routes exported
  by Bird)
][
#set text(size: 15pt)
```nix
  boot.kernelModules = [ "dummy" ];
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = 1;
    "net.ipv4.conf.default.forwarding" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.ipv6.conf.default.forwarding" = 1;
  };
  systemd.network.config.networkConfig.ManageForeignRoutes = false;
```
]
]

#slide[
== Adding announced prefixes to interfaces

#toolbox.side-by-side[
- Use `systemd.network.netdevs` to configure virtual interfaces
- Use `systemd.network.networks` to configure addresses and routing policies
  - `routingPolicyRules` is only needed when the outbound gateway of the announced
    prefixes is different from the default gateway of the main interface
][
#set text(size: 15pt)
```nix
  systemd.network.netdevs."40-dummy0".netdevConfig = {
    Kind = "dummy";
    Name = "dummy0";
  };

  systemd.network.networks."40-dummy0" = {
    name = "dummy0";
    address = ipv4.addresses ++ ipv6.addresses;
    routingPolicyRules = ...;
  };
```
]
]

#slide[
== Multiple upstreams?

#toolbox.side-by-side[
  - Internal routing
    - Usually with WireGuard, VxLAN, or other tunneling protocols
  - Tailscale
][
#set text(size: 15pt)
```nix
services.tailscale.extraSetFlags =
let
  v4s = lib.concatStringsSep "," ipv4.addresses;
  v6s = lib.concatStringsSep "," ipv6.addresses;
  addresses =
    if v4s == "" then v6s
    else if v6s == "" then v4s
    else v4s + "," + v6s;
in
[
  "--accept-routes"
  "--advertise-exit-node"
  "--advertise-routes=${addresses}"
  "--snat-subnet-routes=false"
  "--ssh"
];
```
]
]

#slide[
  == Anycast

  - Announce the same prefixes on multiple geographically distributed machines
  - Add the same address within the prefixes to multiple machines
  - Bind to the same address on multiple machines
  - Profit

  - This is what Cloudflare, BunnyCDN, Google, and many other providers do
]

#slide[
  == Closing remarks

  - Possible to run your own RPKI validator (ROA based and IRR based)
]

#slide[
  #set align(center + horizon)
  == Questions?

  #v(2em)

  Special thanks to Nick Cao (github.com/NickCao)
]
