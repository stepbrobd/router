{ lib, ... }:
let router = lib.router; in
{ config, lib, ... }:
let
  cfg = config.services.bird;
  generated = router.bird.render cfg.settings;
in
{
  options.services.bird = {
    settings = lib.mkOption {
      type = lib.types.nullOr router.bird.types.settings;
      default = null;
      description = ''
        Typed BIRD 3 configuration. Definitions merge across NixOS modules.
        Null leaves the upstream handwritten config option unchanged.
        This extension does not enable BIRD or change its service or package.
      '';
    };
    config = lib.mkOption {
      apply =
        value:
        if cfg.settings != null && value != generated then
          throw "services.bird: settings and a conflicting handwritten config cannot be combined; put native code in an explicit settings escape instead"
        else
          value;
    };
  };

  config = lib.mkIf (cfg.settings != null) {
    services.bird.config = generated;
  };
}
