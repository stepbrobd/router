# Renders services.bird.config from settings. The upstream NixOS BIRD module owns the service.
{ config, lib, ... }:
let
  backend = import ./default.nix { inherit lib; };
  cfg = config.services.bird;
  generated = backend.render cfg.settings;
in
{
  options.services.bird = {
    # Settings stay unvalidated data, so modules can read them while defining them.
    # Rendering into services.bird.config validates them.
    settings = lib.mkOption {
      type = lib.types.nullOr backend.settingsType;
      default = null;
      description = "Source-grammar BIRD settings. Null leaves the upstream handwritten configuration unchanged.";
    };
    config = lib.mkOption {
      apply = value:
        if cfg.settings != null && value != generated then
          throw "services.bird: source-grammar settings and a conflicting handwritten config cannot be combined"
        else value;
    };
  };
  config = lib.mkIf (cfg.settings != null) {
    services.bird.config = generated;
    assertions = [{
      assertion = cfg.package ? src && backend.matchesSource cfg.package.src;
      message = "services.bird.settings needs a BIRD package built from the source router's inventory was generated from. Select that package or regenerate the inventory.";
    }];
  };
}
