{ lib
, bird
, protocols
}:
let
  t = lib.types;
  inherit (lib) mkOption;
  bt = bird.types;
  option = type: default: mkOption { inherit type default; };
  declaration = target: { name, ... }: {
    options = {
      ref = mkOption {
        type = bt.referenceTo target;
        readOnly = true;
        default = {
          kind = "reference";
          inherit target name;
        };
        description = "Identity of this declaration without its body.";
      };
      dependsOn = option bt.dependencies [ ];
    };
  };
  submodule =
    modules:
    t.submoduleWith {
      inherit modules;
      specialArgs = { inherit lib; };
    };
  defineModule = submodule [
    (declaration "define")
    { options.value = mkOption { type = bt.expression; }; }
  ];
  defineType = t.mkOptionType {
    name = "router-bird-definition";
    description = "BIRD constant or a value declaration";
    check =
      value: bt.expression.check value || (lib.isAttrs value && value ? value && !(value ? kind));
    merge =
      location: definitions:
      defineModule.merge location (
        map
          (
            definition:
            definition
            // {
              value =
                if lib.isAttrs definition.value && definition.value ? value && !(definition.value ? kind) then
                  definition.value
                else
                  { value = definition.value; };
            }
          )
          definitions
      );
    getSubOptions = defineModule.getSubOptions;
  };
  # protocols and templates share one schema per protocol type
  protocolModule =
    target: tag:
    submodule [
      (declaration target)
      {
        options = {
          type = mkOption { type = t.enum [ tag ]; };
          from = option (t.nullOr (bt.referenceTo "template")) null;
          disabled = option (t.nullOr t.bool) null;
          description = option (t.nullOr t.str) null;
          extraConfig = option t.str "";
        };
      }
      protocols.${tag}.module
    ];
  protocolType = target: t.mkOptionType {
    name = "router-bird-${target}";
    description = "BIRD ${target} selected by its type discriminator";
    check = lib.isAttrs;
    merge =
      location: definitions:
      let
        discriminators = lib.concatMap
          (
            definition:
            lib.optional (definition.value ? type) {
              inherit (definition) file;
              value = definition.value.type;
            }
          )
          definitions;
        tag =
          if discriminators == [ ] then
            throw "${lib.showOption location}: a ${target} requires a type discriminator"
          else
            (lib.modules.mergeDefinitions (location ++ [ "type" ])
              (t.enum (
                lib.attrNames protocols
              ))
              discriminators).mergedValue;
      in
      (protocolModule target tag).merge location definitions;
    getSubOptions = _: { };
  };
  logType = t.submodule {
    options = {
      target = mkOption {
        type = t.enum [
          "file"
          "fixed"
          "syslog"
          "stderr"
          "udp"
        ];
      };
      # file and fixed
      path = option (t.nullOr t.str) null;
      # rotation limit of a file, ring size of a fixed log
      size = option (t.nullOr bt.uint) null;
      # the file a rotated log moves to
      backup = option (t.nullOr t.str) null;
      # syslog identity
      name = option (t.nullOr t.str) null;
      # udp host name or address and port
      address = option (t.nullOr t.str) null;
      port = option (t.nullOr bt.port) null;
      classes = mkOption {
        type = t.either (t.enum [ "all" ]) (
          t.listOf (
            t.enum [
              "debug"
              "trace"
              "info"
              "remote"
              "warning"
              "error"
              "auth"
              "fatal"
              "bug"
            ]
          )
        );
      };
    };
  };
in
{
  options = {
    id = mkOption {
      type = t.str;
      description = "BIRD router ID as an IPv4 address.";
    };
    includes = option (t.listOf t.str) [ ];
    log = option (t.listOf logType) [ ];
    debugProtocols = option
      (t.nullOr (
        t.either
          (t.enum [
            "all"
            "off"
          ])
          (
            t.listOf (
              t.enum [
                "states"
                "routes"
                "filters"
                "interfaces"
                "events"
                "packets"
              ]
            )
          )
      ))
      null;
    gracefulRestartWait = option (t.nullOr bt.uint) null;
    # native global options, rendered after the includes and before every declaration
    extraConfig = option t.str "";
    attributes = option
      (t.attrsOf (submodule [
        (declaration "attribute")
        {
          options.type = mkOption {
            type = t.enum [
              "bool"
              "int"
              "string"
              "ip"
              "prefix"
              "pair"
              "quad"
              "ec"
              "lc"
              "bgppath"
              "clist"
              "eclist"
              "lclist"
            ];
          };
        }
      ]))
      { };
    defines = option (t.attrsOf defineType) { };
    tables = option
      (t.attrsOf (submodule [
        (declaration "table")
        {
          options.type = mkOption {
            type = t.enum [
              "ipv4"
              "ipv6"
              "roa4"
              "roa6"
            ];
          };
        }
      ]))
      { };
    functions = option
      (t.attrsOf (submodule [
        (declaration "function")
        {
          options = {
            params = option
              (t.listOf (
                t.submodule {
                  options = {
                    name = mkOption { type = t.str; };
                    type = mkOption { type = bt.birdType; };
                  };
                }
              )) [ ];
            returnType = option (t.nullOr bt.birdType) null;
            body = option bt.body [ ];
          };
        }
      ]))
      { };
    filters = option
      (t.attrsOf (submodule [
        (declaration "filter")
        {
          options = {
            default = mkOption {
              type = t.enum [
                "accept"
                "reject"
              ];
            };
            body = option bt.body [ ];
          };
        }
      ]))
      { };
    templates = option (t.attrsOf (protocolType "template")) { };
    protocols = option (t.attrsOf (protocolType "protocol")) { };
  };
}
