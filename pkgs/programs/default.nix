{ pkgs, ... }:
{
  cargo-update = import ./cargo-update.nix { inherit pkgs; };
  locker = import ./locker.nix { inherit pkgs; };
  quick-results = import ./quick-results.nix { inherit pkgs; };
  supertree = import ./supertree.nix { inherit pkgs; };
  upflake = import ./upflake.nix { inherit pkgs; };
  upignore = import ./upignore.nix { inherit pkgs; };
  upjust = import ./upjust.nix { inherit pkgs; };
}
