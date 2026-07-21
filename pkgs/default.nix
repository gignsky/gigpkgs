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
    inherit inputs system;
  };

  # Channel-aware roll-flow. channel.nix + channel-sources.nix select which
  # `flake = false` sibling source backs `pkgs.roll-flow` on this channel; we
  # build it from source with our own callPackage (roll-flow's package.nix is a
  # plain rustPlatform.buildRustPackage). Guarded on `inputs ? <name>` so the
  # `import nixpkgs {}` shim in default.nix — which calls this WITHOUT inputs —
  # doesn't error; that path supplies roll-flow itself (see default.nix).
  channel = import ../channel.nix;
  rollFlowSources = (import ../channel-sources.nix).roll-flow;
  rollFlowName = rollFlowSources.${channel} or rollFlowSources.default;
  rollFlowSrc = inputs.${rollFlowName};
  rollFlowAttrs =
    if inputs ? ${rollFlowName} then
      { roll-flow = pkgs.callPackage "${rollFlowSrc}/package.nix" { }; }
    else
      { };
in
inputPackages
// rollFlowAttrs
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
