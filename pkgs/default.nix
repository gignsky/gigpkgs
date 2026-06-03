# You can build these directly using 'nix build .#example'

{
  pkgs,
  lib ? null,
  inputs ? { },
  newsJson ? null,
}:
let
  programs = import ./programs {
    inherit pkgs newsJson;
  };

  # Scan inputs directory without using lib (to avoid infinite recursion in overlays)
  scanInputsDir =
    dir:
    let
      entries = builtins.readDir dir;
      nixFiles = builtins.filter (
        name: builtins.match ".*\\.nix$" name != null && name != "default.nix"
      ) (builtins.attrNames entries);
    in
    builtins.map (name: dir + "/${name}") nixFiles;

  # Import packages from external flake inputs
  # This scans pkgs/inputs/*.nix for files that expose packages from inputs
  inputPackages =
    if builtins.pathExists ./inputs then
      let
        inputFiles = scanInputsDir ./inputs;
        imported = map (
          f:
          import f {
            inherit inputs pkgs;
            lib = if lib != null then lib else pkgs.lib;
            inherit (pkgs) system;
          }
        ) inputFiles;
      in
      builtins.foldl' (acc: pkgs: acc // pkgs) { } imported
    else
      { };
in
rec {
  # {
  #################### Packaged Scripts ####################
  # Import all packaged scripts from scripts.nix
  # inherit (scripts)
  #   check-hardware-config
  #   nixos-rebuild
  #   home-switch
  #   flake-build
  #   pre-commit-flake-check
  #   run-iso-vm
  #   package-script
  #   roll-flow
  #   rf
  #   ;

  #################### Packaged Programs ####################
  # Import all packaged scripts from programs/
  inherit (programs)
    add-input
    cargo-update
    gigpkgs-input
    gigpkgs-news
    locker
    quick-results
    supertree
    upflake
    upignore
    upjust
    ;

  #################### Input Packages ####################
  # Packages from external flake inputs (pkgs/inputs/*.nix)
}
// inputPackages
