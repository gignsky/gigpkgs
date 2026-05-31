{ pkgs, ... }:
let
  pkg = pkgs.writeShellScriptBin "quick-results" ''
    check_and_display() {
      local dir=$1
      local name=$2
      if [ -d "$dir" ]; then
        echo "Contents of $name directory:" | ${pkgs.lolcat}/bin/lolcat 2> /dev/null
        if [ "$dir" == "./target" ]; then
          ${pkgs.tree}/bin/tree -L 2 "$dir" | ${pkgs.lolcat}/bin/lolcat 2> /dev/null
        else
          ${pkgs.tree}/bin/tree "$dir" | ${pkgs.lolcat}/bin/lolcat 2> /dev/null
        fi
      else
        if [ "$dir" == "./result" ]; then
          if [ -d "./result" ]; then
            ${pkgs.tree}/bin/tree "$dir" | ${pkgs.lolcat}/bin/lolcat 2> /dev/null
          else
            ls -lah "$dir" | ${pkgs.lolcat}/bin/lolcat 2> /dev/null
          fi
        else
          echo "No $name directory found" | ${pkgs.cowsay}/bin/cowsay | ${pkgs.lolcat}/bin/lolcat 2> /dev/null
        fi
      fi
    }

    # Check cargo target folder
    check_and_display "./target" "cargo target"

    # Check nix result folder
    check_and_display "./result" "nix result"

    # Check nix result-man folder
    check_and_display "./result-man" "nix result-man"

    # Check node_modules folder
    check_and_display "./node_modules" "node_modules"

    # Check .svelte-kit folder
    check_and_display "./.svelte-kit" ".svelte-kit"
  '';
in
pkg
// {
  passthru.tests = {
    basic = pkgs.runCommand "quick-results-test" { buildInputs = [ pkg ]; } ''
      set -e
      # Should print something about missing directories (since they likely don't exist in the build sandbox)
      quick-results > $out
      grep -q "No cargo target directory found" $out
      grep -q "No nix result directory found" $out
      grep -q "No nix result-man directory found" $out
    '';
  };
}
