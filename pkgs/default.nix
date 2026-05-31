# You can build these directly using 'nix build .#example'

{
  pkgs ? import <nixpkgs> { },
}:
let
  # Import packaged scripts
  scripts = import ./scripts.nix { inherit pkgs; };
  programs = import ./programs { inherit pkgs; };
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
    cargo-update
    locker
    quick-results
    supertree
    upflake
    upignore
    upjust
    ;
}
