{ pkgs }:
let
  pkg = pkgs.stdenv.mkDerivation {
    pname = "inputman";
    version = "0.2.0";

    src = ./.;

    nativeBuildInputs = [ pkgs.makeWrapper ];

    installPhase = ''
      mkdir -p $out/bin $out/libexec
      cp ${./inputman-lib.sh} $out/libexec/inputman-lib.sh
      substitute ${./inputMan.sh} $out/bin/inputman \
        --subst-var-by INPUTMAN_LIB "$out/libexec/inputman-lib.sh"
      chmod +x $out/bin/inputman

      wrapProgram $out/bin/inputman \
        --prefix PATH : ${
          pkgs.lib.makeBinPath [
            pkgs.nix
            pkgs.git
            pkgs.jq
            pkgs.perl
            pkgs.pre-commit
            pkgs.locker
            pkgs.fupdate
          ]
        }
    '';

    meta = {
      description = "Manage flake inputs for gigpkgs";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.unix;
    };
  };
in
pkg
// {
  passthru.tests = {
    help-output =
      pkgs.runCommand "inputman-help-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          inputman --help > help_output

          grep -q "install <url>" help_output
          grep -q "update <name>" help_output
          grep -q "remove <name>" help_output
          grep -q -- "--follows" help_output
          grep -q -- "--packages, -p" help_output
          grep -q -- "--no-info" help_output
          grep -q -- "--no-branch" help_output
          grep -q -- "--no-modules" help_output
          grep -q -- "--no-commit" help_output

          echo "Help output verified" > $out
        '';

    unknown-command =
      pkgs.runCommand "inputman-unknown-command-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          if inputman unknown-subcommand > output 2>&1; then
            echo "Unknown subcommand should fail"
            cat output
            exit 1
          fi

          grep -q "Unknown command" output
          echo "Unknown command handling verified" > $out
        '';

    infer-name =
      pkgs.runCommand "inputman-infer-name-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e
          actual=$(inputman __infer-name "github:gignsky/gigvim?ref=main")
          test "$actual" = "gigvim"
          echo "infer_name verified" > $out
        '';

    discover-fallback =
      pkgs.runCommand "inputman-discover-fallback-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          inputman __discover-packages "not-a-valid-flake-url" "x86_64-linux" > output 2> errors
          grep -q "^default$" output
          grep -q "falling back\|No packages discovered" errors
          echo "discover_packages fallback verified" > $out
        '';

    parse-packages-spec =
      pkgs.runCommand "inputman-parse-packages-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          # Legacy include list (no '=')
          inputman __parse-packages-spec myinput "default,cli" > out1
          grep -q "^default=myinput$" out1
          grep -q "^cli=myinput-cli$" out1

          # Key=value aliasing
          inputman __parse-packages-spec myinput "default=app,cli=mycli" > out2
          grep -q "^default=app$" out2
          grep -q "^cli=mycli$" out2

          # Exclusion via '-'
          inputman __parse-packages-spec myinput "default=app,legacy=-" > out3
          grep -q "^default=app$" out3
          if grep -q "legacy" out3; then
            echo "exclusion (=-) not honored"; exit 1
          fi

          echo "parse_packages_spec verified" > $out
        '';

    patch-flake-add =
      pkgs.runCommand "inputman-patch-flake-add-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          workdir=$(mktemp -d)
          cd "$workdir"

          cat > flake.nix <<'FLAKE'
          {
              inputs = {
                  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
                  # keep this comment near closing
              };
              outputs = { self, ... }: { };
          }
          FLAKE

          inputman __patch-flake-add gigvim github:gignsky/gigvim nixpkgs=nixpkgs

          grep -q 'gigvim.url = "github:gignsky/gigvim";' flake.nix
          grep -q 'gigvim.inputs.nixpkgs.follows = "nixpkgs";' flake.nix
          grep -q '# keep this comment near closing' flake.nix

          echo "patch_flake_add verified" > $out
        '';

    patch-flake-add-nested-follows =
      pkgs.runCommand "inputman-patch-flake-nested-follows-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          workdir=$(mktemp -d)
          cd "$workdir"

          cat > flake.nix <<'FLAKE'
          {
              inputs = {
                  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
              };
              outputs = { self, ... }: { };
          }
          FLAKE

          # Slash-separated nested follows
          inputman __patch-flake-add roll-flow github:gignsky/roll-flow gigpkgs/nixpkgs=nixpkgs-master
          grep -q 'roll-flow.inputs.gigpkgs.inputs.nixpkgs.follows = "nixpkgs-master";' flake.nix

          # Dot-separated nested follows
          inputman __patch-flake-add other github:foo/other a.b.c=target
          grep -q 'other.inputs.a.inputs.b.inputs.c.follows = "target";' flake.nix

          # Empty follows (bare -f)
          inputman __patch-flake-add self-follow github:foo/self gigpkgs=
          grep -q 'self-follow.inputs.gigpkgs.follows = "";' flake.nix

          echo "nested follows verified" > $out
        '';

    patch-flake-remove-nested =
      pkgs.runCommand "inputman-patch-flake-remove-nested-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          workdir=$(mktemp -d)
          cd "$workdir"

          cat > flake.nix <<'FLAKE'
          {
              inputs = {
                  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
                  gigvim.url = "github:gignsky/gigvim";
                  gigvim.inputs.nixpkgs.follows = "nixpkgs";
                  gigvim.inputs.gigpkgs.inputs.nixpkgs.follows = "nixpkgs";
              };
              outputs = { self, ... }: { };
          }
          FLAKE

          inputman __patch-flake-remove gigvim

          if grep -q 'gigvim' flake.nix; then
            echo "gigvim references should be gone"; cat flake.nix; exit 1
          fi
          grep -q 'nixpkgs.url' flake.nix
          echo "nested follows remove verified" > $out
        '';

    self-name =
      pkgs.runCommand "inputman-self-name-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e
          workdir=$(mktemp -d)/gigpkgs-fixture
          mkdir -p "$workdir"
          cd "$workdir"
          actual=$(inputman __self-name)
          test "$actual" = "gigpkgs-fixture"
          echo "self_name verified" > $out
        '';

    script-syntax =
      pkgs.runCommand "inputman-syntax-test"
        {
          buildInputs = [
            pkg
            pkgs.bash
          ];
        }
        ''
          set -e
          bash -n $(command -v inputman)
          echo "Script syntax verified" > $out
        '';

    dependencies =
      pkgs.runCommand "inputman-dependencies-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e
          command -v inputman > /dev/null
          command -v nix > /dev/null
          command -v git > /dev/null
          command -v jq > /dev/null
          command -v perl > /dev/null
          echo "Runtime dependencies verified" > $out
        '';

    shellcheck =
      pkgs.runCommand "inputman-shellcheck-test"
        {
          buildInputs = [ pkgs.shellcheck ];
        }
        ''
          set -e
          workdir=$(mktemp -d)
          cp ${./inputman-lib.sh} "$workdir/inputman-lib.sh"
          # Materialize the source path so `shellcheck -x` can follow it.
          sed 's|@INPUTMAN_LIB@|inputman-lib.sh|' ${./inputMan.sh} > "$workdir/inputman"
          cd "$workdir"
          shellcheck -x inputman inputman-lib.sh
          echo "shellcheck passed" > $out
        '';

    slug-version =
      pkgs.runCommand "inputman-slug-version-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          test "$(inputman __slug-version v0.2.99)" = "v0-2-99"
          test "$(inputman __slug-version develop)" = "develop"
          # invalid slug (leading digit) must fail
          if inputman __slug-version 1.2.3 > /dev/null 2>&1; then
            echo "expected slug_version to reject '1.2.3'"; exit 1
          fi
          echo "slug_version verified" > $out
        '';

    channel-map-set =
      pkgs.runCommand "inputman-channel-map-set-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          workdir=$(mktemp -d)
          cd "$workdir"

          cat > channel-sources.nix <<'MAP'
          {
            roll-flow = {
              "nixos-unstable" = "roll-flow-develop";
              "nixos-2605" = "roll-flow-main";
              default = "roll-flow-main";
            };
          }
          MAP

          # Replace an existing channel entry.
          inputman __patch-channel-map-set roll-flow nixos-2605 roll-flow-frozen-v0-2-99
          grep -q '"nixos-2605" = "roll-flow-frozen-v0-2-99";' channel-sources.nix
          grep -q '"nixos-unstable" = "roll-flow-develop";' channel-sources.nix
          grep -q 'default = "roll-flow-main";' channel-sources.nix

          # Insert a brand-new channel entry (before default).
          inputman __patch-channel-map-set roll-flow nixos-stable roll-flow-main
          grep -q '"nixos-stable" = "roll-flow-main";' channel-sources.nix

          # Auto-create a block for a program with no block yet.
          inputman __ensure-channel-map-block gigvim
          inputman __patch-channel-map-set gigvim nixos-unstable gigvim-develop
          grep -q '"nixos-unstable" = "gigvim-develop";' channel-sources.nix

          echo "channel_map_set verified" > $out
        '';

    freeze-patch =
      pkgs.runCommand "inputman-freeze-patch-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          workdir=$(mktemp -d)
          cd "$workdir"

          cat > flake.nix <<'FLAKE'
          {
              inputs = {
                  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
                  roll-flow-main.url = "github:gignsky/roll-flow/main";
              };
              outputs = { self, ... }: { };
          }
          FLAKE

          cat > channel-sources.nix <<'MAP'
          {
            roll-flow = {
              "nixos-2605" = "roll-flow-main";
              default = "roll-flow-main";
            };
          }
          MAP

          # Freeze to an explicit tag (no flake.lock needed for --tag path); use
          # the internal patchers directly since `freeze` also invokes locker/nix.
          inputman __patch-flake-add roll-flow-frozen-v0-2-99 github:gignsky/roll-flow/v0.2.99 nixpkgs=nixpkgs
          inputman __patch-channel-map-set roll-flow nixos-2605 roll-flow-frozen-v0-2-99

          grep -q 'roll-flow-frozen-v0-2-99.url = "github:gignsky/roll-flow/v0.2.99";' flake.nix
          grep -q 'roll-flow-frozen-v0-2-99.inputs.nixpkgs.follows = "nixpkgs";' flake.nix
          grep -q '"nixos-2605" = "roll-flow-frozen-v0-2-99";' channel-sources.nix

          echo "freeze_patch verified" > $out
        '';

    generate-group-aggregator =
      pkgs.runCommand "inputman-group-aggregator-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          inputman __generate-group-aggregator roll-flow > agg.nix
          grep -q 'channel   = import ../../channel.nix;' agg.nix
          grep -q '(import ../../channel-sources.nix).roll-flow;' agg.nix
          grep -q 'roll-flow = src.packages.''${system}.default;' agg.nix
          echo "group_aggregator verified" > $out
        '';
  };
}
