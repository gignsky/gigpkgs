# Base nixpkgs channel this branch builds on.
#
# This single marker is the ONLY thing that differs between the trunk and each
# CI-derived `gigos-*` channel branch. flake.nix (outputs) and default.nix (the
# `import nixpkgs {}` shim) both read it and select `inputs.<channel>` as the
# base, so pkgs / lib / legacyPackages all descend from one consistent base.
#
# The value must name a nixpkgs input declared in flake.nix's `inputs` block
# (e.g. "nixos-unstable", "nixos-2605"). The trunk tracks unstable; channel
# branches are derived by overwriting only this file
# (see .github/workflows/channels.yml).
"nixos-unstable"
