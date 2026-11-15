{ lib, protocols }:
config:
let
  inherit (lib)
    elem
    isAttrs
    isList
    isString
    mapAttrs
    ;

  join = base: own: lib.concatStringsSep "\n" (lib.filter (text: text != "") [ base own ]);
  overlay = base: own: base // mapAttrs (name: value: if value == null then base.${name} or null else value) own;

  # bird copies a template and then applies the derived block on top
  # scalars set by the derived block win, lists gain its entries, channels and records merge per field
  value =
    name: base: own:
    if own == null then
      base
    else if base == null then
      own
    else if name == "extraConfig" then
      join base own
    else if name == "channels" then
      mapAttrs
        (
          family: _:
          overlay (base.${family} or { }) (own.${family} or { })
          // {
            extraConfig = join (base.${family}.extraConfig or "") (own.${family}.extraConfig or "");
          }
        )
        (base // own)
    else if isList base && isList own then
      base ++ own
    else if isAttrs base && isAttrs own && !(base ? kind) && !(own ? kind) then
      overlay base own
    else
      own;
  merge =
    base: own:
    mapAttrs
      (
        name: _:
        if elem name [ "ref" "type" "from" ] then own.${name} else value name (base.${name} or null) (own.${name} or null)
      )
      (base // own);

  # router's defaults sit below the root of every inheritance chain
  defaults = type: { disabled = false; } // (if isString type then protocols.${type}.defaults or { } else { });
  # missing, cyclic or mistyped templates fall back to the defaults and are reported by validation
  resolveIn =
    seen: declaration:
    let
      from = declaration.from or null;
      parent = if isAttrs from then from.name or null else null;
      template = if parent == null then null else (config.templates or { }).${parent} or null;
      base =
        if template == null || elem parent seen || (template.type or null) != (declaration.type or null) then
          defaults (declaration.type or null)
        else
          resolveIn (seen ++ [ parent ]) template;
    in
    merge base declaration;
  finish =
    declaration:
    declaration
    // lib.optionalAttrs (declaration ? channels) {
      channels = mapAttrs
        (
          _: channel: channel // { addPaths = if (channel.addPaths or null) == null then "off" else channel.addPaths; }
        )
        declaration.channels;
    };
in
config
  // {
  templates = mapAttrs (name: template: finish (resolveIn [ name ] template)) (config.templates or { });
  protocols = mapAttrs (_: protocol: finish (resolveIn [ ] protocol)) (config.protocols or { });
}
