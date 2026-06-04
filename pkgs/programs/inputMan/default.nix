{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "inputman";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin $out/share/inputMan

    cp ${./lib.nix} $out/share/inputMan/lib.nix

    substitute ${./inputMan.sh} $out/bin/inputman \
      --replace "@LIB_PATH@" "$out/share/inputMan/lib.nix"

    chmod +x $out/bin/inputman

    wrapProgram $out/bin/inputman \
      --prefix PATH : ${
        pkgs.lib.makeBinPath [
          pkgs.nix
          pkgs.git
          pkgs.jq
          pkgs.perl
        ]
      }
  '';

  meta = {
    description = "Manage flake inputs for gigpkgs";
    license = pkgs.lib.licenses.mit;
    platforms = pkgs.lib.platforms.linux;
  };
}
