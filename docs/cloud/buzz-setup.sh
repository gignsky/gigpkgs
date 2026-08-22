#!/usr/bin/env bash
# =============================================================================
# Setup script for the "buzz" cloud environment (Claude Code on the web).
#
# Where it goes: claude.ai/code -> environment selector -> buzz -> edit ->
#                "Setup script" field. Paste this whole file.
#
# Goal: make `nix` fully usable for build / run / eval / flake operations. The
# flake devShell is intentionally NOT auto-loaded — the repo's devShell
# shellHook fetches github:cachix/git-hooks.nix (the pre-commit-hooks input),
# which the GitHub proxy 403s independent of network level. See
# docs/cloud-environments.md ("The devShell & the GitHub proxy") for the full
# root cause. Plain nix build/run/eval never need the devShell.
# =============================================================================
set -euo pipefail
echo "==> buzz nix setup starting"

# --- 1. Install Nix if absent (install-if-missing, NOT assert) --------------
#    The Claude Code cloud base image (Ubuntu 24.04) does NOT ship Nix. The
#    first successful run bakes /nix into the environment-cache snapshot, so on
#    a WARM cache this whole block is skipped; on a COLD cache (fresh env, or
#    after you edit this script, or ~7-day expiry) it installs. Do NOT replace
#    this with a bare `command -v nix || exit 1` assert: that hard-fails on
#    every cache rebuild because the base image has no Nix.
#
#    nix.conf is written FIRST so the installer's own bundled Nix does not
#    demand the nonexistent `nixbld` group when it runs as root
#    (`build-users-group =` -> build directly as root; `sandbox = false` ->
#    no namespace sandbox a container may forbid). The installer is pinned and
#    fetched from releases.nixos.org (a *.nixos.org subdomain, allowlisted);
#    the bare apex nixos.org is NOT covered by `*.nixos.org` and 403s.
if ! command -v nix >/dev/null 2>&1 && [ ! -e /nix/var/nix/profiles/default/bin/nix ]; then
  install -d -m 0755 /etc/nix
  cat > /etc/nix/nix.conf <<'EOF'
build-users-group =
sandbox = false
experimental-features = nix-command flakes fetch-tree
accept-flake-config = true
warn-dirty = false
max-jobs = auto
EOF
  NIX_VERSION="${NIX_VERSION:-2.31.2}"
  installer="$(mktemp)"
  curl --proto '=https' --tlsv1.2 -sSf -L \
    "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" -o "$installer"
  sh "$installer" --no-daemon --no-channel-add
  rm -f "$installer"
fi

# --- 2. Load Nix into this shell --------------------------------------------
#    nix.sh only exports PATH when $USER is set, and a non-login setup shell
#    may lack it; set USER/HOME and also prepend the profile bin directly.
export USER="${USER:-root}"
export HOME="${HOME:-/root}"
# shellcheck disable=SC1091
[ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && . "$HOME/.nix-profile/etc/profile.d/nix.sh"
export PATH="$HOME/.nix-profile/bin:$PATH"
# NOW it is safe to fail loud: if Nix is still missing, install genuinely broke.
command -v nix >/dev/null 2>&1 || { echo "ERROR: nix not on PATH after install step" >&2; exit 1; }
echo "    nix: $(nix --version)"

# --- 3. Ensure flake / nix-command features are on (idempotent) -------------
#    Covers a warm cache where step 1 was skipped.
install -d -m 0755 /etc/nix
grep -qs '^experimental-features' /etc/nix/nix.conf 2>/dev/null || \
  echo 'experimental-features = nix-command flakes fetch-tree' >> /etc/nix/nix.conf
echo "    experimental-features: $(nix config show experimental-features 2>/dev/null || echo '?')"

# --- 4. Handy CLIs from nixpkgs (idempotent) --------------------------------
#    direnv, just, nushell (+ nix-direnv for a fast `use flake` IF you ever
#    authorize the devShell's inputs and `direnv allow`). These substitute from
#    cache.nixos.org only, never github, so no 403.
nix profile install \
  nixpkgs#direnv \
  nixpkgs#nix-direnv \
  nixpkgs#just \
  nixpkgs#nushell 2>/dev/null || true
install -d -m 0755 "$HOME/.config/direnv"
if ! grep -q nix-direnv "$HOME/.config/direnv/direnvrc" 2>/dev/null; then
  # $HOME must stay literal — it is expanded by direnv at runtime, not now.
  # shellcheck disable=SC2016
  echo 'source "$HOME/.nix-profile/share/nix-direnv/direnvrc"' \
    >> "$HOME/.config/direnv/direnvrc"
fi
# Expose Nix + profile tools on the default PATH for Claude's non-login shells.
ln -sf "$HOME"/.nix-profile/bin/* /usr/local/bin/

# --- 5. Actively prevent the devShell from auto-loading ---------------------
#    The repo .envrc runs `use flake`; entering that devShell triggers the
#    shellHook -> github:cachix/git-hooks.nix -> 403. A stale `direnv allow`
#    can persist across sessions, so passively not-allowing is unreliable; we
#    REVOKE any existing allow. (`deny` on older direnv, `revoke` on newer.)
if command -v direnv >/dev/null 2>&1 && [ -f .envrc ]; then
  direnv deny . 2>/dev/null || direnv revoke . 2>/dev/null || true
  echo "    .envrc DENIED -> devShell will not auto-load on cd"
  echo "    (want it later? 'add_repo cachix/git-hooks.nix' then 'direnv allow',"
  echo "     or guard the flake.nix shellHook on CLAUDE_CODE_REMOTE)"
fi

# --- 6. Warm the flake metadata cache (safe) --------------------------------
#    Resolves inputs from flake.lock; touches the local flake + cache.nixos.org
#    only. Does NOT fetch the github devShell inputs, so no 403.
if [ -f flake.nix ]; then
  nix flake metadata >/dev/null 2>&1 || echo "    (flake metadata warm skipped)"
fi

echo "==> buzz nix setup complete: build/run/eval ready; devShell intentionally not auto-loaded"
