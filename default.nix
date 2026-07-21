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

  # Same base selection as flake.nix — honour the channel.nix marker so the
  # `import nixpkgs {}` shim fetches the branch's base channel, not a hardcoded one.
  channel = import ./channel.nix;
  nixpkgsSrc = fetchNode channel;
  nixpkgsUnstableSrc = fetchNode "nixpkgs-unstable";

  # Channel-aware roll-flow source, kept in sync with the flake path (./pkgs)
  # so `import nixpkgs {}` exposes the same roll-flow the flake does. Guarded on
  # the lock actually carrying the selected input, so the shim still evaluates
  # before `nix flake lock` has populated the roll-flow siblings.
  rollFlowSources = (import ./channel-sources.nix).roll-flow;
  rollFlowName = rollFlowSources.${channel} or rollFlowSources.default;
  rollFlowOverlay =
    if rootNode.inputs ? ${rollFlowName} then
      (final: _prev: {
        roll-flow = final.callPackage "${fetchNode rollFlowName}/package.nix" { };
      })
    else
      (_final: _prev: { });

  pkgs = import nixpkgsSrc {
    inherit system config;
    overlays = overlays ++ [
      (final: _prev: import ./pkgs { pkgs = final; })
      rollFlowOverlay
      (final: _prev: {
        unstable =
          (import nixpkgsUnstableSrc {
            inherit system;
            config.allowUnfree = true;
          })
          // (if final ? roll-flow then { inherit (final) roll-flow; } else { });
      })
    ];
  };
in
pkgs
