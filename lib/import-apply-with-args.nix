{ lib }:
modulePath: staticArgs:
let
  inherit (lib) all attrNames elem filterAttrs functionArgs intersectLists isFunction;
  f = import modulePath;
  staticArgNames = attrNames staticArgs;
  moduleArgNames = if isFunction f then attrNames (functionArgs f) else [ ];
  requiredArgNames = attrNames (filterAttrs (_: hasDefault: !hasDefault) (functionArgs f));
  argUsed =
    if !(isFunction f) then false
    else if moduleArgNames == [ ] then isFunction (f { })
    else intersectLists staticArgNames moduleArgNames != [ ]
      && all (n: elem n staticArgNames) requiredArgNames;
in
{
  key = toString modulePath;
  _file = modulePath;
  imports = [ (if argUsed then f staticArgs else f) ];
}
