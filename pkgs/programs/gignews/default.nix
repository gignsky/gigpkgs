{
  pkgs,
  lib,
  newsJson,
}:

let
  # `str downcase` was renamed to `str lowercase` in nushell 0.114, where the
  # old name still works but warns. gignews is built against whatever nushell
  # the consuming channel carries — 0.112 on gigos-2605, 0.115 on master — so
  # pick the spelling that matches at build time.
  #
  # This cannot be branched inside the script: an unknown `str` subcommand is a
  # *parse* error, which kills the whole script even on a code path that never
  # runs. The source keeps the older spelling so it stays parseable as-is.
  lowercaseCmd =
    if lib.versionAtLeast pkgs.nushell.version "0.114" then "str lowercase" else "str downcase";
in

pkgs.stdenv.mkDerivation {
  pname = "gignews";
  version = "0.1.3";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin

    # Substitute the news JSON path into the script
    substitute ${./gignews.nu} $out/bin/gignews \
      --replace-fail "@NEWS_JSON@" "${newsJson}" \
      --replace-warn "str downcase" "${lowercaseCmd}"

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
