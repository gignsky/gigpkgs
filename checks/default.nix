# Merge all test attributes into a single flat set
{
  self,
  pkgs,
  lib,
  inputs,
  ...
}@args:
(import ./package-tests.nix args) // (import ./container-tests.nix args)
