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
#     are pre-set and the system trust store already contains the proxy CA, so
#     Nix fetches through the proxy with no extra config.
#   * *.nixos.org (incl. cache.nixos.org / releases.nixos.org) and crates.io
#     are in the default "Trusted" network allowlist, so "Trusted" is enough.
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Write /etc/nix/nix.conf BEFORE installing.
#
#    This is the fix for the "group 'nixbld' ... does not exist" failure: Nix's
#    compiled-in default is `build-users-group = nixbld`, and when Nix runs as
#    root it tries to drop to a build user in that group. In a single-user
#    install there is no nixbld group, so the install aborts. Setting
#    `build-users-group =` (empty) makes root build directly; `sandbox = false`
#    avoids namespace sandboxing that a container may disallow. The installer's
#    own bundled Nix reads this file, so it must exist first.
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/nix
cat > /etc/nix/nix.conf <<'EOF'
build-users-group =
sandbox = false
experimental-features = nix-command flakes
accept-flake-config = true
warn-dirty = false
max-jobs = auto
EOF

# ---------------------------------------------------------------------------
# 2. Install Nix, single-user / daemonless.
#
#    Daemonless is deliberate: the install and all later builds run as root and
#    inherit HTTPS_PROXY + NIX_SSL_CERT_FILE, so substituter downloads work
#    through the egress proxy. A nix-daemon would run in its own environment,
#    would NOT inherit those variables, and its fetches would fail.
#
#    We fetch a pinned installer from releases.nixos.org (a *.nixos.org
#    subdomain, in the default Trusted allowlist). The usual
#    https://nixos.org/nix/install one-liner hits the bare apex `nixos.org`,
#    which `*.nixos.org` does NOT cover, so it 403s at the egress proxy. The
#    pinned installer and its tarball both live under releases.nixos.org, and
#    Nix's own fetches use cache.nixos.org, so nothing touches the blocked
#    apex. Bump NIX_VERSION to upgrade (see https://releases.nixos.org/?prefix=nix/).
# ---------------------------------------------------------------------------
NIX_VERSION="${NIX_VERSION:-2.31.2}"
if ! command -v nix >/dev/null 2>&1 && [ ! -e /nix/var/nix/profiles/default/bin/nix ]; then
  installer="$(mktemp)"
  curl --proto '=https' --tlsv1.2 -sSf -L \
    "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" -o "$installer"
  sh "$installer" --no-daemon --no-channel-add
  rm -f "$installer"
fi

# ---------------------------------------------------------------------------
# 3. Load Nix into this script's shell. The profile's nix.sh only exports PATH
#    when $USER is set, and a non-login setup shell may not have it, so set
#    USER/HOME first and then prepend the profile bin directly as a fallback.
# ---------------------------------------------------------------------------
export USER="${USER:-root}"
export HOME="${HOME:-/root}"
# shellcheck disable=SC1091
[ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && . "$HOME/.nix-profile/etc/profile.d/nix.sh"
export PATH="$HOME/.nix-profile/bin:$PATH"

# ---------------------------------------------------------------------------
# 4. Handy CLIs from nixpkgs into the root profile:
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
# 5. Put Nix + the profile tools on the default PATH for Claude's shells.
#    Claude's Bash tool runs non-login shells that never source nix.sh, so
#    symlink into /usr/local/bin, which is always on PATH.
# ---------------------------------------------------------------------------
ln -sf "$HOME"/.nix-profile/bin/* /usr/local/bin/

# ---------------------------------------------------------------------------
# 6. Pre-warm the gigpkgs devShell so its inputs and custom packages
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
