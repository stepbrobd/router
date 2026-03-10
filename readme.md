# Internet scale routing with NixOS

This is mostly derived from my NixCon 2025 talk with
[RFC 0189](https://github.com/nixos/rfcs/pull/189) twist.

- Details: <https://talks.nixcon.org/nixcon-2025/talk/7YWTUC/>

- Archive: <https://youtu.be/ebZJLKc80oE>

## Summary

Introduce a `contracts.routing` contract following the NixOS RFC 0189 pattern to
decouple routing protocol configuration from routing daemon implementation. The
contract defines fully typed Nix options for 14 standard routing protocols. A
Bird2 provider compiles these typed inputs into `bird.conf`. No raw config
strings in the contract layer -- the provider is the only place where
daemon-specific syntax exists.

## Architecture

### Actors

```
Consumer           Contract                Provider
(host config) --> contracts.routing --> (Bird2 compiler)
     |               |    ^                   |
     |          typed inputs               bird.conf
     |               |    |                   |
     +-- reads output (all inputs mirrored) --+
```

Four roles per RFC 0189:

1. **Contract team** -- maintains `contracts.routing` (types, behavior tests)
2. **Provider team** -- maintains Bird2 provider (compiler, systemd unit)
3. **Consumer team** -- maintains modules that need routing (currently just the
   host config)
4. **End user** -- wires consumer to provider, sets provider-specific options

### File layout

```
lib/
  router.nix                 # lib.router constants + custom types
modules/
  contracts/
    routing/
      default.nix            # contract definition (input/output)
      types/
        common.nix           # shared: blockOptions, prefix list, address family
        filter.nix           # filter/policy language types
        bgp.nix              # BGP session type
        ospf.nix             # OSPF instance type
        rip.nix              # RIP instance type
        babel.nix            # Babel instance type
        radv.nix             # RAdv instance type
        rpki.nix             # RPKI validator type
        bfd.nix              # BFD session type
        bmp.nix              # BMP station type
        mrt.nix              # MRT dump type
        static.nix           # static route type
        aggregator.nix       # route aggregation type
        device.nix           # interface discovery type
        direct.nix           # connected routes type
        kernel.nix           # kernel FIB sync type
  providers/
    bird2/
      default.nix            # Bird2 provider module (wiring + systemd)
      compiler.nix           # top-level compiler: typed inputs -> bird.conf
      compiler/
        bgp.nix
        ospf.nix
        rip.nix
        babel.nix
        radv.nix
        rpki.nix
        bfd.nix
        bmp.nix
        mrt.nix
        static.nix
        aggregator.nix
        device.nix
        direct.nix
        kernel.nix
        filter.nix           # filter AST -> Bird2 filter syntax
      tests/
        default.nix          # NixOS VM behavior tests
```

### Module injection via importApply

All modules receive `std` (builtins // nixpkgs.lib) and `router` (constants +
types) via `importApply`:

```nix
# flake.nix
let
  std = builtins // nixpkgs.lib;
  router = import ./lib/router.nix { inherit std; };
in
{
  nixosModules.default = std.modules.importApply ./modules {
    inherit std router;
  };
}
```

Module files:

```nix
{ std, router, ... }:   # injected by importApply
{ config, pkgs, ... }:  # standard NixOS module args
{ ... }
```

## `lib.router` namespace

Semantic constants replacing string enums. Provides tab completion in nix-repl
and type safety.

```nix
# lib/router.nix
{ std, ... }:
{
  # -- constants --

  peering = {
    disabled  = { type = "disabled"; };
    direct    = { type = "direct"; };
    multihop  = { type = "multihop"; };
  };

  policy = {
    accept = { decision = "accept"; };
    reject = { decision = "reject"; };
  };

  roa = {
    valid    = { status = "valid"; };
    invalid  = { status = "invalid"; };
    unknown  = { status = "unknown"; };
    notFound = { status = "not-found"; };
  };

  addPaths = {
    off    = { mode = "off"; };
    rx     = { mode = "rx"; };
    tx     = { mode = "tx"; };
    switch = { mode = "switch"; };
  };

  route = {
    blackhole   = { action = "blackhole"; };
    unreachable = { action = "unreachable"; };
    prohibit    = { action = "prohibit"; };
    via         = addr: { action = "via"; gateway = addr; };
  };

  multiprotocol = {
    v4overV6 = { mode = "v4-over-v6"; };
    v6overV4 = { mode = "v6-over-v4"; };
  };

  ospf = {
    v2 = { version = "v2"; };
    v3 = { version = "v3"; };
  };

  area = {
    normal = { type = "normal"; };
    stub   = { type = "stub"; };
    nssa   = { type = "nssa"; };
  };

  cmp = {
    eq = { op = "="; };
    ne = { op = "!="; };
    lt = { op = "<"; };
    gt = { op = ">"; };
    le = { op = "<="; };
    ge = { op = ">="; };
  };

  af = {
    ipv4 = { family = "ipv4"; };
    ipv6 = { family = "ipv6"; };
  };

  babel = {
    wired    = { type = "wired"; };
    wireless = { type = "wireless"; };
  };

  bmp = {
    prePolicy  = { mode = "pre-policy"; };
    postPolicy = { mode = "post-policy"; };
  };

  # -- custom option types --

  types = {
    # helper: create an option type that validates an attrset has
    # a specific key with a value from an allowed set
    mkEnumAttrType = name: attrName: validValues:
      std.types.mkOptionType {
        inherit name;
        description = "${name} (one of: ${std.concatStringsSep ", " validValues})";
        check = v: std.isAttrs v && v ? ${attrName}
          && std.elem v.${attrName} validValues;
        merge = std.options.mergeEqualOption;
      };

    peeringType     = /* mkEnumAttrType "peeringType" "type" [...] */;
    policyType      = /* mkEnumAttrType "policyDecision" "decision" [...] */;
    roaStatusType   = /* mkEnumAttrType "roaStatus" "status" [...] */;
    addPathsType    = /* mkEnumAttrType "addPathsMode" "mode" [...] */;
    routeActionType = /* mkEnumAttrType "routeAction" "action" [...] */;
    cmpType         = /* mkEnumAttrType "cmpOp" "op" [...] */;
    # submodule types for protocols
    filterType      = /* std.types.submodule { ... } */;
    bgpSessionType  = /* std.types.submodule { ... } */;
    ospfInstanceType = /* std.types.submodule { ... } */;
    # ... one per protocol
  };
}
```

## Contract definition

### Input options

All protocol options default to empty/disabled. Consumer only populates what it
needs. Every protocol block inherits `blockOptions` (order, extraConfigBefore,
extraConfigAfter).

```nix
# modules/contracts/routing/default.nix
contracts.routing = {
  input = { config, ... }: {
    options = {
      routerId = std.mkOption { type = std.types.str; };
      asn = std.mkOption { type = std.types.int; };
      source = {
        ipv4 = std.mkOption { type = std.types.nullOr std.types.str; default = null; };
        ipv6 = std.mkOption { type = std.types.nullOr std.types.str; default = null; };
      };

      prefixLists = std.mkOption {
        type = std.types.attrsOf router.types.prefixListType;
        default = {};
      };

      bgp.sessions = std.mkOption {
        type = std.types.attrsOf router.types.bgpSessionType;
        default = {};
      };
      ospf.instances = std.mkOption {
        type = std.types.attrsOf router.types.ospfInstanceType;
        default = {};
      };
      rip.instances = std.mkOption {
        type = std.types.attrsOf router.types.ripInstanceType;
        default = {};
      };
      babel.instances = std.mkOption {
        type = std.types.attrsOf router.types.babelInstanceType;
        default = {};
      };
      radv.instances = std.mkOption {
        type = std.types.attrsOf router.types.radvInstanceType;
        default = {};
      };
      rpki = std.mkOption {
        type = router.types.rpkiType;
        default = {};
      };
      bfd.sessions = std.mkOption {
        type = std.types.attrsOf router.types.bfdSessionType;
        default = {};
      };
      bmp.stations = std.mkOption {
        type = std.types.attrsOf router.types.bmpStationType;
        default = {};
      };
      mrt.dumps = std.mkOption {
        type = std.types.attrsOf router.types.mrtDumpType;
        default = {};
      };
      static = std.mkOption {
        type = router.types.staticType;
        default = {};
      };
      aggregator.instances = std.mkOption {
        type = std.types.attrsOf router.types.aggregatorType;
        default = {};
      };
      device = std.mkOption {
        type = router.types.deviceType;
        default = {};
      };
      direct = std.mkOption {
        type = router.types.directType;
        default = {};
      };
      kernel = std.mkOption {
        type = router.types.kernelType;
        default = {};
      };
    };
  };

  output = { ... }: {
    # all input options mirrored as read-only
    # downstream modules (nftables, tailscale, prometheus) consume these
  };

  behaviorTest = { /* NixOS VM test */ };
};
```

### Output options

All user-specified inputs are exposed back as read-only outputs. This allows
downstream modules to reference routing data without depending on the provider.

Example downstream usage:

```nix
let
  announced = config.services.bird2.routing.output;
in
{
  networking.nftables.tables.outbound4.content = ''
    chain postrouting {
      type nat hook postrouting priority srcnat; policy accept;
      ip saddr { ${std.concatMapStringsSep ", " (r: r.prefix) announced.static.ipv4.routes} } oifname "eth0" masquerade
    }
  '';

  services.tailscale.extraSetFlags =
    let
      v4 = map (r: r.prefix) announced.static.ipv4.routes;
      v6 = map (r: r.prefix) announced.static.ipv6.routes;
    in
    [ "--advertise-routes=${std.concatStringsSep "," (v4 ++ v6)}" ];
}
```

## Block ordering

Numeric priority via `mkOrder`. Default ordering encodes Bird2's dependency
requirements:

| Priority | Category                | Rationale                                                |
| -------- | ----------------------- | -------------------------------------------------------- |
| 10       | ROA table declarations  | Must exist before filters reference them                 |
| 20       | RPKI protocol instances | Populate the ROA tables                                  |
| 30       | Device protocol         | Must discover interfaces before other protocols use them |
| 40       | Direct protocol         | Connected routes depend on device                        |
| 50       | Kernel protocol         | FIB sync                                                 |
| 60       | Static routes           |                                                          |
| 70       | Aggregator              | Operates on existing routes                              |
| 80       | BFD                     | Must be ready before BGP sessions reference it           |
| 90       | OSPF, RIP, Babel, RAdv  | IGP protocols                                            |
| 100      | BGP                     | EGP sessions                                             |
| 110      | BMP, MRT                | Monitoring/dump protocols                                |

Users override with `order` on any block. The Bird2 compiler collects all
blocks, sorts by order, joins with newlines.

## Injection points

Every block supports:

- `extraConfigBefore`: raw string prepended before the block (e.g.,
  `include "/run/secrets/bgp-passwords"`)
- `extraConfigAfter`: raw string appended after the block

The Bird2 provider module also has a top-level `extraConfig` for content that
doesn't belong to any specific block.

## Filter/policy language

Filters are inline values of `filterType`, not named references. Users compose
them with standard Nix (`let`/`in`, functions, `//`).

### Filter type structure

A filter is a list of ordered rules. Each rule has a match condition (AND of all
non-null fields) and an action.

**Match conditions:**

| Field           | Type              | Bird2 compilation                              |
| --------------- | ----------------- | ---------------------------------------------- |
| `roaStatus`     | `router.roa.*`    | `roa_check(table, net, bgp_path.last) = ROA_*` |
| `prefixIn`      | `prefixListType`  | `net ~ [ prefix/len+, ... ]`                   |
| `bgpAsn`        | `int`             | `bgp_path.last = ASN`                          |
| `bgpPathLength` | `{ op; value; }`  | `bgp_path.len OP VALUE`                        |
| `communityHas`  | `{ asn; value; }` | `(ASN, VALUE) ~ bgp_community`                 |

Empty match (all fields null) means match all -- used for default rules.

**Actions:**

| Field             | Type              | Bird2 compilation                             |
| ----------------- | ----------------- | --------------------------------------------- |
| `decision`        | `router.policy.*` | `accept;` / `reject;`                         |
| `setLocalPref`    | `int`             | `bgp_local_pref = VALUE;`                     |
| `setMed`          | `int`             | `bgp_med = VALUE;`                            |
| `prependPath`     | `{ asn; count; }` | `bgp_path.prepend(ASN);` repeated count times |
| `addCommunity`    | `{ asn; value; }` | `bgp_community.add((ASN, VALUE));`            |
| `deleteCommunity` | `{ asn; value; }` | `bgp_community.delete((ASN, VALUE));`         |

Multiple action fields can be set on one rule (e.g., set local pref AND accept).
The compiler emits them in order.

### Usage example

```nix
let
  inherit (lib) router;

  mkRpkiFilter = bogons: {
    rules = [
      { match.roaStatus = router.roa.invalid; action = router.policy.reject; }
      { match.prefixIn = bogons; action = router.policy.reject; }
      { action = router.policy.accept; }
    ];
  };

  bogons4 = {
    prefixes = [
      { prefix = "0.0.0.0/8"; le = 32; }
      { prefix = "10.0.0.0/8"; le = 32; }
      { prefix = "127.0.0.0/8"; le = 32; }
    ];
  };
in
{
  routing.bgp.sessions.upstream1.ipv4.import.filter = mkRpkiFilter bogons4;
}
```

Bird2 compiler output:

```
protocol bgp upstream1_ipv4 {
  ...
  ipv4 {
    import filter {
      if (roa_check(roa4, net, bgp_path.last) = ROA_INVALID) then { reject; }
      if (net ~ [ 0.0.0.0/8+, 10.0.0.0/8+, 127.0.0.0/8+ ]) then { reject; }
      accept;
    };
    ...
  };
}
```

## Bird2 provider

### Compiler

Pure function: contract input attrset -> `bird.conf` string.

- `compiler.nix`: top-level orchestrator. Collects all protocol compilers, sorts
  blocks by order, concatenates.
- `compiler/<protocol>.nix`: each returns `{ order = int; text = string; }` or a
  list thereof.
- `compiler/filter.nix`: translates filter AST to Bird2 filter body syntax.

The compiler handles Bird2-specific decisions:

- Splitting BGP sessions into separate v4/v6 protocol blocks
- Deriving ROA table declarations from RPKI config
- Mapping `router.peering.direct` to Bird2's `direct;` keyword
- Mapping `router.peering.multihop` to Bird2's `multihop;` keyword
- Generating `protocol device`, `protocol direct`, `protocol kernel` blocks

### Provider-specific options

Options outside the contract, set directly on the Bird2 provider by the end
user:

- `pipe`: Bird2 inter-table routing (attrsOf pipe config)
- `l3vpn`: Bird2 MPLS L3VPN config (attrsOf l3vpn config)
- `extraConfig`: raw string appended to the generated config

### Systemd unit

Equivalent to current module:

- `Type = "forking"`
- Capabilities: `CAP_NET_ADMIN`, `CAP_NET_BIND_SERVICE`, `CAP_NET_RAW`
- `ExecStart = bird -c /etc/bird/bird.conf`
- `ExecReload = birdc configure`
- Auto-reload on config change via `reloadTriggers`
- Hardened: `ProtectSystem`, `ProtectHome`, `PrivateTmp`,
  `MemoryDenyWriteExecute`

## Protocol split

| Protocol   | In contract?  | Rationale                                                         |
| ---------- | ------------- | ----------------------------------------------------------------- |
| BGP        | Yes           | RFC 4271, universal                                               |
| OSPF       | Yes           | RFC 2328/5340, universal                                          |
| RIP        | Yes           | RFC 2453, universal                                               |
| Babel      | Yes           | RFC 8966, universal                                               |
| RAdv       | Yes           | RFC 4861, universal                                               |
| RPKI       | Yes           | RFC 6810, universal                                               |
| BFD        | Yes           | RFC 5880, universal                                               |
| BMP        | Yes           | RFC 7854, universal                                               |
| MRT        | Yes           | RFC 6396, universal                                               |
| Static     | Yes           | Every daemon supports static routes                               |
| Aggregator | Yes           | Route summarization is a standard concept                         |
| Device     | Yes           | Interface discovery (explicit in Bird2, implicit in FRR/OpenBGPD) |
| Direct     | Yes           | Connected route generation, universal concept                     |
| Kernel     | Yes           | Kernel FIB sync, universal concept                                |
| Pipe       | No (provider) | Bird2-specific inter-table routing                                |
| L3VPN      | No (provider) | Maturity varies too much across daemons                           |

## Behavior tests

NixOS VM tests following the NuschtOS/bird.nix pattern:

1. Two hosts on a shared VLAN
2. Each runs the Bird2 provider with contract config (static routes, OSPF, BGP)
3. Verify route propagation via `ip --json r | jq`
4. Verify BGP session establishment via `birdc show protocols`
5. Verify RPKI table population (when validators are reachable)

The test is generic on the provider -- parameterized so future FRR/OpenBGPD
providers run the same assertions.

## End-user wiring

```nix
{
  # consumer: declare routing intent
  routing = {
    routerId = "198.51.100.10";
    asn = 65535;
    # ... protocols ...
  };

  # wire consumer to bird2 provider
  services.bird2.routing = {
    consumer = config.routing;
    # provider-specific
    extraConfig = "";
  };
}
```

## Scope exclusions

The following remain separate modules that consume contract outputs:

- systemd-networkd / dummy interface setup
- nftables SNAT rules
- Tailscale advertised routes / exit node config
- Prometheus bird exporter
- IP forwarding sysctl settings

## Unresolved questions

1. **Dual-link**: RFC 0189 requires linking consumer-to-provider and
   provider-to-consumer. Whether we can simplify to single-direction depends on
   module system experiments.
2. **Filter completeness**: The initial filter language covers the common 80% of
   BGP policy. Advanced Bird2 filter features (variables, functions, custom
   attributes) may need an `extraFilter` escape hatch or future type extensions.
3. **OSPF interface options**: OSPF has many per-interface knobs (cost,
   priority, authentication, network type). Initial implementation covers the
   common ones; extend as needed.
4. **Behavior test scope**: Which protocols to test in the initial VM test.
   BGP + OSPF + static route propagation is the minimum viable set.

## License

Licensed under the [MIT License](license.txt).
