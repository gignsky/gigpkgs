# channel-sources.nix
#
# Channel-aware source map for multi-version sibling inputs.
#
# For each logical program pinned differently per channel, map the channel.nix
# marker string -> the flake input NAME (declared in flake.nix) that backs it on
# that channel. Read by BOTH flake.nix (via ./pkgs/default.nix) and default.nix
# (the `import nixpkgs {}` shim), exactly like channel.nix, so selection
# survives CI projection — channels.yml rewrites ONLY channel.nix, never this
# file, so this map MUST stay channel-agnostic (identical on every branch).
#
# `default` is the fallback for any channel with no explicit entry.
#
# Managed by `inputman group-install` / `inputman freeze`.
{
  roll-flow = {
    "nixos-unstable" = "roll-flow-develop"; # trunk / gigos-unstable — rolling
    "nixos-stable" = "roll-flow-main"; # gigos-stable — follows main
    "nixos-2605" = "roll-flow-main"; # gigos-26.05 — freeze here when stable moves on
    default = "roll-flow-main";
  };
}
