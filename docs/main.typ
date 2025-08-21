// FIXME: text too dense
// spend more time on what nixos can bring?
// e.g. benifets of using nixos for routing
// the code is kinda useless with all the explanation?
// memory consumption of BIRD, maybe add why the global routing table is
// needed and when default routes is necessary
// figures?
// more background on routing basica?
// clarify how this talk is related to nix (very first slide?) up until p.10 its not like a nix talk
// bring page 7 to the top? be clear on what we want to achive with nix
// explain what bird is (background)
// add motivation for the first slide or second?
// comparison with ubuntu?
// why use nix for managing config? bird is text only
// add story, what is the debug chanllange, how i fixed it
// after motivation add challnge
// less implementation details?
// mention that options added are close to 1-1 match with bird official docs
//
// for challenges e.g. why not exporting routes directly to kernel
//
// 1. motivation
// 2. some info about networking (if necessary to introduce following challenges)
// 3. challenges
// 4. overview of solutions
// 5. solution 1
// 6. solution 2
// 7. ...
// 8. summary (can be the same as overview of solutions)
// kazuki says:1. motivation
// 2. some info about networking which are necessary to introduce challenges
// 3. challenges <<<<<<
// 4. some info about networking which are necessary to introduce solutions
// 5. overview of solutions
// 6. solution 1
// 7. solution 2
// 8. ...
// last slide. summary (can be the same as overview of solutions)
// motivation here is "want to use Nix as a templating engine for bird config"
// do it more adhoc? instead of dump background beforehand

#import "@preview/polylux:0.4.0": *

#let title = "Internet scale routing with NixOS"
#let author = "Yifei Sun"
#let date = datetime(year: 2025, month: 9, day: 6)
#let conference = "NixCon 2025"

#set document(title: title, author: author, date: date)

#set text(size: 20pt)
#set page(
  paper: "presentation-16-9", margin: 2cm, footer: context[
    #set text(size: 12pt)
    #set align(horizon)
    #if here().page() == 1 [
      #conference $dot.c$ #date.display("[month repr:long] [day padding:none], [year]")
    ] else if here().page() == counter(page).final().at(0) [
    ] else [
      #author $dot.c$ #conference $dot.c$ #date.display("[month repr:short]. [day padding:none], [year]")
      #h(1fr)
      #toolbox.slide-number / #toolbox.last-slide-number
    ]
  ],
)

#slide[
  = #title

  #v(1em)
  #set text(size: 20pt)

  Yifei Sun

  Inria, ENS de Lyon, Université Grenoble Alpes

  #box(image("inria.png", height: 11%))
  #h(1em)
  #box(move(dx: 0pt, dy: 15pt, image("ensl.png", height: 12.5%)))
  #h(1em)
  #box(move(dx: 0pt, dy: 9pt, image("uga.png", height: 11.5%)))
]

#slide[
  == Routing daemon

  Software that implements *routing protocols* to *exchange routing information*
  with other routers and *maintain routing tables*.

  #v(2em)

  *BIRD*: BIRD Internet Routing Daemon // recursive acronym
]

#slide[
== Problem

NixOS module option `services.bird.config` is text only

#v(2em)

#toolbox.side-by-side[
  - Maintenance burden
    - Hard to read
    - Hard to write
    - Hard to debug
    - Hard to maintain
  - Hard to compose and reuse
][
  #image("meme.png")
]
]

#slide[
  == Solution

  #set text(size: 28pt)
  #set align(center)
  #v(4em)
  *Parameteriziing BIRD configuration with NixOS options*
]

#slide[
  == Prerequisites

  - Nix and NixOS

  #v(1em)

  - Some netwoking knowledge
    - systemd-networkd #footnote[NixOS's default networking backend]
    - nftables #footnote[Linux Kernel packet classification framework]

  #v(1em)

  - BIRD
  - Tailscale #footnote[Open source mesh VPN software]
]

#slide[
  == Background

  #set text(size: 28pt)
  #set align(center)
  #v(3em)
  *How the internet works*

  #set text(size: 22pt)
  #v(2em)
  Resource acquisition

  Routing security

  Finding an upstream

  Pingable!
]

#slide[
  == Acquisition

  #toolbox.side-by-side[
    *ASN*: // unique identifier for each autonomous system (simply put, an AS is a network or a group of networks under a unified routing policy)
    - RIR direct assignment or LIR sponsorship
  ][
    *IP address*: // identifier for each network interface
    - Direct assignment
    - Lease/purchase from third-party
  ]

  #set align(center)
  #image("rir.jpg", width: 60%)
]

#slide[
  == Routing security

  #toolbox.side-by-side[
    *RPKI*: signed authorization objects hosted by registries

    #v(2em)

    *IRR*: database of routing policies, hosted by registries and other entities

    #v(2em)
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
      - Hurricane Electric
      - Cogent
      - Equinix
      - ...
  ][
    - Virtual presence at cloud provider that provide IP transit
      - Vultr, V.PS, Neptune Networks, etc.
      - https://bgp.services

    #v(3em)

    - Any VPS + virtual IX or transit providers
      - Cloudflare Magic Transit
      - https://bgp.exchange
      - https://route64.org
  ]
]

#slide[
  == Going live

  - Setting up BGP session
    - Get routes from upstream
      - Default route (0.0.0.0/0, ::/0)
      - Full table (usually not necessary)
        - BIRD: 250MB+ for \~1M IPv4 routes + \~230K IPv6 routes)
        - May be smaller or larger depending on routing daemon

  - Routing policies
    - Import/export
    - Filtering
    - ...

  - Add address within announced prefix to interface
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
services.bird.config = lib.mkOrder <int> ''
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
== Predefined filters

- Renamable ROA filters
- Can be referred later in import/export filters
- Have future improvements in mind

```nix
services.bird.config = lib.mkOrder <int> ''
  filter ${cfg.router.rpki.ipv4.filter} {
    if (roa_check(roa4, net, bgp_path.last) = ROA_INVALID) then {
      print "Ignore RPKI invalid ", net, " for ASN ", bgp_path.last;
      reject;
    }
    accept;
  }
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
== Immediate benefit

*Parametericity*

#set text(size: 18pt)
```nix
config = lib.mkIf
  (options?router
  &&
  lib.elem
    config.a.b.c.bind.v4
    config.services.router.local.ipv4.addresses
  &&
  lib.elem
    config.a.b.c.bind.v6
    config.services.router.local.ipv6.addresses)
  { ... };
```
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

- This is what GitHub Pages, Cloudflare, Google, and many other providers do

- Example
  #set text(size: 15pt)
  - https://github.com/search?q=repo%3Astepbrobd%2Fdotfiles%20personal%20site%20anycast&type=code
  - https://ysun.co
  - `curl -6 -I https://ysun.co`
]

#slide[
== Lessons learned

- NAT is not your friend
  - Use IPv6 if possible

- Debugging
  - All network operators should have public looking glass
    - `bird-lg` or other looking glass tools
    - Feed full table to BGP.Tools or NLNOG
  - `mtr`, `ping`, `traceroute`, `dig`, etc. are your friends
  - Tailscale is buggy
    - They eat the entirety of CGNAT address space (100.64.0.0/10)
    - `nodeAttrs` -> `ipPool` is half-baked, outstanding issue since Feb 2021
      (tailscale\#1381)
    - My workaround: set very specific priority in nftables
]

#slide[
== Closing remarks

- Possible to run your own validator (ROA based and IRR based)

- Plan to write a more generic module to replace `services.bird` and upstream it
  - Proof of concept: `github:stepbrobd/router#nixosModules.alpha`
  - Idea from: `github:NuschtOS/bird.nix`
  - Support all protocols
  - Integrate flow exporter for better observability
]

#slide[
  #set align(center + horizon)
  == Questions?

  #v(2em)

  Special thanks to Nick Cao (github.com/NickCao)

  #v(1fr)

  #box(image("france2030.png", height: 15%))
  #h(1em)
  #box(image("numpex.png", height: 15%))

  #box(image("cf_blk.png", width: 25%)) #h(0.25em) #text(size: 16pt, weight: "bold")[Project Alexandria]
]
