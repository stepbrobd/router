# NixOS Router

Router compiles routing daemons' source grammars into Nix configuration modules.
This project is only intended to generates configuration. Downstream NixOS
configurations still need to manage the routing daemon, package selection,
secrets, host networking, etc.

## BIRD

BIRD is currently the only supported routing daemon. The exported
`nixosModules.bird` adds `services.bird.settings` to the nixpkgs module. The
inventory is generated from BIRD's `thread-next` branch at the commit pinned in
`flake.lock`, and every setting of that commit can be written as attributes. The
flake's `packages.bird` builds nixpkgs' `bird3` from the same commit and matches
the inventory exactly:

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.router.nixosModules.bird ];

  services.bird = {
    enable = true;
    package = inputs.router.packages.${pkgs.stdenv.hostPlatform.system}.bird;
    settings = {
      router-id = "192.0.2.1";
      protocol.device.device0 = { };
    };
  };
}
```

Any BIRD 3 package works. A package built from another commit or release may
lack a setting the inventory has. With `checkConfig` on, the upstream module
runs the selected package's `bird -p` at build time, which rejects that setting.
With `checkConfig` off, the configuration fails when the daemon loads it.

Settings have one canonical path. Use dashed multiword directives such as
`router-id`, `hold-time` and `peer-table`, declaration namespaces such as
`protocol.bgp.peer`, and nested fields for real records or blocks. Keyword-path
aliases such as `hold.time` are rejected, which keeps separate spellings from
bypassing Nix module priorities. Only declared settings are emitted. Repeated
entries use ordered lists, and executable bodies use native BIRD text:

```nix
{
  function.owned = {
    args = [{ name = "candidate"; type = "prefix"; }];
    return = "bool";
    body = ''
      return candidate ~ [ 203.0.113.0/24 ];
    '';
  };
  filter.export_owned.body = ''
    if owned(net) then accept;
    reject;
  '';
  protocol.bgp.peer = {
    local.as = 65000;
    neighbor = { address = "192.0.2.2"; as = 65001; };
    hold-time = 30;
    ipv4 = {
      import = "none";
      export.filter = "export_owned";
    };
  };
}
```

Functions and filters are named records, with native BIRD code in `body`.
Function `args` is an ordered list of `{ name, type }` records, and `return`
sets the return annotation. Omitted or empty `args` emits the grammar's
zero-argument signature, `()`. Omitted `return` emits no return annotation.
Optional `variables = "int x;";` emits native declarations before the body
braces. Both `body` and `variables` compose with Nix lines merging, including
`mkBefore` and `mkAfter`. Target these fields rather than the declaration
record. Other scalar fields retain normal module conflicts and priorities.

Ordinary arguments are typed data, not whole BIRD clauses. Expected text values
are quoted automatically. In expression positions, a plain string means a string
literal. Use `bird.ip "192.0.2.1"`, `bird.prefix "203.0.113.0/24"`,
`bird.tuple [ 65000 100 ]` and `bird.ec [ "rt" 65000 100 ]` for other literal
types. Lists represent sets in constant positions. The `bird.symbol "NAME"`
constructor references a symbol, while `bird.expr "A_VALUE + 1"` explicitly
supplies native expression code. Native `where` and program-body fields remain
BIRD text. Inline filters use `import.filter.body = "accept;";`, while a string
assigned directly to `import.filter` names an existing filter. Duration
arguments use `{ value = 100; unit = "ms"; }`. A bare integer is allowed only
when that rule has a bare numeric production. Explicit constructors also
disambiguate slots that accept both text and IP addresses, such as a static
route's `via`. EVPN and L3VPN targets take `bird.ec` items with the arities BIRD
accepts: `bird.ec [ "rt" 65000 1 ]`, the range `bird.ec [ "rt" 65000 2 10 ]` and
the wildcard `bird.ec [ "rt" 65001 ]`.

A statement with several values takes a record named by the keyword before each
value. Values that no keyword names, such as the two thresholds of
`cork-threshold`, take a label from the `[[labels]]` table in
`registry/bird.toml`. A label names a value by its Bison position in one
production, and generation checks it against the C storage BIRD's action
assigns. A named entry with options after its name keeps them in its record:

```nix
{
  attribute = [{ type = "int"; name = "local_mark"; }];
  ipv4.table.main4.cork-threshold = { low = 1000; high = 2000; };
  protocol.ospf.ospf0 = {
    ecmp = { enabled = true; limit = 8; };
    area."0.0.0.1".virtual-link."192.0.2.9" = { instance = 1; hello = 5; };
  };
  protocol.pipe.mirror.export-in = { prefix = "192.0.2.0/24"; policy = "all"; };
}
```

Blocks of statements without keywords, such as OSPF `networks` and NBMA
`neighbors`, are ordered lists of records. A comma-separated repetition is a
list, as in an ASPA route's `providers`:

```nix
area."0.0.0.1" = {
  networks = [
    { prefix = "172.16.1.0/24"; }
    { prefix = "172.16.2.0/24"; hidden = true; }
  ];
  interface = [{
    pattern = "eth1";
    type = "nbma";
    neighbors = [
      { address = "192.168.120.1"; eligible = true; }
      { address = "192.168.120.2"; }
    ];
  }];
};
```

Interface statements and static routes are ordered records, including duplicate
route prefixes. Each outer interface record is a separate statement. Put an
exclusion and its wildcard in the same ordered `patterns` group:

```nix
interface = [{
  patterns = [
    { pattern = "eth9"; exclude = true; }
    { pattern = "eth*"; }
  ];
}];
```

An exclusion in one statement does not exclude matches in a later statement.

A static route's single next hop is `via` with its options beside it. Several
next hops are a `via` list of records, which BIRD reads as a multipath route:

```nix
route = [
  { prefix = "198.51.100.0/24"; via = bird.ip "192.0.2.2"; weight = 2; bfd = true; }
  {
    prefix = "203.0.113.0/24";
    via = [
      { address = bird.ip "192.0.2.2"; weight = 1; }
      { address = bird.ip "192.0.2.3"; weight = 3; onlink = true; }
    ];
  }
];
```

A flowspec prefix is a record under `flow4` or `flow6` whose components are
named by their keywords: `dst`, `src`, `proto`, `next-header`, `port`, `dport`,
`sport`, `icmp-type`, `icmp-code`, `length`, `dscp`, `label`, `tcp-flags` and
`fragment`. Prefix components are typed, and a flow6 prefix with an offset is
`{ prefix; offset; }`. Operator expressions are native BIRD text, given as a
string or as `body`, like function and filter bodies. BIRD orders the components
by type, which makes attribute order irrelevant:

```nix
route = [{
  prefix.flow4 = {
    dst = "10.0.0.0/8";
    proto = "= 6";
    dport.body = "> 24 && < 30";
    tcp-flags = "0x03/0x0f";
  };
}];
```

See [`examples/bird`](examples/bird) for complete data, policy and peer
examples. The [settings search](https://stepbrobd.github.io/router/) lists every
setting path under `services.bird.settings` with the value it expects, its entry
in BIRD's manual and its grammar line at the pinned commit.

Settings stay plain data while modules define them, which lets a module read
`config.services.bird.settings` to decide what else to set. Rendering into
`services.bird.config` validates them, and a failure names the setting, for
example
`protocol.bgp.peer.hold-time: invalid value, expected number-expression`.
Setting both structured `settings` and a different handwritten `config` is an
error. Leaving `settings` unset preserves the upstream handwritten configuration
path. Upstream `checkConfig` validates the consumed file with the selected BIRD
package.

An `include = [ "/run/bird/credentials.conf" ];` setting emits native includes
without reading their contents into the Nix store. Every braced block accepts
one, rendered first like at the root. Because BIRD expands an include at the
start of any line, `bird.include "/run/bird/password.conf"` also stands in for a
value or a list item, as in
`password = bird.include "/run/bird/password.conf";`. Runtime-only files cannot
be checked during a pure build. Use upstream `preCheckConfig` for build-time
fixtures or explicitly disable its check when those files are unavailable.

Standalone use shares the generated backend:

```nix
let
  bird = inputs.router.lib.router.bird;
in
{
  generated = bird.eval { modules = [ ./bird.nix ]; };
  checked = bird.check {
    inherit pkgs;
    package = inputs.router.packages.${pkgs.stdenv.hostPlatform.system}.bird;
    modules = [ ./bird.nix ];
  };
}
```

The `eval` function returns `{ config, text, resolved }`, and
`bird.resolve settings` exposes the same explicit inherited data view. A
structured `from = "parent";` may name a template or an existing protocol of the
same type. The view follows inheritance, preserves list order and keeps repeated
routes distinct. It does not add daemon defaults, evaluate native expressions or
read runtime includes. Use the view only for configurations that pass BIRD
validation.

Nix module contributions concatenate lists and retain `mkBefore`, `mkAfter` and
`mkForce`. BIRD `from` inheritance is a separate operation. Repeated statements
such as static routes append, while a complete list-valued argument such as BGP
`interface-range` replaces the inherited value. Source copy hooks can reset
collections, as BFD does for interfaces and neighbors.

Root declarations render in the order `declaration_order` in
`registry/bird.toml` sets: includes, then definitions and attributes, then other
settings, then functions, filters, templates and protocols. Known `from`
references order protocols and templates among themselves. For opaque
dependencies inside native bodies, pass ordered declaration groups, such as
`bird.render [ definitions functions filters protocols ]`. Block bodies can also
use ordered groups. Explicit list order is preserved. BIRD owns semantic
validation, including expression types, ranges, symbol classes and postconfig
checks.

## Grammar compiler

The Rust CLI takes a BIRD source directory:

```sh
router inspect /path/to/bird
router generate /path/to/bird --output generated/bird
router options /path/to/bird --prefix services.bird.settings \
  --source-url https://github.com/cz-nic/bird/blob/REV/
```

The `generate` command writes `generated/bird/grammar.json`, the grammar
inventory. The Nix runtime in `lib/router/bird` interprets it, and the NixOS
module there is what `nixosModules.bird` imports. The checked-in inventory
follows the `bird` input in `flake.lock`, BIRD's `thread-next` branch. Grammar
productions remain available through their exact production form,
`{ _rule; _production; _args; }`.

The `options` command prints a NixOS-style `options.json` with one entry per
setting path under `--prefix`, described from `doc/bird.sgml` and linked to its
production under `--source-url`. A scope shared by several paths, such as a
template's block or a second channel of one protocol, is listed once and the
other paths point there. The flake's `packages.site` serves it at the site root
with [NuschtOS Search](https://github.com/NuschtOS/search), beside the NixCon
slides, and `.github/workflows/pages.yaml` publishes the site from `master`.
Each module is one entry of the search's `scopes` list in
`modules/flake/site.nix`, given as an `options.json` or as the module itself,
and a second entry adds a scope picker to the page.

Generation fails when a setting form cannot be written as attributes, and names
each such form with its BIRD source location. The `inspect` command lists the
same forms in `registry.diagnostics.unaddressable`. The weekly bump regenerates
the inventory, which means a BIRD commit that adds such a form fails the bump
until the registry names its values.

The registry, `registry/bird.toml`, holds the stable public type and field
identities, source aliases, value labels, projection hints and declaration
order, grouped by table kind. Syntax, delimiters, alternatives and repetition
still come from the inspected grammar. Required bindings fail when their source
match is missing, ambiguous or incompatible.

Keep a binding's `id` stable when upstream renames its rule, and update its
`rules` aliases and source checks in this file. Readable field names belong in
the same registry, not in protocol-specific Nix renderers.

Recorded source hashes prevent a stale generated inventory from being used with
a changed validator source. The `bird-generation` check regenerates the
inventory from the pinned input and compares it with the checked-in file.

Use `nix develop` for Rust and grammar tools, `cargo nextest run` for the Rust
tests, `nix build` for the compiler, and `nix fmt` for the conventional checks
and formatting. Autopilot still discovers the library, packages and modules.

## License

This work is an extension of NixCon 2025 talk
["Internet scale routing with NixOS"](https://talks.nixcon.org/nixcon-2025/talk/7YWTUC/).

<p>
  Sponsored under
  <a href="https://www.cloudflare.com/lp/project-alexandria/" style="display: inline-flex; align-items: center; gap: 0.5em; text-decoration: none;">
    <picture>
      <source media="(prefers-color-scheme: light)" srcset="https://github.com/stepbrobd/router/blob/master/docs/cf_blk.png">
      <source media="(prefers-color-scheme: dark)" srcset="https://github.com/stepbrobd/router/blob/master/docs/cf_wht.png">
      <img src="https://github.com/stepbrobd/router/blob/master/docs/cf_blk.png" width="192" alt="Cloudflare">
    </picture>
    <span>Project Alexandria</span>
  </a>
  .
</p>

The compiler and Nix runtime are licensed under the [MIT License](license.txt).
The generated inventory records the provenance of the BIRD grammar and semantic
declarations, which are derived from GPL-2.0-or-later upstream source.
