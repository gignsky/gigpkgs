# Containers contributed by external flake inputs.
# Files under ./inputs/ are inputMan-generated aggregators, each a function
# `{ inputs, system }: attrset` returning
#   { <name> = inputs.<input>.containers.${system}.<container>; ... }
# whose results are merged here. Exposed as `containers.<system>.<name>`; each
# value is the container spec the input's flake publishes (fill-in items plus
# `imageFile` and a `service` attrset that oci-containers accepts verbatim).
# Consumed by `gigpkgs.nixosModules.containers` (`gigpkgs.containers.fromInputs`).
{ inputs, system }:
let
  dir = ./inputs;
  files =
    if builtins.pathExists dir then
      builtins.filter (n: builtins.match ".*\\.nix$" n != null) (
        builtins.attrNames (builtins.readDir dir)
      )
    else
      [ ];
in
builtins.foldl' (acc: f: acc // (import (dir + "/${f}") { inherit inputs system; })) { } files
