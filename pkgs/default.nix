# You can build these directly using 'nix build .#example'

{
  pkgs ? import <nixpkgs> { },
  newsJson ? null,
}:
let
  programs = import ./programs {
    inherit pkgs newsJson;
  };
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
    gignews
    locker
    quick-results
    supertree
    upflake
    upignore
    upjust
    ;
}
