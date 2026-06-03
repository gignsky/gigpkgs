# Gigpkgs News System
#
# Collects all news entries, evaluates conditions, and provides mechanisms
# for generating news JSON for consumption by the CLI and HM activation.

{
  lib,
  pkgs,
  config ? { },
}:
let
  gigLib = import ../lib { inherit lib; };

  # Import all news entry files
  entryPaths = gigLib.scanPaths ./entries;
  allEntries = map import entryPaths;

  # Filter entries based on their condition (if present)
  # Conditions that reference unavailable context default to true
  applicableEntries = builtins.filter (
    entry:
    if entry ? condition then
      (
        # Try to evaluate condition, fall back to true if context unavailable
        let
          evalResult = builtins.tryEval (
            entry.condition {
              inherit
                pkgs
                config
                lib
                ;
            }
          );
        in
        if evalResult.success then evalResult.value else true
      )
    else
      true
  ) allEntries;

  # Sort entries by date (newest first)
  sortedEntries = lib.sort (a: b: a.date > b.date) applicableEntries;

in
{
  # The list of applicable news entries
  entries = sortedEntries;

  # Generate a JSON file containing all news entries
  # This is used by the CLI and activation script
  json = pkgs.writeText "gigpkgs-news.json" (builtins.toJSON sortedEntries);

  # For testing: return the raw list
  inherit allEntries applicableEntries;
}
