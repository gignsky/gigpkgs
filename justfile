
default:
	# @just --list | bat --file-name "justfile"
	@just --choose

#perform a lock update
lock:
  @nix-shell -p lolcat --run "echo 'Locking Nix Flake & Commiting Lock File' | lolcat 2> /dev/null"
  nix flake lock --commit-lock-file
  @nix-shell -p lolcat --run "echo 'For your convience, the two most recent git commit have been posted below:' | lolcat 2> /dev/null"
  git log -2

# Update the flake, write gignews entries for what changed, and commit
update:
	#!/usr/bin/env bash
	set -euo pipefail
	# Resolve inputman against the CURRENT lock, before the update moves it.
	if command -v inputman >/dev/null; then im=inputman
	else im="$(nix build .#inputman --no-link --print-out-paths)/bin/inputman"; fi
	snap=$(mktemp -d); trap 'rm -rf "$snap"' EXIT
	"$im" __flake-update-snapshot "$snap"
	nix flake update
	if git diff --quiet -- flake.lock; then echo "No flake inputs changed."; exit 0; fi
	summary=$("$im" __lock-diff "$snap/flake.lock" flake.lock)
	news=$("$im" __flake-update-news "$snap")
	mapfile -t written <<<"$news"
	git add flake.lock "${written[@]}"
	git commit -m "flake.lock: Update" -m "$summary"

update-no-commit:
	nix flake update

pre-commit:
  pre-commit run --all-files
