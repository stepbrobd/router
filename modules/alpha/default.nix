{ lib, ... }:

{ config, pkgs, ... }:

let
  cfg = config.services.bird;
in
{
  disabledModules = [ "services/networking/bird.nix" ];

  options.services.bird = {
    enable = lib.mkEnableOption "BIRD Internet Routing Daemon";

    package = lib.mkPackageOption pkgs "bird2" { };

    config = lib.mkOption {
      type = lib.types.submodule (import ./interface.nix { inherit cfg lib; });
      description = "BIRD Internet Routing Daemon configurations.";
    };

    autoReload = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether bird should be automatically reloaded when the configuration changes.
      '';
    };

    checkConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the config should be checked at build time.
        When the config can't be checked during build time, for example when it includes
        other files, either disable this option or use `preCheckConfig` to create
        the included files before checking.
      '';
    };

    preCheckConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        echo "cost 100;" > include.conf
      '';
      description = ''
        Commands to execute before the config file check. The file to be checked will be
        available as `bird.conf` in the current directory.

        Files created with this option will not be available at service runtime, only during
        build time checking.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    environment.etc."bird/bird.conf".source = pkgs.callPackage ./implementation.nix {
      inherit lib cfg;
    };

    systemd.services.bird = {
      description = "BIRD Internet Routing Daemon";
      wantedBy = [ "multi-user.target" ];
      reloadTriggers = lib.optional cfg.autoReload config.environment.etc."bird/bird.conf".source;
      serviceConfig =
        let
          caps = [
            "CAP_NET_ADMIN"
            "CAP_NET_BIND_SERVICE"
            "CAP_NET_RAW"
          ];
        in
        {
          Type = "forking";
          Restart = "on-failure";
          User = "bird";
          Group = "bird";
          ExecStart = "${lib.getExe' cfg.package "bird"} -c /etc/bird/bird.conf";
          ExecReload = "${lib.getExe' cfg.package "birdc"} configure";
          ExecStop = "${lib.getExe' cfg.package "birdc"} down";
          RuntimeDirectory = "bird";
          CapabilityBoundingSet = caps;
          AmbientCapabilities = caps;
          ProtectSystem = "full";
          ProtectHome = "yes";
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          PrivateTmp = true;
          PrivateDevices = true;
          SystemCallFilter = "~@cpu-emulation @debug @keyring @module @mount @obsolete @raw-io";
          MemoryDenyWriteExecute = "yes";
        };
    };

    users = {
      groups.bird = { };
      users.bird = {
        description = "BIRD Internet Routing Daemon user";
        group = "bird";
        isSystemUser = true;
      };
    };
  };
}
