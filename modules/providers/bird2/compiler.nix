# Bird2 top-level compiler orchestrator
#
# collects all per-protocol blocks, sorts by order, and concatenates.
# does NOT emit router id -- that is handled by the provider module.

{ std, router }:

contractInput:

let
  # instantiate the filter compiler with shared dependencies
  mkCompileFilter = import ./compiler/filter.nix { inherit std router; };

  # singleton protocol compilers
  compileDevice = import ./compiler/device.nix { inherit std; };
  compileDirect = import ./compiler/direct.nix { inherit std; };
  compileKernel = import ./compiler/kernel.nix {
    inherit std;
    compileFilter = mkCompileFilter { roaTable = "roa4"; };
  };
  compileStatic = import ./compiler/static.nix { inherit std router; };

  # RPKI
  compileRpki = import ./compiler/rpki.nix { inherit std; };

  # BGP -- needs top-level input for asn and ROA tables
  compileBgpSession = import ./compiler/bgp.nix {
    inherit std router;
    compileFilter = mkCompileFilter;
  };

  # attrsOf protocol compilers
  compileOspf = import ./compiler/ospf.nix {
    inherit std router;
    compileFilter = mkCompileFilter;
  };
  compileRip = import ./compiler/rip.nix {
    inherit std;
    compileFilter = mkCompileFilter;
  };
  compileBabel = import ./compiler/babel.nix {
    inherit std;
    compileFilter = mkCompileFilter;
  };
  compileRadv = import ./compiler/radv.nix { inherit std; };
  compileBfd = import ./compiler/bfd.nix { inherit std; };
  compileBmp = import ./compiler/bmp.nix { inherit std; };
  compileMrt = import ./compiler/mrt.nix { inherit std; };
  compileAggregator = import ./compiler/aggregator.nix {
    inherit std;
    compileFilter = mkCompileFilter;
  };

  # -- collect all blocks --

  deviceBlocks = compileDevice contractInput.device;
  directBlocks = compileDirect contractInput.direct;
  kernelBlocks = compileKernel contractInput.kernel;

  staticBlocks =
    if contractInput.static.ipv4.routes == [ ] && contractInput.static.ipv6.routes == [ ]
    then [ ]
    else compileStatic contractInput.static;

  rpkiBlocks = compileRpki contractInput.rpki;

  bgpBlocks = std.concatLists (
    std.mapAttrsToList
      (name: cfg: compileBgpSession contractInput name cfg)
      contractInput.bgp.sessions
  );

  ospfBlocks = std.concatLists (
    std.mapAttrsToList compileOspf contractInput.ospf.instances
  );

  ripBlocks = std.concatLists (
    std.mapAttrsToList compileRip contractInput.rip.instances
  );

  babelBlocks = std.concatLists (
    std.mapAttrsToList compileBabel contractInput.babel.instances
  );

  radvBlocks = std.concatLists (
    std.mapAttrsToList compileRadv contractInput.radv.instances
  );

  bfdBlocks = std.concatLists (
    std.mapAttrsToList compileBfd contractInput.bfd.sessions
  );

  bmpBlocks = std.concatLists (
    std.mapAttrsToList compileBmp contractInput.bmp.stations
  );

  mrtBlocks = std.concatLists (
    std.mapAttrsToList compileMrt contractInput.mrt.dumps
  );

  aggregatorBlocks = std.concatLists (
    std.mapAttrsToList compileAggregator contractInput.aggregator.instances
  );

  allBlocks =
    deviceBlocks
    ++ directBlocks
    ++ kernelBlocks
    ++ staticBlocks
    ++ rpkiBlocks
    ++ bgpBlocks
    ++ ospfBlocks
    ++ ripBlocks
    ++ babelBlocks
    ++ radvBlocks
    ++ bfdBlocks
    ++ bmpBlocks
    ++ mrtBlocks
    ++ aggregatorBlocks;

  sorted = std.sort (a: b: a.order < b.order) allBlocks;

in
std.concatMapStringsSep "\n\n" (b: b.text) sorted
