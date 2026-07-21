{ pkgs }:
let
  inherit (pkgs) lib;

  # Shared library lives with inputMan; inputman-lite sources the SAME file so
  # the flake.nix patcher and marker/anchor helpers stay single-sourced.
  inputmanLib = ../inputMan/inputman-lib.sh;

  pkg = pkgs.stdenv.mkDerivation {
    pname = "inputman-lite";
    version = "0.1.0";

    src = ./.;

    nativeBuildInputs = [ pkgs.makeWrapper ];

    installPhase = ''
      mkdir -p $out/bin $out/libexec
      cp ${inputmanLib} $out/libexec/inputman-lib.sh
      substitute ${./inputman-lite.sh} $out/bin/inputman-lite \
        --subst-var-by INPUTMAN_LIB "$out/libexec/inputman-lib.sh"
      chmod +x $out/bin/inputman-lite

      wrapProgram $out/bin/inputman-lite \
        --prefix PATH : ${
          lib.makeBinPath [
            pkgs.nix
            pkgs.git
            pkgs.jq
            pkgs.perl
            pkgs.locker
            pkgs.fupdate
          ]
        }
    '';

    meta = {
      description = "Slim consumer companion to inputMan: toggle local dev of a gigpkgs-provided program";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  };
in
pkg
// {
  passthru.tests = {
    help-output =
      pkgs.runCommand "inputman-lite-help-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          inputman-lite --help > help_output
          grep -q "dev <prog>" help_output
          grep -q "promote <prog>" help_output
          grep -q -- "--local <path>" help_output
          grep -q -- "--remote <url>" help_output
          echo "help verified" > $out
        '';

    unknown-command =
      pkgs.runCommand "inputman-lite-unknown-command-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          if inputman-lite bogus-cmd > output 2>&1; then
            echo "unknown command should fail"; cat output; exit 1
          fi
          grep -q "Unknown command" output
          echo "unknown command verified" > $out
        '';

    render-pkgs-shadow =
      pkgs.runCommand "inputman-lite-render-shadow-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          inputman-lite __render-pkgs-shadow roll-flow roll-flow-local > shadow
          grep -q "inputman-lite:begin roll-flow-local" shadow
          grep -q "inputman-lite:end roll-flow-local" shadow
          grep -q 'roll-flow = inputs.roll-flow-local.packages.''${system}.default;' shadow
          grep -q 'unstable = (inputs.gigpkgs.legacyPackages.''${system}.unstable or { })' shadow
          echo "render verified" > $out
        '';

    # Full anchor round-trip: insert the shadow after the anchor, assert it lands
    # between the anchor and the `;`, then remove it and assert the file returns
    # to its original shape. Uses inputMan's generic helpers (same shared lib).
    dev-promote-roundtrip =
      pkgs.runCommand "inputman-lite-roundtrip-test"
        {
          buildInputs = [
            pkg
            pkgs.inputman
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          workdir=$(mktemp -d); cd "$workdir"
          cat > flake.nix <<'FLAKE'
          {
            outputs = { self, ... }:
              let
                pkgs = base // custom
                  # inputman-lite:pkgs-anchor
                  ;
              in { inherit pkgs; };
          }
          FLAKE
          orig=$(cat flake.nix)

          shadow=$(inputman-lite __render-pkgs-shadow roll-flow roll-flow-local)
          inputman __insert-after-anchor flake.nix "# inputman-lite:pkgs-anchor" "$shadow
          "
          grep -q "inputman-lite:begin roll-flow-local" flake.nix
          grep -q 'roll-flow = inputs.roll-flow-local.packages' flake.nix
          # the anchor must precede the inserted shadow block
          a=$(grep -n "pkgs-anchor" flake.nix | head -1 | cut -d: -f1)
          b=$(grep -n "begin roll-flow-local" flake.nix | head -1 | cut -d: -f1)
          test "$a" -lt "$b"

          inputman __remove-marker-block flake.nix "# inputman-lite:begin roll-flow-local" "# inputman-lite:end roll-flow-local"
          if grep -q "roll-flow-local" flake.nix; then
            echo "shadow not fully removed"; cat flake.nix; exit 1
          fi
          test "$(cat flake.nix)" = "$orig"
          echo "roundtrip verified" > $out
        '';

    script-syntax =
      pkgs.runCommand "inputman-lite-syntax-test"
        {
          buildInputs = [
            pkg
            pkgs.bash
          ];
        }
        ''
          set -e
          bash -n $(command -v inputman-lite)
          echo "syntax verified" > $out
        '';

    shellcheck =
      pkgs.runCommand "inputman-lite-shellcheck-test"
        {
          buildInputs = [ pkgs.shellcheck ];
        }
        ''
          set -e
          workdir=$(mktemp -d)
          cp ${inputmanLib} "$workdir/inputman-lib.sh"
          sed 's|@INPUTMAN_LIB@|inputman-lib.sh|' ${./inputman-lite.sh} > "$workdir/inputman-lite"
          cd "$workdir"
          shellcheck -x inputman-lite
          echo "shellcheck passed" > $out
        '';
  };
}
