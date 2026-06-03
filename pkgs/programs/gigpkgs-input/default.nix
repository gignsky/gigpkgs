{
  pkgs,
  lib,
}:

pkgs.stdenv.mkDerivation {
  pname = "gigpkgs-input";
  version = "0.2.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin

    cp ${./gigpkgs-input.nu} $out/bin/gigpkgs-input
    chmod +x $out/bin/gigpkgs-input

    # Create add-input symlink for backwards compatibility
    ln -s $out/bin/gigpkgs-input $out/bin/add-input

    # Wrap with nushell and required tools
    wrapProgram $out/bin/gigpkgs-input \
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
    description = "Manage flake inputs for gigpkgs (add, remove, update)";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
