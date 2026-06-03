{
  pkgs,
  lib,
  newsJson,
}:

pkgs.stdenv.mkDerivation {
  pname = "gignews";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin

    # Substitute the news JSON path into the script
    substitute ${./gignews.nu} $out/bin/gignews \
      --replace "@NEWS_JSON@" "${newsJson}"

    chmod +x $out/bin/gignews

    # Wrap with nushell
    wrapProgram $out/bin/gignews \
      --prefix PATH : ${lib.makeBinPath [ pkgs.nushell ]}
  '';

  meta = with lib; {
    description = "View and manage gigpkgs news entries";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
