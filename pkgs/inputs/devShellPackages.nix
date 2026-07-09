# Collect single-output default packages exposed by every input registered
# under ./inputs/. Files here are named after the input they aggregate, so their
# filenames double as the source-of-truth list of inputs to consider.
#
# For each such input:
#   - If `inputs.<name>.packages.<system>.default` exists, include it.
#   - Otherwise skip the input entirely (variant packages must be added
#     manually to the devShell, since we can't guess which one to pick).
#
# This keeps the devShell definition in flake.nix free of per-input edits when
# a new single-output input is installed by inputMan.

{
  inputs,
  system,
  lib,
}:
let
  dir = builtins.readDir ./.;
  isInputFile =
    n: t:
    (t == "regular")
    && (n != "default.nix")
    && (n != "devShellPackages.nix")
    && (lib.hasSuffix ".nix" n);
  names = builtins.map (f: lib.removeSuffix ".nix" f) (
    builtins.attrNames (lib.filterAttrs isInputFile dir)
  );

  pkgFor =
    name:
    let
      input = inputs.${name} or null;
      pkgs = if input != null then (input.packages.${system} or { }) else { };
    in
    pkgs.default or null;
in
builtins.filter (p: p != null) (builtins.map pkgFor names)
