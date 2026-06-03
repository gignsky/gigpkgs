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
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  rootNode = lock.nodes.${lock.root};

  fetchNode =
    inputName:
    let
      key =
        let
          v = rootNode.inputs.${inputName};
        in
        if builtins.isList v then builtins.head v else v;
      info = lock.nodes.${key}.locked;
    in
    builtins.fetchTree {
      type = "github";
      inherit (info)
        owner
        repo
        rev
        narHash
        ;
    };

  nixpkgsSrc = fetchNode "nixpkgs";
  nixpkgsUnstableSrc = fetchNode "nixpkgs-unstable";

  pkgs = import nixpkgsSrc {
    inherit system config;
    overlays = overlays ++ [
      (final: _prev: import ./pkgs { pkgs = final; })
      (_final: _prev: {
        unstable = import nixpkgsUnstableSrc {
          inherit system;
          config.allowUnfree = true;
        };
      })
    ];
  };
in
pkgs
