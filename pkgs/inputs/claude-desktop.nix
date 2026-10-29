# gigpkgs inputMan: managed input
#
# Hand-customized: upstream's `claude-desktop-with-fhs` only rewraps bin/ — its
# share/applications/*.desktop is symlinked straight from the unwrapped
# claude-desktop, so every Exec= line (including the NewChat/NewCode actions)
# launches outside the FHS env. Anything started from a launcher then can't run
# dynamically linked binaries (MCP servers, npx/uvx tools, etc.). We re-point
# those Exec= lines at the FHS wrapper.
#
# Bindings go through `upstream` (rather than one passthrough line per package)
# so inputMan treats this file as custom and doesn't re-append the raw
# `claude-desktop-claude-desktop-with-fhs` alias on update.
{
  inputs,
  system,
  pkgs,
}:
let
  upstream = inputs.claude-desktop.packages.${system};
in
{
  inherit (upstream) claude-desktop claude-desktop-shell;

  claude-desktop-with-fhs = pkgs.symlinkJoin {
    name = "claude-desktop-with-fhs";
    paths = [ upstream.claude-desktop-with-fhs ];
    inherit (upstream.claude-desktop-with-fhs) meta;
    postBuild = ''
      for f in $out/share/applications/*.desktop; do
        src=$(readlink -f "$f")
        rm "$f"
        sed "s|^Exec=[^ ]*/bin/claude-desktop|Exec=$out/bin/claude-desktop|" "$src" > "$f"
      done
    '';
  };
}
