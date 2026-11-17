{ inputs, lib, ... }:
{
  perSystem = { config, pkgs, ... }: {
    # checks/<backend> provides checks.<system>.<backend>-<name>
    checks = lib.concatMapAttrs
      (backend: lib.mapAttrs' (name: lib.nameValuePair "${backend}-${name}"))
      (lib.loadAll {
        dir = ../../checks;
        args = {
          inherit pkgs lib;
          router = inputs.self.lib.router;
          self = inputs.self;
        };
      }) // { compiler = config.packages.default; };
  };
}
