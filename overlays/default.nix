#
# This file defines overlays/custom modifications to upstream packages
#

{ inputs, ... }:
let
  additions = final: _prev: import ../pkgs { pkgs = final; };
in
{
  # Adds all gigpkgs custom packages as top-level pkgs attributes.
  # This is the canonical overlay for downstream consumers.
  default = additions;

  # Named alias kept for compatibility
  inherit additions;

  # When applied, the unstable nixpkgs set (declared in the flake inputs) will
  # be accessible through 'pkgs.unstable'
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };
}
