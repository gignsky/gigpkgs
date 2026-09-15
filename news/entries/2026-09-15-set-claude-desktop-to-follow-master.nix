{
  id = "2026-09-15-set-claude-desktop-to-follow-master";
  num = 33;
  date = "2026-09-15";
  timestamp = "2026-09-15T19:18:27Z";
  message = ''
    Claude-Desktop now follows `nixpkgs-master`

    Rather than following the user's nixpkgs pinned version the claude-desktop input now
    follows the `nixpkgs-master` flake input to follow the unstable branch of things.
  '';
}
