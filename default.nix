# Compatibility shim: makes `import nixpkgs { ... }` work when
# nixpkgs is pointed at gigpkgs (github:gignsky/gigpkgs).
#
# Returns the full nixpkgs package set with gigpkgs overlays applied,
# using the exact nixpkgs revision pinned in flake.lock.
#
# Usage:
#   pkgs = import nixpkgs {
#     inherit system;
#     config = { allowUnfree = true; };
#   };
#
# This is equivalent to:
#   pkgs = nixpkgs.legacyPackages.${system};

{
  system ? builtins.currentSystem,
  config ? { },
  overlays ? [ ],
  ...
}:

let
  # Read the pinned nixpkgs from flake.lock
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  rootNode = lock.nodes.${lock.root};
  nixpkgsInput = rootNode.inputs.nixpkgs;
  nixpkgsKey = if builtins.isList nixpkgsInput then builtins.head nixpkgsInput else nixpkgsInput;
  nixpkgsInfo = lock.nodes.${nixpkgsKey}.locked;

  # Fetch the exact pinned nixpkgs revision
  nixpkgsSrc = builtins.fetchTree {
    type = "github";
    inherit (nixpkgsInfo)
      owner
      repo
      rev
      narHash
      ;
  };

  # Build nixpkgs with gigpkgs overlays applied
  pkgs = import nixpkgsSrc {
    inherit system config;
    overlays = overlays ++ [
      (import ./overlays).additions
      (import ./overlays).unstable-packages
    ];
  };
in
pkgs
