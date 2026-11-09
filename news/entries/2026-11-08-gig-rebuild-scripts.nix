{
  id = "2026-11-08-gig-rebuild-scripts";
  num = 65;
  date = "2026-11-08";
  timestamp = "2026-11-08T21:15:00Z";
  message = ''
    New packages: `gig-nixos-rebuild` and `gig-home-switch`

    The dotfiles repo's NixOS and home-manager rebuild scripts now live in
    gigpkgs, so other tools can depend on them — roll-flow's `n` rebuild menu
    among them. Run them from inside a flake checkout, as before: they build
    `.#<host>` from the current directory and commit a generation marker
    (`<host>: generation N (<mode>)`, `<user>@<host>: ...`).

    They are named `gig-*` rather than `nixos-rebuild` / `home-switch` so they
    never shadow nixpkgs' own `nixos-rebuild`, which the system script calls.
  '';
}
