# NixOS Router

NixOS Router compiles the source grammar of a routing daemon into a NixOS
module. It generates configuration and leaves the daemon, its package, secrets
and host networking to the downstream NixOS configuration.

## BIRD

BIRD is currently the only supported routing daemon. The exported
`nixosModules.bird` adds `services.bird.settings`. In theory any BIRD 3 release
should work, though a package built from another commit or release may lack a
setting the generated options contain. Enabling `services.bird.checkConfig`, the
upstream default, is recommended, since it runs `bird -p` on the generated
configuration at build time.

```nix
{ inputs, ... }:

{
  imports = [ inputs.router.nixosModules.bird ];

  services.bird = {
    enable = true;
    settings = {
      router-id = "192.0.2.1";
      protocol.device.device0 = { };
    };
  };
}
```

Each setting has one path. Multiword directives are dashed, as in `router-id`,
`hold-time` and `peer-table`, declarations are namespaced, as in
`protocol.bgp.peer`, and records and blocks nest. Keyword paths such as
`hold.time` are rejected, because a second spelling would bypass module
priorities. Repeated entries are ordered lists, and executable bodies are native
BIRD text:

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

Functions and filters are named records with native BIRD code in `body`. A
function's `args` is an ordered list of `{ name, type }` records, empty or
omitted for `()`, and `return` sets the return type. An optional
`variables = "int x;";` declares locals before the body braces. The `body` and
`variables` fields merge as Nix lines, and `mkBefore` and `mkAfter` belong on
them rather than on the declaration record. Other scalar fields keep ordinary
module priorities and conflicts.

Arguments are typed data rather than BIRD clauses. Text values are quoted
automatically, and a plain string in an expression position is a string literal.
Other literals take constructors: `bird.ip "192.0.2.1"`,
`bird.prefix "203.0.113.0/24"`, `bird.tuple [ 65000 100 ]` and
`bird.ec [ "rt" 65000 100 ]`. They also disambiguate slots that accept both text
and addresses, such as a static route's `via`. Lists are sets in constant
positions. A symbol reference is `bird.symbol "NAME"`, and
`bird.expr "A_VALUE + 1"` passes native expression code.

An inline filter is `import.filter.body = "accept;";`, while a string assigned
to `import.filter` names an existing filter. Native `where` clauses stay BIRD
text. Durations are `{ value = 100; unit = "ms"; }`, or a bare integer where the
rule has a bare numeric production. EVPN and L3VPN targets take `bird.ec` in
BIRD's three forms: `bird.ec [ "rt" 65000 1 ]`, the range
`bird.ec [ "rt" 65000 2 10 ]` and the wildcard `bird.ec [ "rt" 65001 ]`.

A statement with several values is a record keyed by the keyword before each
value. Values without a keyword, such as the two thresholds of `cork-threshold`,
take names from the `[[labels]]` table in `registry/bird.toml`. A label maps a
Bison position in one production to a field, and generation checks it against
the C field BIRD's action assigns. Options after an entry's name stay in its
record:

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
`neighbors`, are ordered lists of records, as is a comma-separated repetition
such as an ASPA route's `providers`:

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

Interface statements and static routes are ordered lists that keep duplicate
route prefixes. Each interface record is one statement, and an exclusion applies
within its own statement only. An exclusion and its wildcard therefore go in one
`patterns` list:

```nix
interface = [{
  patterns = [
    { pattern = "eth9"; exclude = true; }
    { pattern = "eth*"; }
  ];
}];
```

A static route with one next hop puts the next hop's options beside `via`. A
list of `via` records is a multipath route:

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

A flowspec prefix is a record under `flow4` or `flow6` keyed by component, such
as `dst`, `proto`, `dport` and `tcp-flags`. Prefix components are typed, and a
flow6 prefix with an offset is `{ prefix; offset; }`. Operator expressions are
BIRD text, given as a string or as `body`. BIRD sorts components by type, which
makes attribute order irrelevant:

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
examples, and the [option search](https://stepbrobd.github.io/router/) for each
setting's expected value, BIRD documentation and grammar rule at the pinned
commit.

Settings stay plain data while modules define them, which lets a module read
`config.services.bird.settings` to decide what else to set. Rendering into
`services.bird.config` validates them and names the failing setting, for example
`protocol.bgp.peer.hold-time: invalid value, expected number-expression`.
Setting `settings` together with a different handwritten `config` is an error,
and leaving `settings` unset keeps the upstream handwritten configuration.

An `include = [ "/run/bird/credentials.conf" ];` setting renders BIRD includes
at the start of the root or of any braced block, without copying the files into
the Nix store. BIRD expands an include at the start of any line, and
`bird.include` can therefore stand in for a value or a list item, as in
`password = bird.include "/run/bird/password.conf";`. A pure build cannot read
runtime files, which leaves `checkConfig` two choices: fixtures from upstream
`preCheckConfig`, or disabling it.

Outside NixOS, the library evaluates and checks the same settings:

```nix
let
  bird = inputs.router.lib.router.bird;
in
{
  generated = bird.eval { modules = [ ./bird.nix ]; };
  checked = bird.check {
    inherit pkgs;
    package = pkgs.bird3;
    modules = [ ./bird.nix ];
  };
}
```

The `eval` function returns `{ config, text, resolved }`. The `resolved` view,
also returned by `bird.resolve settings`, applies `from` inheritance, keeps list
order and keeps repeated routes apart. A structured `from = "parent";` names a
template or an existing protocol of the same type. The view leaves out daemon
defaults, native expressions and runtime includes, and it holds only for
configurations BIRD accepts.

Module definitions concatenate lists and keep `mkBefore`, `mkAfter` and
`mkForce`. BIRD's `from` inheritance is a separate step: repeated statements
such as static routes append to the inherited ones, a list-valued argument such
as BGP `interface-range` replaces them, and a protocol's copy hook can reset
collections, as BFD does for interfaces and neighbors.

Root declarations render in the order `declaration_order` in
`registry/bird.toml` sets: includes, definitions and attributes, other settings,
then functions, filters, templates and protocols. Protocols and templates follow
the ones their `from` names. A dependency inside native code needs ordered
groups, as in `bird.render [ definitions functions filters protocols ]`, and
block bodies accept them too. BIRD checks the semantics, including expression
types, ranges, symbol classes and postconfig constraints.

## Grammar compiler

The Rust CLI takes a BIRD source directory:

```sh
router inspect /path/to/bird
router generate /path/to/bird --output generated/bird
router options /path/to/bird --prefix services.bird.settings --source-url https://github.com/cz-nic/bird/blob/REV/
```

The `generate` command writes the grammar inventory,
`generated/bird/grammar.json`, for the Nix runtime in `lib/router/bird` to
interpret. The checked-in inventory follows the `bird` input in `flake.lock`,
BIRD's `thread-next` branch. A production can also be written in its raw form,
`{ _rule; _production; _args; }`.

The `options` command prints a NixOS `options.json` with one entry per setting
under `--prefix`, described from BIRD's `doc/bird.sgml` and linked to its
production under `--source-url`. A block reachable from several paths, such as a
template's or a second channel's, is listed under the first path and the others
point there. The flake's `packages.site` indexes the file with
[NuschtOS Search](https://github.com/NuschtOS/search), and
`.github/workflows/pages.yaml` publishes it to GitHub Pages. Another module
joins the search as one more entry in the `scopes` list of
`modules/flake/site.nix`.

Generation fails on a setting that cannot be written as attributes and prints
its BIRD source location. The `inspect` command lists the same settings under
`registry.diagnostics.unaddressable`. A BIRD commit that adds one fails the
weekly bump until the registry names its values.

The registry, `registry/bird.toml`, holds public type and field names, rule
aliases, value labels, projection hints and declaration order. Syntax,
delimiters, alternatives and repetition come from the grammar. A required
binding fails when its source match is missing, ambiguous or incompatible. When
upstream renames a rule, keep the binding's `id` and update its `rules` aliases
and source checks. Field names belong in the registry rather than in
protocol-specific Nix code.

Recorded source hashes keep a stale inventory from being used with changed BIRD
sources. The `bird-generation` check regenerates the inventory from the pinned
input and compares it with the checked-in file.

Development uses `nix develop` for the toolchain, `cargo nextest run` for tests,
`nix build` for the compiler and `nix fmt` for formatting and lints. Autopilot
discovers the library, packages and modules.

## License

This work extends the NixCon 2025 talk
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
