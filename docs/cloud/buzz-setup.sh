#!/usr/bin/env bash
# Setup script for the "buzz" cloud environment (Claude Code on the web).
#
# Where it goes: claude.ai/code -> environment selector -> buzz -> edit ->
#                "Setup script" field. Paste this whole file.
#
# Target: gigpkgs plus general Nix / Rust development.
#
# Facts this script relies on (see docs/cloud-environments.md for sources):
#   * Runs as root on Ubuntu 24.04, once per environment-cache build. The
#     resulting /nix store is snapshotted, so later sessions start with it on
#     disk and this script is skipped (cache TTL ~7 days).
#   * The base image already ships Rust (rustc/cargo) and Python (pip, uv,
#     poetry, ruff, pytest, ...). It does NOT ship Nix, direnv or Nushell -
#     that is what we add here.
#   * TLS + egress proxy are already wired: HTTPS_PROXY and NIX_SSL_CERT_FILE
#     are pre-set in the environment and the system trust store already
#     contains the proxy CA, so Nix fetches succeed with no extra config.
#   * *.nixos.org (incl. cache.nixos.org / releases.nixos.org) and crates.io
#     are in the default "Trusted" network allowlist, so "Trusted" access is
#     enough for this script.
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Install Nix, single-user / daemonless.
#
#    Daemonless is deliberate: the install and all later builds run as root and
#    inherit HTTPS_PROXY + NIX_SSL_CERT_FILE, so substituter downloads work
#    through the egress proxy. A nix-daemon would run in its own environment,
#    would NOT inherit those variables, and its fetches would fail.
# ---------------------------------------------------------------------------
if ! command -v nix >/dev/null 2>&1 && [ ! -e /nix/var/nix/profiles/default/bin/nix ]; then
  sh <(curl --proto '=https' --tlsv1.2 -sSf -L https://nixos.org/nix/install) \
    --no-daemon --no-channel-add
fi

# Load Nix into this script's shell.
# shellcheck disable=SC1091
. "$HOME/.nix-profile/etc/profile.d/nix.sh"

# ---------------------------------------------------------------------------
# 2. Global Nix config: flakes on, plus CI-friendly defaults.
#    Nix reads /etc/nix/nix.conf in single-user mode too.
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/nix
cat > /etc/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
accept-flake-config = true
warn-dirty = false
max-jobs = auto
EOF

# ---------------------------------------------------------------------------
# 3. Handy CLIs from nixpkgs into the root profile:
#    direnv (+ nix-direnv, to make the repo's `use flake` fast), just, nushell.
# ---------------------------------------------------------------------------
nix profile install \
  nixpkgs#direnv \
  nixpkgs#nix-direnv \
  nixpkgs#just \
  nixpkgs#nushell || true

# Wire nix-direnv so the repo's .envrc (`use flake`) resolves quickly.
install -d -m 0755 "$HOME/.config/direnv"
if ! grep -q nix-direnv "$HOME/.config/direnv/direnvrc" 2>/dev/null; then
  echo 'source "$HOME/.nix-profile/share/nix-direnv/direnvrc"' \
    >> "$HOME/.config/direnv/direnvrc"
fi

# ---------------------------------------------------------------------------
# 4. Put Nix + the profile tools on the default PATH.
#    Claude's Bash tool runs non-login shells that never source
#    ~/.nix-profile/etc/profile.d/nix.sh, so symlink into /usr/local/bin,
#    which is always on PATH.
# ---------------------------------------------------------------------------
ln -sf /root/.nix-profile/bin/* /usr/local/bin/

# ---------------------------------------------------------------------------
# 5. Pre-warm the gigpkgs devShell so its inputs and custom packages
#    (locker, inputman, upjust, quick-results, nixfmt, statix, deadnix, ...)
#    are baked into the snapshot. Bounded + non-fatal so it can never block
#    session start; whatever it fetches before the timeout is still cached.
# ---------------------------------------------------------------------------
for d in "$PWD" /root/gigpkgs "$HOME/gigpkgs" /workspace/gigpkgs; do
  if [ -f "$d/flake.nix" ]; then
    ( cd "$d" && timeout 300 nix develop --command true ) || true
    break
  fi
done
