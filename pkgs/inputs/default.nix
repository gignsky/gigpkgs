# Packages contributed by external flake inputs.
# Drop <name>.nix or <name>/default.nix here to expose packages from an input.
# Each file receives: { inputs, system } and must return an attrset.
#
# `devShellPackages.nix` is a helper consumed separately by flake.nix and is
# not treated as an input aggregator here.

{
  inputs,
  system,
}:
let
  dir = builtins.readDir ./.;
  inputFiles = builtins.map (f: ./. + "/${f}") (
    builtins.filter (
      name:
      let
        t = dir.${name};
      in
      (t == "directory")
      || (
        name != "default.nix" && name != "devShellPackages.nix" && builtins.match ".*\\.nix$" name != null
      )
    ) (builtins.attrNames dir)
  );
  importedSets = builtins.map (f: import f { inherit inputs system; }) inputFiles;
in
builtins.foldl' (acc: set: acc // set) { } importedSets
