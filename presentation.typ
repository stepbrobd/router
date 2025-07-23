#import "@preview/polylux:0.4.0": *

#let title = "Internet scale routing with NixOS"
#let author = "Yifei Sun"
#let date = datetime(year: 2025, month: 9, day: 5)

#set document(title: title, author: author, date: date)

#set text(size: 20pt)
#set page(paper: "presentation-16-9", margin: 2cm, footer: [
  #set text(size: 12pt)
  #set align(horizon)
  #author #h(1fr) #toolbox.slide-number / #toolbox.last-slide-number
])

#slide[
  #set align(horizon)
  = Experience report:\ #title

  #date.display("[month repr:long] [day padding:none], [year]")
]

#slide[
  == Address assignment

  #toolbox.side-by-side[
    - DN42
    - 44NET from ARDC
    - Lease or purchase from a third party
  ][
    - Getting an assignment from RIR
      - APNIC
      - ARIN
      - RIPE NCC
      - LACNIC
      - AFRINIC
  ]
]

#slide[
  == Routing security

  - Setup
    - ROA
    - IRR objects
]

#slide[
  == Getting connected

  - Find an upstream
  - Physical presence at a data center
    - Equinix, Hurricane Electric, Cogent, etc.
  - Virtual presence at a cloud provider that provides IP transit
    - https://bgp.services
  - Any VPS + virtual IX or transit providers
    - https://route64.org
    - https://bgp.exchange
    - https://evix.org
]

#slide[
  == Overview

  - Setting up BGP session
    - Get routes from upstream
      - Default route
      - Full table (250MB+ for \~1M IPv4 routes + \~230K IPv6 routes)
  - Routing policies
    - Import/export
    - Filtering
    - ...
  - Add address(es) within announced prefix(es) to an interface
]

#slide[
  == Prerequisites

  - NixOS
    - systemd-networkd
    - nftables
  - Bird
  - Tailscale
]

#slide[
== Wrapping `services.bird`

- `services.bird.config` text config only
- Defaults to Bird 3
  - Since a couple months ago
  - Unstable
- Solution:
  - Use Nix as a templating engine
  - Bird 2
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
```

```nix
# config.services.bird.config
lib.concatMapStringsSep
  "\n  "
  (r: "route ${r.prefix} ${r.option};")
  cfg.router.static.ipv4.routes
```
]
]

#slide[
== eBPG sessions

#toolbox.side-by-side[
  - The usual: 1 session per protocol
  - MP-BGP: 1 session for both v4 and v6
][
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
]
]

#slide[
  == Adding announced prefixes to interfaces

]

#slide[
  == Multiple upstreams?

  - Internal routing
  - Tailscale
]

#slide[
  #set align(center + horizon)
  == Questions?

]
