{
  pkgs,
  lib,
  newsJson,
}:

pkgs.stdenv.mkDerivation {
  pname = "gigpkgs-news";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin

    # Substitute the news JSON path into the script
    substitute ${./gigpkgs-news.nu} $out/bin/gigpkgs-news \
      --replace "@NEWS_JSON@" "${newsJson}"

    chmod +x $out/bin/gigpkgs-news

    # Wrap with nushell
    wrapProgram $out/bin/gigpkgs-news \
      --prefix PATH : ${lib.makeBinPath [ pkgs.nushell ]}
  '';

  meta = with lib; {
    description = "View and manage gigpkgs news entries";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
