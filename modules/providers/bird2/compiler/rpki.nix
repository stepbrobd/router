# Bird2 RPKI protocol compiler
#
# emits ROA table declarations and one protocol block per validator.

{ std }:

rpkiConfig:

let
  tables = rpkiConfig.tables;

  # ROA table declarations need to appear before any protocol that references them
  tableDecl = {
    order = 10;
    text = ''
      roa4 table ${tables.ipv4};
      roa6 table ${tables.ipv6};
    '';
  };

  mkValidator = name: cfg:
    {
      order = cfg.order;
      text = std.concatStringsSep "\n" (
        std.optional (cfg.extraConfigBefore != "") cfg.extraConfigBefore
        ++ [
          ''
            protocol rpki ${name} {
              roa4 { table ${tables.ipv4}; };
              roa6 { table ${tables.ipv6}; };
              remote "${cfg.remote}" port ${toString cfg.port};
              retry keep ${toString cfg.retry};
              refresh keep ${toString cfg.refresh};
              expire ${toString cfg.expire};
            }
          ''
        ]
        ++ std.optional (cfg.extraConfigAfter != "") cfg.extraConfigAfter
      );
    };

  validators = std.mapAttrsToList mkValidator rpkiConfig.validators;

in
# only emit table declarations when there are validators
std.optional (rpkiConfig.validators != { }) tableDecl
++ validators
