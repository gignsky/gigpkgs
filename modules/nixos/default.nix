# Auto-discovered NixOS modules.
# Drop <name>.nix or <name>/default.nix here to register a new nixosModule.
# Returns an attrset of { moduleName = path; }.

{ lib }:
let
  paths = builtins.map (f: ./. + "/${f}") (
    builtins.attrNames (
      lib.filterAttrs (
        name: type: (type == "directory") || ((name != "default.nix") && (lib.hasSuffix ".nix" name))
      ) (builtins.readDir ./.)
    )
  );
  toName = path: lib.removeSuffix ".nix" (builtins.baseNameOf (toString path));
in
builtins.listToAttrs (builtins.map (p: lib.nameValuePair (toName p) p) paths)
