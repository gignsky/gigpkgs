{ lib, ... }:
{
  # Returns a list of absolute paths to all .nix files and directories in `path`,
  # excluding default.nix. Useful for auto-importing a directory of modules.
  scanPaths =
    path:
    builtins.map (f: (path + "/${f}")) (
      builtins.attrNames (
        lib.attrsets.filterAttrs (
          name: type:
          (type == "directory") || ((name != "default.nix") && (lib.strings.hasSuffix ".nix" name))
        ) (builtins.readDir path)
      )
    );

  # Returns all .nu file contents in `path` concatenated into one string.
  # Suitable for direct interpolation into nushell extraConfig.
  scanPathsNuShell =
    path:
    let
      dirContents = builtins.readDir path;
      nuFileNames = lib.filter (name: lib.hasSuffix ".nu" name) (lib.attrNames dirContents);
      fileContentList = lib.map (name: builtins.readFile (path + "/${name}")) nuFileNames;
    in
    lib.concatStringsSep "\n\n" fileContentList;
}
