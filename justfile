
default:
	# @just --list | bat --file-name "justfile"
	@just --choose

#perform a lock update
lock:
  @nix-shell -p lolcat --run "echo 'Locking Nix Flake & Commiting Lock File' | lolcat 2> /dev/null"
  nix flake lock --commit-lock-file
  @nix-shell -p lolcat --run "echo 'For your convience, the two most recent git commit have been posted below:' | lolcat 2> /dev/null"
  git log -2

# Update the flake
update:
	nix flake update --commit-lock-file

update-no-commit:
	nix flake update

pre-commit:
  pre-commit run --all-files
