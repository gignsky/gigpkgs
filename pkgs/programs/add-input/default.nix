{
  pkgs,
  lib,
}:

pkgs.stdenv.mkDerivation {
  pname = "add-input";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin

    cp ${./add-input.nu} $out/bin/add-input
    chmod +x $out/bin/add-input

    # Wrap with nushell and required tools
    wrapProgram $out/bin/add-input \
      --prefix PATH : ${
        lib.makeBinPath [
          pkgs.nushell
          pkgs.git
          pkgs.nix
          (pkgs.callPackage ../locker.nix { })
        ]
      }
  '';

  meta = with lib; {
    description = "Interactive flake input installer for gigpkgs";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
