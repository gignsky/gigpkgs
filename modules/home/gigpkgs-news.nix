# Home Manager module for gigpkgs-news
#
# Displays unread news entries during home-manager activation.
# Users can disable this with: gigpkgs.news.enable = false;

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.gigpkgs.news;

  # Import the news system to get the JSON path
  # This will be overridden by the flake if gigpkgs is used as an input
  news =
    if config.gigpkgs.news.newsJson != null then
      config.gigpkgs.news.newsJson
    else
      # Fallback: build news from source (used when testing or developing)
      (import ../../news { inherit lib pkgs; }).json;

  # Build gigpkgs-news package with the news JSON
  gigpkgs-news = pkgs.callPackage ../../pkgs/programs/gigpkgs-news {
    newsJson = news;
  };

in
{
  options.gigpkgs.news = {
    enable = lib.mkEnableOption "gigpkgs news on home-manager activation" // {
      default = true;
    };

    newsJson = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to the news JSON file (automatically set by gigpkgs flake)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Make gigpkgs-news available in user's PATH
    home.packages = [ gigpkgs-news ];

    # Show unread news during activation
    home.activation.gigpkgsNews = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${gigpkgs-news}/bin/gigpkgs-news
    '';
  };
}
