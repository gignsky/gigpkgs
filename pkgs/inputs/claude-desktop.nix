# gigpkgs inputMan: managed input
#
# Two upstream (github:k3d3/claude-desktop-linux-flake) issues force us to
# rebuild these packages rather than consume the input's outputs directly:
#
#   1. `nodePackages.asar` — removed from nixpkgs (now `pkgs.asar` at top level),
#      so the input's claude-desktop throws "nodePackages has been removed".
#
#   2. patchy-cnb's `cargoLock.lockFile` resolves upstream's `../patchy-cnb` PATH
#      LITERAL to a fresh `…-patchy-cnb` store copy, and buildRustPackage reads
#      that Cargo.lock at eval time. In a fresh store that copy isn't realised, so
#      `nix flake check --no-build` (CI) dies with "path … is not valid". We avoid
#      it by pointing src/lockFile at the flake input's own store path via a
#      string subpath (`"${cd}/patchy-cnb"`), which is already valid — no separate
#      realisation needed to evaluate.
{
  inputs,
  pkgs,
}:
let
  cd = inputs.claude-desktop;

  # Reproduce upstream's pkgs/patchy-cnb.nix, but source src + Cargo.lock from the
  # already-valid flake-input store path (see note 2 above) instead of the
  # `../patchy-cnb` path literal.
  patchy-cnb = pkgs.rustPlatform.buildRustPackage {
    pname = "patchy-cnb";
    version = "0.1.0";

    src = "${cd}/patchy-cnb";
    cargoLock.lockFile = "${cd}/patchy-cnb/Cargo.lock";

    nativeBuildInputs = [
      pkgs.napi-rs-cli
      pkgs.nodejs
    ];

    buildPhase = ''
      runHook preBuild
      npm run build --offline
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib
      cp patchy-cnb.*.node $out/lib/
      runHook postInstall
    '';

    meta = {
      description = "Stub replacement for claude-native-bindings.node, for use in claude-desktop";
      license = with pkgs.lib.licenses; [
        mit
        asl20
      ];
    };
  };

  # Rebuild upstream's claude-desktop with our patchy-cnb and pkgs.asar in place
  # of the removed nodePackages.asar (see note 1 above). Its `src = ./.` is a path
  # LITERAL that addToStore-copies a fresh `…-pkgs` path — the same fresh-copy
  # hazard as note 2 — so we override src to the valid flake-input subpath. The
  # original `./.` thunk is replaced by overrideAttrs and never forced.
  claude-desktop =
    (pkgs.callPackage "${cd}/pkgs/claude-desktop.nix" {
      inherit patchy-cnb;
      nodePackages = { inherit (pkgs) asar; };
    }).overrideAttrs
      (_: {
        src = "${cd}/pkgs";
      });

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
