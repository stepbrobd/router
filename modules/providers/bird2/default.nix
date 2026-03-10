# Bird2 provider NixOS module
#
# reads the routing contract input from services.bird2.routing,
# compiles it to bird.conf via the Bird2 compiler, and manages
# the Bird2 systemd service with appropriate hardening.

{ std, router, ... }:

{ config, pkgs, lib, ... }:

let
  cfg = config.services.bird2;

  types = ../../contracts/routing/types;
  common = import (types + "/common.nix") { inherit std router; };
  bgpTypes = import (types + "/bgp.nix") { inherit std router; };
  rpkiTypes = import (types + "/rpki.nix") { inherit std router; };
  staticTypes = import (types + "/static.nix") { inherit std router; };
  deviceTypes = import (types + "/device.nix") { inherit std router; };
  directTypes = import (types + "/direct.nix") { inherit std router; };
  kernelTypes = import (types + "/kernel.nix") { inherit std router; };
  ospfTypes = import (types + "/ospf.nix") { inherit std router; };
  ripTypes = import (types + "/rip.nix") { inherit std router; };
  babelTypes = import (types + "/babel.nix") { inherit std router; };
  radvTypes = import (types + "/radv.nix") { inherit std router; };
  bfdTypes = import (types + "/bfd.nix") { inherit std router; };
  bmpTypes = import (types + "/bmp.nix") { inherit std router; };
  mrtTypes = import (types + "/mrt.nix") { inherit std router; };
  aggregatorTypes = import (types + "/aggregator.nix") { inherit std router; };

  # reuse the same option shape as the routing contract input
  routingOptions = {
    routerId = std.mkOption {
      type = std.types.str;
      description = "BIRD router ID, typically an IPv4 address.";
    };

    asn = std.mkOption {
      type = std.types.int;
      description = "Autonomous system number for this router.";
    };

    source = {
      ipv4 = std.mkOption {
        type = std.types.nullOr std.types.str;
        default = null;
        description = "Default IPv4 source address for outgoing connections.";
      };
      ipv6 = std.mkOption {
        type = std.types.nullOr std.types.str;
        default = null;
        description = "Default IPv6 source address for outgoing connections.";
      };
    };

    prefixLists = std.mkOption {
      type = std.types.attrsOf common.prefixListType;
      default = { };
      description = "Named prefix lists referenceable from filter rules.";
    };

    bgp.sessions = std.mkOption {
      type = std.types.attrsOf bgpTypes.bgpSessionType;
      default = { };
      description = "BGP peer sessions keyed by name.";
    };

    ospf.instances = std.mkOption {
      type = std.types.attrsOf ospfTypes.ospfInstanceType;
      default = { };
      description = "OSPF instances keyed by name.";
    };

    rip.instances = std.mkOption {
      type = std.types.attrsOf ripTypes.ripInstanceType;
      default = { };
      description = "RIP instances keyed by name.";
    };

    babel.instances = std.mkOption {
      type = std.types.attrsOf babelTypes.babelInstanceType;
      default = { };
      description = "Babel instances keyed by name.";
    };

    radv.instances = std.mkOption {
      type = std.types.attrsOf radvTypes.radvInstanceType;
      default = { };
      description = "Router advertisement instances keyed by interface.";
    };

    rpki = std.mkOption {
      type = rpkiTypes.rpkiType;
      default = { };
      description = "RPKI origin validation configuration.";
    };

    bfd.sessions = std.mkOption {
      type = std.types.attrsOf bfdTypes.bfdSessionType;
      default = { };
      description = "BFD sessions keyed by name.";
    };

    bmp.stations = std.mkOption {
      type = std.types.attrsOf bmpTypes.bmpStationType;
      default = { };
      description = "BMP monitoring stations keyed by name.";
    };

    mrt.dumps = std.mkOption {
      type = std.types.attrsOf mrtTypes.mrtDumpType;
      default = { };
      description = "MRT table dump configurations keyed by name.";
    };

    static = std.mkOption {
      type = staticTypes.staticType;
      default = { };
      description = "Static route definitions.";
    };

    aggregator.instances = std.mkOption {
      type = std.types.attrsOf aggregatorTypes.aggregatorType;
      default = { };
      description = "Route aggregation instances keyed by name.";
    };

    device = std.mkOption {
      type = deviceTypes.deviceType;
      default = { };
      description = "Device protocol configuration.";
    };

    direct = std.mkOption {
      type = directTypes.directType;
      default = { };
      description = "Direct protocol configuration.";
    };

    kernel = std.mkOption {
      type = kernelTypes.kernelType;
      default = { };
      description = "Kernel protocol configuration.";
    };
  };

  compile = import ./compiler.nix { inherit std router; };

  # Bird2-specific pipe and l3vpn protocols from raw config
  pipeBlocks = std.concatStringsSep "\n\n" (
    std.mapAttrsToList
      (name: body: ''
        protocol pipe ${name} {
          ${body}
        }'')
      cfg.pipe
  );

  l3vpnBlocks = std.concatStringsSep "\n\n" (
    std.mapAttrsToList
      (name: body: ''
        protocol l3vpn ${name} {
          ${body}
        }'')
      cfg.l3vpn
  );

  configText = std.concatStringsSep "\n\n" (std.filter (s: s != "") [
    "router id ${cfg.routing.routerId};"
    (compile cfg.routing)
    pipeBlocks
    l3vpnBlocks
    cfg.extraConfig
  ]);

  configFile =
    if cfg.checkConfig then
      pkgs.runCommandLocal "bird-check-conf"
        {
          nativeBuildInputs = [ cfg.package ];
          preferLocalBuild = true;
        } ''
        cat > bird.conf <<'BIRD_EOF'
        ${configText}
        BIRD_EOF
        ${cfg.preCheckConfig}
        bird -d -p -c bird.conf
        cp bird.conf $out
      ''
    else
      pkgs.writeText "bird.conf" configText;

in
{
  options.services.bird2 = {
    enable = std.mkEnableOption "Bird2 routing daemon";

    package = std.mkPackageOption pkgs "bird2" { };

    autoReload = std.mkOption {
      type = std.types.bool;
      default = true;
      description = "Whether Bird2 should be automatically reloaded when configuration changes.";
    };

    checkConfig = std.mkOption {
      type = std.types.bool;
      default = true;
      description = "Whether to validate bird.conf at build time.";
    };

    preCheckConfig = std.mkOption {
      type = std.types.lines;
      default = "";
      description = "Commands to run before the config check (e.g., to create include files).";
    };

    routing = std.mkOption {
      type = std.types.submodule {
        options = routingOptions;
      };
      default = { };
      description = "Routing contract input -- protocol-agnostic routing configuration.";
    };

    pipe = std.mkOption {
      type = std.types.attrsOf std.types.lines;
      default = { };
      description = "Bird2-specific pipe protocol blocks keyed by name.";
    };

    l3vpn = std.mkOption {
      type = std.types.attrsOf std.types.lines;
      default = { };
      description = "Bird2-specific L3VPN protocol blocks keyed by name.";
    };

    extraConfig = std.mkOption {
      type = std.types.lines;
      default = "";
      description = "Raw Bird2 config appended after all compiled blocks.";
    };
  };

  config = std.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    environment.etc."bird/bird.conf".source = configFile;

    systemd.services.bird = {
      description = "BIRD Internet Routing Daemon";
      wantedBy = [ "multi-user.target" ];
      reloadTriggers = std.optional cfg.autoReload config.environment.etc."bird/bird.conf".source;
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
          ExecStart = "${std.getExe' cfg.package "bird"} -c /etc/bird/bird.conf";
          ExecReload = "${std.getExe' cfg.package "birdc"} configure";
          ExecStop = "${std.getExe' cfg.package "birdc"} down";
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
