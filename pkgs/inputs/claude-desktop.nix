# gigpkgs inputMan: managed input
#
# NOTE: upstream (github:k3d3/claude-desktop-linux-flake) still references
# `nodePackages.asar`, which was removed from nixpkgs (now `pkgs.asar` at the top
# level). Consuming `inputs.claude-desktop.packages.<system>` directly therefore
# throws "nodePackages has been removed" under current nixpkgs. Until upstream is
# fixed, we rebuild the packages from the input's source with our own `pkgs`,
# supplying `asar` via the `nodePackages` argument.
{
  inputs,
  pkgs,
}:
let
  src = inputs.claude-desktop;

  patchy-cnb = pkgs.callPackage "${src}/pkgs/patchy-cnb.nix" { };

  claude-desktop = pkgs.callPackage "${src}/pkgs/claude-desktop.nix" {
    inherit patchy-cnb;
    # Shim the removed nodePackages set to satisfy the `nodePackages.asar` ref.
    nodePackages = { inherit (pkgs) asar; };
  };

  # Mirror upstream's flake.nix buildFHSEnv wrapper, pointing at our rebuilt
  # claude-desktop instead of the broken one baked into the input's outputs.
  claude-desktop-with-fhs = pkgs.buildFHSEnv {
    name = "claude-desktop";
    targetPkgs =
      pkgs: with pkgs; [
        docker
        glibc
        openssl
        nodejs
        uv
      ];
    runScript = "${claude-desktop}/bin/claude-desktop";
    extraInstallCommands = ''
      # Copy desktop file from the claude-desktop package
      mkdir -p $out/share/applications
      cp ${claude-desktop}/share/applications/claude.desktop $out/share/applications/

      # Copy icons
      mkdir -p $out/share/icons
      cp -r ${claude-desktop}/share/icons/* $out/share/icons/
    '';
  };
in
{
  inherit claude-desktop claude-desktop-with-fhs;
  claude-desktop-patchy-cnb = patchy-cnb;
}
