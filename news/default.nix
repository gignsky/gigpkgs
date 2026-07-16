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

  # Every entry must carry a `num` — a short, stable integer id used to mark
  # entries read without typing the full string id. Collect them, failing the
  # build if any entry is missing one.
  entryNums = map (
    entry:
    if entry ? num then
      entry.num
    else
      throw "gignews: news entry '${entry.id}' is missing the required 'num' field"
  ) sortedEntries;

  # Validate that the `num` values are unique. Gate the entry list on this check
  # so any consumer (entries or json) triggers it.
  validatedEntries =
    if (builtins.length entryNums) != (builtins.length (lib.unique entryNums)) then
      throw "gignews: news entries contain duplicate 'num' values: ${builtins.toJSON entryNums}"
    else
      sortedEntries;

in
{
  # The list of applicable news entries
  entries = validatedEntries;

  # Generate a JSON file containing all news entries
  # This is used by the CLI and activation script
  json = pkgs.writeText "gignews.json" (builtins.toJSON validatedEntries);

  # For testing: return the raw list
  inherit allEntries applicableEntries;
}
