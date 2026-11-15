{ lib
, protocolExtensions ? { }
}:
let
  extendedLib = lib.extend (_: prev: {
    router = (prev.router or { }) // { bird = self; };
  });
  valueTypes = import ./types.nix { lib = extendedLib; };
  nodes = import ./nodes.nix { lib = extendedLib; };
  schemas = import ./protocols.nix {
    lib = extendedLib;
    types = self.types;
  };
  implementations = import ./protocol-renderers.nix { lib = extendedLib; };
  defaults = extendedLib.mapAttrs (name: schema: schema // implementations.${name}) schemas;
  registry = defaults // protocolExtensions;
  invalidEntries = extendedLib.filterAttrs
    (
      _: entry:
        !(entry ? module)
        || !(entry ? render)
        || !(builtins.isFunction entry.render)
        || (entry ? validate && !(builtins.isFunction entry.validate))
    )
    registry;
  checkedRegistry =
    if invalidEntries == { } then
      registry
    else
      throw "lib.router.bird: protocol extensions require a module, a render function and an optional validate function: ${extendedLib.concatStringsSep ", " (builtins.attrNames invalidEntries)}";
  renderConfig = import ./render.nix {
    lib = extendedLib;
    protocols = checkedRegistry;
  };
  validateConfig = import ./validate.nix {
    lib = extendedLib;
    protocols = checkedRegistry;
  };
  self = nodes // {
    types = valueTypes // {
      settings = extendedLib.types.submoduleWith {
        modules = [ self.settingsModule ];
        specialArgs = {
          lib = extendedLib;
        };
      };
    };
    settingsModule = import ./schema.nix {
      lib = extendedLib;
      bird = self;
      protocols = checkedRegistry;
    };
    validate = validateConfig;
    render =
      config:
      let
        errors = self.validate config;
      in
      if errors == [ ] then
        renderConfig config
      else
        throw (
          "lib.router.bird: invalid configuration\n"
            + extendedLib.concatMapStringsSep "\n" (error: "- ${error}") errors
        );
    eval =
      { modules
      , specialArgs ? { }
      }:
      let
        evaluated = extendedLib.evalModules {
          modules = [ self.settingsModule ] ++ modules;
          specialArgs = specialArgs // {
            lib = extendedLib;
          };
        };
        config = builtins.removeAttrs evaluated.config [ "_module" ];
        text = self.render config;
      in
      builtins.seq text { inherit config text; };
    check =
      { pkgs
      , modules
      , specialArgs ? { }
      , package ? pkgs.bird3
      , name ? "bird-config"
      }:
      let
        result = self.eval { inherit modules specialArgs; };
        source = pkgs.writeText "${name}.conf" result.text;
      in
      if extendedLib.versions.major package.version != "3" then
        throw "lib.router.bird.check requires a BIRD 3 package"
      else
        pkgs.runCommand name { nativeBuildInputs = [ package ]; } ''
          ${extendedLib.getExe' package "bird"} -p -c ${source}
          cp ${source} "$out"
        '';
    extend =
      extension:
      if builtins.attrNames extension != [ "protocols" ] then
        throw "lib.router.bird.extend expects a protocols registry"
      else
        import ./. {
          inherit lib;
          protocolExtensions = protocolExtensions // extension.protocols;
        };
  };
in
self
