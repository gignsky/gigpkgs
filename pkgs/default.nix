# You can build these directly using 'nix build .#example'

{
  pkgs ? import <nixpkgs> { },
  inputs ? { },
  system ? pkgs.stdenv.hostPlatform.system,
  newsJson ? null,
}:
let
  programs = import ./programs {
    inherit pkgs newsJson;
  };

  inputPackages = import ./inputs {
    inherit inputs system pkgs;
  };
in
inputPackages
// {
  inherit (programs)
    cargo-update
    gignews
    inputman
    locker
    quick-results
    supertree
    upflake
    upignore
    upjust
    ;
}
