{
  lib,
  pkgs,
  inputs,
  ...
}:
let
  packageBuilds = lib.mapAttrs' (name: pkg: {
    name = "build-${name}";
    value = pkg;
  }) (import ../pkgs { inherit pkgs inputs; });
in
packageBuilds
