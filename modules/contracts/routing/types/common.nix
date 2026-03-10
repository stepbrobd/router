{ std, router, ... }:
{
  # every protocol block inherits these
  blockOptions = {
    order = std.mkOption {
      type = std.types.int;
      default = 1000;
      description = "Numeric priority for ordering in generated config. Lower values appear first.";
    };
    extraConfigBefore = std.mkOption {
      type = std.types.lines;
      default = "";
      description = "Raw config injected before this block (e.g., secret includes).";
    };
    extraConfigAfter = std.mkOption {
      type = std.types.lines;
      default = "";
      description = "Raw config injected after this block.";
    };
  };

  prefixListType = std.types.submodule {
    options.prefixes = std.mkOption {
      type = std.types.listOf (std.types.submodule {
        options = {
          prefix = std.mkOption { type = std.types.str; description = "Prefix in CIDR notation."; };
          ge = std.mkOption { type = std.types.nullOr std.types.int; default = null; description = "Minimum prefix length."; };
          le = std.mkOption { type = std.types.nullOr std.types.int; default = null; description = "Maximum prefix length."; };
        };
      });
      description = "List of prefix entries.";
    };
  };
}
