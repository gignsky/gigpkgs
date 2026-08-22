# gigpkgs inputMan: managed input
#
# NOTE: upstream (github:k3d3/claude-desktop-linux-flake) still references
# `nodePackages.asar`, which was removed from nixpkgs (now `pkgs.asar` at the top
# level). Consuming `inputs.claude-desktop.packages.<system>.claude-desktop`
# directly therefore throws "nodePackages has been removed" under current
# nixpkgs. Until upstream is fixed, we take the input's own packages and swap the
# offending `nativeBuildInputs` entry via overrideAttrs.
#
# We deliberately do NOT re-import upstream's package files by path (e.g.
# `pkgs.callPackage "${src}/pkgs/patchy-cnb.nix"`): that resolves patchy-cnb's
# `../patchy-cnb` relative path to a fresh store copy whose `Cargo.lock` is read
# at eval time (IFD), which fails under `nix flake check --no-build` with
# "path ... is not valid". Using the input's own outputs keeps those relative
# paths rooted in the flake, so no extra realisation is needed to evaluate.
{
  inputs,
  system,
  pkgs,
}:
let
  base = inputs.claude-desktop.packages.${system};

  # patchy-cnb doesn't touch nodePackages — expose the input's build as-is.
  inherit (base) patchy-cnb;

  # Replace the whole nativeBuildInputs list (upstream's, with nodePackages.asar
  # → pkgs.asar). We must not reference the old value or the removed-set throw
  # fires; overrideAttrs replaces the thunk, so it never gets forced.
  claude-desktop = base.claude-desktop.overrideAttrs (_: {
    nativeBuildInputs = with pkgs; [
      p7zip
      asar
      makeWrapper
      imagemagick
      icoutils
      perl
    ];
  });

  # Mirror upstream's flake.nix buildFHSEnv wrapper, pointing at our fixed
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
