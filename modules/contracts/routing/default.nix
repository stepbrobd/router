{ std, router, ... }:
{ config, ... }:

let
  cfg = config.contracts.routing;

  types = ./types;
  common = import (types + "/common.nix") { inherit std router; };
  filter = import (types + "/filter.nix") { inherit std router; };
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

  # shared option set used by both input and output to avoid duplication
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

in
{
  options.contracts.routing = {
    input = std.mkOption {
      type = std.types.submodule {
        options = routingOptions;
      };
      default = { };
      description = "Routing contract input -- routing protocol configuration.";
    };

    # provider populates this from input; downstream modules read it
    output = std.mkOption {
      type = std.types.attrsOf std.types.anything;
      readOnly = true;
      default = cfg.input;
      description = "Routing contract output -- mirrors all inputs for downstream consumption.";
    };
  };
}
