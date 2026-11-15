# NixOS Router

Router generates routing daemon configuration from typed Nix modules. BIRD 3 is the only backend so far.

NixOS modules in this repo will only produces configuration text. Managing the daemon, choosing its package, provisioning secrets and configuring host networking should still be done downstream users.

## BIRD 3

`nixosModules.bird` adds `services.bird.settings` to the nixpkgs BIRD module and renders it into `services.bird.config`.

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.router.nixosModules.bird ];

  services.bird = {
    enable = true;
    package = pkgs.bird3;
    settings = {
      id = "192.0.2.1";
      protocols.device0.type = "device";
    };
  };
}
```

Settings merge across modules like any other option. Setting both `settings` and a handwritten `config` is an error.

Or you can use it standalone:

```nix
let
  bird = inputs.router.lib.router.bird;
in
{
  # { config, text }
  generated = bird.eval { modules = [ ./bird.nix ]; };
  # the same text, accepted by the BIRD parser
  checked = bird.check {
    inherit pkgs;
    modules = [ ./bird.nix ];
  };
}
```

A settings module declares `id`, `includes`, `attributes`, `defines`, `tables`, `functions`, `filters`, `templates` and `protocols`, plus the global `log`, `debugProtocols`, `gracefulRestartWait` and `extraConfig`. Each named declaration has a `.ref` handle to use wherever another declaration is expected, such as `export = config.filters.export_owned4.ref`. `expr`, `stmt` and `community` build policy code as plain data, `expr.raw` and `stmt.raw` embed native BIRD, and `bird.extend` registers more protocol types. [`examples/bird`](examples/bird) is a complete configuration with policies, communities and BGP peers.

Only what a module declares reaches the rendered configuration, so every unset option keeps BIRD's own default. A protocol or template takes `from = config.templates.<name>.ref` and renders as a BIRD template derivation, and `bird.resolve` returns each declaration with its template chain applied for code that reads inherited values.

Includes are paths on the target host, never read at evaluation time. `bird.external` names a symbol defined in one, such as a BGP password, so secrets stay out of the Nix store.

## License

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

Licensed under the [MIT License](license.txt).
