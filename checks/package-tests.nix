{
  lib,
  pkgs,
  inputs,
  newsJson,
  ...
}:
let
  allPackages = import ../pkgs {
    inherit
      pkgs
      lib
      inputs
      newsJson
      ;
  };

  # Filter out null packages (from inputs that may not be available)
  validPackages = lib.filterAttrs (_name: pkg: pkg != null) allPackages;

  packageBuilds = lib.mapAttrs' (name: pkg: {
    name = "build-${name}";
    value = pkg;
  }) validPackages;
in
packageBuilds
