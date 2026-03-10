# Bird2 kernel protocol compiler
#
# emits separate protocol blocks for v4 and v6 -- Bird2 requires
# one kernel instance per address family.

{ std, compileFilter }:

kernelConfig:

let
  # compile a filter or emit "none" when null
  filterOrNone = dir: filterVal:
    if filterVal == null then
      "${dir} none;"
    else
      "${dir} filter {\n${compileFilter filterVal}\n};";

  mkKernel = name: af: channel:
    let
      body = ''
        protocol kernel ${name} {
          scan time ${toString kernelConfig.scanTime};
        ${std.optionalString kernelConfig.learn "  learn;\n"}${std.optionalString kernelConfig.persist "  persist;\n"}  ${af} {
            ${filterOrNone "import" channel.import.filter}
            ${filterOrNone "export" channel.export.filter}
          };
        }
      '';
    in
    {
      order = kernelConfig.order;
      text = std.concatStringsSep "\n" (
        std.optional (kernelConfig.extraConfigBefore != "") kernelConfig.extraConfigBefore
        ++ [ body ]
        ++ std.optional (kernelConfig.extraConfigAfter != "") kernelConfig.extraConfigAfter
      );
    };

in
std.optional (kernelConfig.ipv4 != null) (mkKernel "kernel4" "ipv4" kernelConfig.ipv4)
++ std.optional (kernelConfig.ipv6 != null) (mkKernel "kernel6" "ipv6" kernelConfig.ipv6)
