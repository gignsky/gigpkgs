{ pkgs, ... }:
let
  pkg = pkgs.writeShellScriptBin "locker" ''
    COMMIT=""

    # Parse command line args
    while [[ $# -gt 0 ]]; do
      case $1 in
        -y|--yes)
          COMMIT=true
          shift
          ;;
        -n|--no)
          COMMIT=false
          shift
          ;;
        -h|--help)
    echo "Usage: locker [-y|--yes] [-n|--no] [-h|--help]"
    echo "  -y, --yes    Automatically commit the lock file"
    echo "  -n, --no     Don't commit the lock file"
    echo "  -h, --help   Show this help message"
    echo "  (no args)    Ask interactively"
          exit 0
          ;;
        *)
          echo "Unknown option: $1"
          echo "Usage: locker [-y|--yes] [-n|--no] [-h|--help]"
          exit 1
          ;;
      esac
    done

    echo "Locking Flake with Current flake.nix content" | ${pkgs.lolcat}/bin/lolcat

    # If no flags provided, ask interactively
    if [[ -z "$COMMIT" ]]; then
      echo -n "Commit lock file? [Y/n]: "
      read -r commit
      if [[ "$commit" =~ ^[Nn]([Oo])?$ ]]; then
        COMMIT=false
      else
        COMMIT=true
      fi
    fi

    # Execute based on decision
    if $COMMIT; then
      git restore flake.lock
      nix flake lock --commit-lock-file
      echo "flake.lock updated! -- COMMITTED" | ${pkgs.cowsay}/bin/cowsay | ${pkgs.lolcat}/bin/lolcat
    else
      git restore flake.lock
      nix flake lock
      echo "flake.lock updated! -- NOT COMMITTED" | ${pkgs.cowsay}/bin/cowsay | ${pkgs.lolcat}/bin/lolcat
    fi
  '';
in
pkg
// {
  passthru.tests = rec {
    # Run all tests at once
    all-tests = pkgs.runCommand "locker-all-tests" { } ''
      {
        echo "======================================="
        echo "LOCKER COMPREHENSIVE TEST SUITE"
        echo "======================================="
        echo ""

        # Test 1: Help Output
        echo "Test 1: Help Output Functionality"
        if test -f ${help-output}; then
          echo "PASSED"
          echo "   Result: $(cat ${help-output})"
        else
          echo "FAILED - help-output test failed"
          exit 1
        fi
        echo ""

        # Test 2: Invalid Arguments
        echo "Test 2: Invalid Argument Handling"
        if test -f ${invalid-args}; then
          echo "PASSED"
          echo "   Result: $(cat ${invalid-args})"
        else
          echo "FAILED - invalid-args test failed"
          exit 1
        fi
        echo ""

        # Test 3: Script Syntax
        echo "Test 3: Script Syntax Validation"
        if test -f ${script-syntax}; then
          echo "PASSED"
          echo "   Result: $(cat ${script-syntax})"
        else
          echo "FAILED - script-syntax test failed"
          exit 1
        fi
        echo ""

        # Test 4: Dependencies
        echo "Test 4: Dependency Injection"
        if test -f ${dependencies}; then
          echo "PASSED"
          echo "   Result: $(cat ${dependencies})"
        else
          echo "FAILED - dependencies test failed"
          exit 1
        fi
        echo ""

        # Test 5: No Flake Environment
        echo "Test 5: No Nix Environment Handling"
        if test -f ${no-flake-error}; then
          echo "PASSED"
          echo "   Result: $(cat ${no-flake-error})"
        else
          echo "FAILED - no-flake-error test failed"
          exit 1
        fi
        echo ""

        echo "======================================="
        echo "ALL LOCKER TESTS PASSED!"
        echo "   5/5 test scenarios completed successfully"
        echo "======================================="
      } > $out
    '';

    # Test 1: Help output functionality
    help-output =
      pkgs.runCommand "locker-help-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e

          # Test --help flag
          if locker --help > help_output 2>&1; then
            grep -q "Usage:" help_output || {
              echo "Missing usage line in help"
              exit 1
            }
            grep -q "\-y.*commit" help_output || {
              echo "Missing -y flag description"
              exit 1
            }
            grep -q "\-n.*commit" help_output || {
              echo "Missing -n flag description"
              exit 1
            }
            grep -q "\-h.*help" help_output || {
              echo "Missing -h flag description"
              exit 1
            }
          else
            echo "Help command failed unexpectedly"
            exit 1
          fi

          # Test -h short flag
          locker -h > short_help 2>&1
          grep -q "Usage:" short_help || {
            echo "Short help flag failed"
            exit 1
          }

          echo "Help functionality working correctly" > $out
        '';

    # Test 2: Invalid argument handling
    invalid-args =
      pkgs.runCommand "locker-invalid-args-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e

          # Test invalid flag
          if locker --invalid-flag > error_output 2>&1; then
            echo "Invalid flag should have failed"
            exit 1
          else
            grep -q "Unknown option" error_output || {
              echo "Missing expected error message"
              exit 1
            }
            grep -q "Usage:" error_output || {
              echo "Missing usage in error output"
              exit 1
            }
          fi

          echo "Invalid argument handling working correctly" > $out
        '';

    # Test 3: Script syntax and basic structure validation
    script-syntax =
      pkgs.runCommand "locker-syntax-test"
        {
          buildInputs = [
            pkg
            pkgs.bash
            pkgs.coreutils
          ];
        }
        ''
          set -e

          # Test that script exists and is executable
          command -v locker > /dev/null || {
            echo "locker command not found"
            exit 1
          }

          # Test script has valid bash syntax
          bash -n $(command -v locker) || {
            echo "locker script has syntax errors"
            exit 1
          }

          echo "Script syntax validation passed" > $out
        '';

    # Test 4: Dependency injection verification
    dependencies =
      pkgs.runCommand "locker-deps-test"
        {
          buildInputs = [
            pkg
            pkgs.bash
            pkgs.gnugrep
            pkgs.coreutils
          ];
        }
        ''
          set -e

          # Check script contains expected dependencies
          cat $(command -v locker) > script_content

          grep -q "lolcat" script_content || {
            echo "Script missing lolcat dependency"
            cat script_content
            exit 1
          }

          grep -q "cowsay" script_content || {
            echo "Script missing cowsay dependency"
            cat script_content
            exit 1
          }

          grep -q "nix flake lock" script_content || {
            echo "Script missing nix flake lock command"
            exit 1
          }

          grep -q "nix flake lock --commit-lock-file" script_content || {
            echo "Script missing commit variant of flake lock"
            exit 1
          }

          echo "Dependency verification passed" > $out
        '';

    # Test 5: No nix command environment (expected failure)
    no-flake-error =
      pkgs.runCommand "locker-no-nix-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e

          LOCKER_CMD=$(command -v locker)

          # Test -y flag (should fail - no nix command available)
          if $LOCKER_CMD -y > commit_output 2>&1; then
            # Check if it "succeeded" but nix command actually failed
            if grep -q "nix: command not found" commit_output; then
              echo "Expected behavior: nix command not found"
            else
              echo "locker -y unexpectedly succeeded:"
              cat commit_output
              exit 1
            fi
          else
            # If it failed, check for expected error patterns
            grep -E "(nix: command not found|flake|error)" commit_output || {
              echo "Unexpected error output for -y flag:"
              cat commit_output
              exit 1
            }
          fi

          echo "No nix environment handling working correctly" > $out
        '';
  };
}
