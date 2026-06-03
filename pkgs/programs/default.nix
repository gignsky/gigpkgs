{
  pkgs,
  newsJson ? null,
  ...
}:
{
  cargo-update = import ./cargo-update.nix { inherit pkgs; };
  gignews =
    if newsJson != null then
      import ./gignews {
        inherit pkgs;
        inherit (pkgs) lib;
        inherit newsJson;
      }
    else
      pkgs.writeShellScriptBin "gignews" ''
        echo "gigpkgs-news: newsJson not provided, cannot build package"
        exit 1
      '';
  locker = import ./locker.nix { inherit pkgs; };
  quick-results = import ./quick-results.nix { inherit pkgs; };
  supertree = import ./supertree.nix { inherit pkgs; };
  upflake = import ./upflake.nix { inherit pkgs; };
  upignore = import ./upignore.nix { inherit pkgs; };
  upjust = import ./upjust.nix { inherit pkgs; };
}
