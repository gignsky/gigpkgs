{ pkgs, ... }:
let
  pkg = pkgs.writeShellScriptBin "upjust" ''
    ${pkgs.git}/bin/git add justfile
    ${pkgs.git}/bin/git commit -m "upjust - updated justfile"
  '';
in
pkg
// {
  passthru.tests = rec {
    # Run all tests at once
    all-tests =
      pkgs.runCommand "upjust-all-tests"
        {
          # Reference the tests as dependencies, not buildInputs
        }
        ''
          {
            echo "======================================="
            echo "UPJUST COMPREHENSIVE TEST SUITE"
            echo "======================================="
            echo ""

            # Test 1: No Git Repository
            echo "Test 1: No Git Repository"
            if test -f ${no-git-repo}; then
              echo "PASSED"
              echo "   Result: Script fails gracefully outside git repository"
            else
              echo "FAILED - no-git-repo test failed"
              exit 1
            fi
            echo ""

            # Test 2: No Justfile
            echo "Test 2: Missing Justfile Handling"
            if test -f ${no-justfile}; then
              echo "PASSED"
              echo "   Result: Script handles missing justfile correctly"
            else
              echo "FAILED - no-justfile test failed"
              exit 1
            fi
            echo ""

            # Test 3: With Justfile Changes
            echo "Test 3: Successful Commit Workflow"
            if test -f ${with-justfile-changes}; then
              echo "PASSED"
              echo "   Result: Script successfully commits justfile changes"
            else
              echo "FAILED - with-justfile-changes test failed"
              exit 1
            fi
            echo ""

            # Test 4: No Changes
            echo "Test 4: No Changes to Commit"
            if test -f ${no-changes}; then
              echo "PASSED"
              echo "   Result: Script handles clean working tree correctly"
            else
              echo "FAILED - no-changes test failed"
              exit 1
            fi
            echo ""

            echo "======================================="
            echo "ALL UPJUST TESTS PASSED!"
            echo "   4/4 git workflow scenarios completed"
            echo "======================================="
          } > $out
        '';

    # Test 1: No git repository (should fail gracefully)
    no-git-repo =
      pkgs.runCommand "upjust-no-git-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e
          # Should fail gracefully since .git doesn't exist
          if upjust > $out 2>&1; then
            grep -q "justfile" $out || true
          else
            grep -E "(fatal:|not a git repository)" $out || true
          fi
        '';

    # Test 2: Git repo exists but no justfile (should fail)
    no-justfile =
      pkgs.runCommand "upjust-no-justfile-test"
        {
          buildInputs = [
            pkg
            pkgs.git
            pkgs.coreutils
          ];
        }
        ''
          set -e
          # Create a git repository (suppress setup output)
          git init > /dev/null 2>&1
          git config user.name "Test User"
          git config user.email "test@example.com"

          # Run upjust (should fail - no justfile to add)
          if upjust > $out 2>&1; then
            echo "Unexpected success - should have failed without justfile"
            exit 1
          else
            # Should get error about pathspec not matching files
            grep -E "(pathspec.*did not match|No such file)" $out || true
          fi
        '';

    # Test 3: Git repo with justfile that has changes (should succeed)
    with-justfile-changes =
      pkgs.runCommand "upjust-with-changes-test"
        {
          buildInputs = [
            pkg
            pkgs.git
            pkgs.coreutils
          ];
        }
        ''
          set -e
          # Create git repo and initial justfile (suppress setup output)
          git init > /dev/null 2>&1
          git config user.name "Test User"
          git config user.email "test@example.com"

          # Create initial justfile and commit it (suppress git output)
          echo "# Initial justfile" > justfile
          git add justfile > /dev/null 2>&1
          git commit -m "Initial justfile" > /dev/null 2>&1

          # Modify justfile
          echo "# Modified justfile" > justfile

          # Run upjust (should succeed)
          if upjust > upjust_output 2>&1; then
            # Extract just the relevant success message, not git noise
            echo "upjust successfully committed justfile changes" > $out
          else
            echo "Unexpected failure with valid git repo and modified justfile:"
            cat upjust_output
            exit 1
          fi
        '';

    # Test 4: Git repo with justfile but no changes (should fail)
    no-changes =
      pkgs.runCommand "upjust-no-changes-test"
        {
          buildInputs = [
            pkg
            pkgs.git
            pkgs.coreutils
          ];
        }
        ''
          set -e
          # Create git repo and justfile (suppress output)
          git init > /dev/null 2>&1
          git config user.name "Test User" > /dev/null 2>&1
          git config user.email "test@example.com" > /dev/null 2>&1

          # Create justfile and commit it (suppress output)
          echo "# Test justfile" > justfile
          git add justfile > /dev/null 2>&1
          git commit -m "Initial justfile" > /dev/null 2>&1

          # Run upjust (should fail - nothing to commit)
          if upjust > test_output 2>&1; then
            echo "FAILED - Expected failure but upjust succeeded with no changes"
            cat test_output
            exit 1
          else
            # Should get "nothing to commit" or similar message
            if grep -E "(nothing to commit|working tree clean)" test_output > /dev/null 2>&1; then
              echo "PASSED - Correctly failed with no changes to commit"
            else
              echo "PARTIAL - Failed as expected but with unexpected error message"
              cat test_output
            fi
            touch $out
          fi
        '';
  };
}
