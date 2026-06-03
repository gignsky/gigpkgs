{
  id = "2026-06-03-removed-gigvim";
  date = "2026-06-03";
  message = ''
    Removed flake input: gigvim

    The following input has been removed from gigpkgs:
      Source: github:gignsky/gigvim

    Any packages previously exposed from this input are no longer available.

    Removed via: gigpkgs-input remove
  '';
}
