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

  - Getting an assignment
    - From a Regional Internet Registry
      - APNIC
      - ARIN
      - RIPE NCC
      - LACNIC
      - AFRINIC
    - 44NET
    - DN42
    - Lease or purchase from a third party
]

#slide[
  == Routing security

  - Setup
    - RPKI Route Origin Authorization
      - Who's allowed to announce which prefix(es)?
    - Internet Routing Registry Objects
      - route/route6
      - as-set
      - aut-num
      - route-set
]

#slide[
  == Upstream

  - Finding an upstream
  - Physical presence at a data center
    - Equinix, Hurricane Electric, Cogent, etc.
  - Virtual presence at a cloud provider that provides IP transit
    - https://bgp.services
  - Any VPS + virtual transit providers
    - https://route64.org
    - https://bgp.exchange
    - https://evix.org
]

#slide[
  == Module system magic

  - Setting up BGP session(s)
    - How to get routes from upstream(s)?
      - Full table
      - Default route
  - Routing policies
    - Filtering
    - Community tagging
  - Add address(es) within announced prefix(es) to an interface
  - Multiple upstreams
    - Internal routing
  - Anycast?
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
== Bird NixOS module is bad

- `services.bird.config` text based config only
- The module defaults to Bird 3 since a couple months ago, and it's unstable
- Solution: use Nix as a templating engine
]

#slide[
== RPKI setup

- Bird `rpki` protocol and `roa` table
- Delcaritive filter

```nix
router.rpki.validators = [{
  id = 0;
  remote = "rtr.rpki.cloudflare.com";
  port = 8282;
}];
```

```nix
  services.bird.config = ''
    roa4 table ${cfg.router.rpki.ipv4.table};
    roa6 table ${cfg.router.rpki.ipv6.table};

    ${lib.concatMapStringsSep
    "\n\n"
    (validator: ''
      protocol rpki rpki${lib.toString validator.id} {
        roa4 { table ${cfg.router.rpki.ipv4.table}; };
        roa6 { table ${cfg.router.rpki.ipv6.table}; };

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

  - Export full table to kernel - 250MB+ from Bird, and another copy in kernel
  - Will break if upstream router have unusual configuration
]

#slide[
  == Multi-protocol BGP

  - usual: 1 session per protocol
  - MP-BGP: 1 session for all protocols
]

#slide[
  == Adding announced prefixes to interfaces
]

#slide[
  == Internal routing
]

#slide[
  #set align(center + horizon)
  == Questions?
]
