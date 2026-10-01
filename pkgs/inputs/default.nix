# Packages contributed by external flake inputs.
# Drop <name>.nix or <name>/default.nix here to expose packages from an input.
# Each file receives whichever of { inputs, system, pkgs } it declares in its
# argument set (autofilled callPackage-style), and must return an attrset.
#
# `devShellPackages.nix` is a helper consumed separately by flake.nix and is
# not treated as an input aggregator here.

{
  inputs,
  system,
  pkgs ? null,
}:
let
  available = { inherit inputs system pkgs; };
  # Pass a file only the args it actually declares, so simple inputs can keep
  # `{ inputs, system }` while richer ones (e.g. claude-desktop) opt into `pkgs`.
  importFile =
    f:
    let
      fn = import f;
    in
    fn (builtins.intersectAttrs (builtins.functionArgs fn) available);
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
  importedSets = builtins.map importFile inputFiles;
in
builtins.foldl' (acc: set: acc // set) { } importedSets
