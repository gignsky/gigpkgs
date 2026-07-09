# Auto-discovered NixOS modules.
# Drop <name>.nix or <name>/default.nix here to register a new nixosModule.
# Files under ./inputs/ are treated as inputMan-generated aggregators —
# each is a function `{ inputs }: attrset` whose result is merged in.
# Returns an attrset of { moduleName = path-or-module; }.

{
  lib,
  inputs ? { },
}:
let
  dir = builtins.readDir ./.;
  isDirect =
    name: type:
    (name != "default.nix")
    && (name != "inputs")
    && ((type == "directory") || (lib.hasSuffix ".nix" name));
  directPaths = builtins.map (f: ./. + "/${f}") (builtins.attrNames (lib.filterAttrs isDirect dir));
  toName = path: lib.removeSuffix ".nix" (builtins.baseNameOf (toString path));
  direct = builtins.listToAttrs (builtins.map (p: lib.nameValuePair (toName p) p) directPaths);

  inputsDir = ./inputs;
  fromInputs =
    if builtins.pathExists inputsDir then
      let
        idir = builtins.readDir inputsDir;
        files = builtins.attrNames (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) idir);
      in
      builtins.foldl' (acc: f: acc // (import (inputsDir + "/${f}") { inherit inputs; })) { } files
    else
      { };
in
direct // fromInputs
