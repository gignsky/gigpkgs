#!/usr/bin/env bash
# Setup script for the "bumble" cloud environment (Claude Code on the web).
#
# Where it goes: claude.ai/code -> environment selector -> Add environment ->
#                name it "bumble" -> "Setup script" field. Paste this whole file.
#
# Target: a general polyglot runner for Nix + Rust + Python + Nushell projects
#         (not tied to any single repo).
#
# Facts this script relies on (see docs/cloud-environments.md for sources):
#   * Runs as root on Ubuntu 24.04, once per environment-cache build; the
#     result is snapshotted and reused (cache TTL ~7 days).
#   * The base image already ships Rust (rustc/cargo) and a full Python stack
#     (pip, uv, poetry, black, mypy, pytest, ruff). We add what it lacks -
#     Nix + flakes, direnv, Nushell - and the Rust dev components (clippy,
#     rustfmt, rust-analyzer) that the bare rustc/cargo image omits.
#   * TLS + egress proxy are pre-wired (HTTPS_PROXY + NIX_SSL_CERT_FILE set,
#     proxy CA already in the system trust store), so Nix fetches just work.
#   * "Trusted" network access is enough: *.nixos.org, crates.io and pypi.org
#     are all in the default allowlist.
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Install Nix, single-user / daemonless (so it inherits the proxy + CA env).
#
#    Fetched from releases.nixos.org (a *.nixos.org subdomain, in the default
#    Trusted allowlist) at a pinned version. The bare apex `nixos.org` used by
#    the usual install one-liner is NOT covered by the `*.nixos.org` wildcard
#    and 403s at the egress proxy. Bump NIX_VERSION to upgrade.
# ---------------------------------------------------------------------------
NIX_VERSION="${NIX_VERSION:-2.31.2}"
if ! command -v nix >/dev/null 2>&1 && [ ! -e /nix/var/nix/profiles/default/bin/nix ]; then
  installer="$(mktemp)"
  curl --proto '=https' --tlsv1.2 -sSf -L \
    "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" -o "$installer"
  sh "$installer" --no-daemon --no-channel-add
  rm -f "$installer"
fi

# shellcheck disable=SC1091
. "$HOME/.nix-profile/etc/profile.d/nix.sh"

# ---------------------------------------------------------------------------
# 2. Global Nix config: flakes + CI-friendly defaults.
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/nix
cat > /etc/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
accept-flake-config = true
warn-dirty = false
max-jobs = auto
EOF

# ---------------------------------------------------------------------------
# 3. Fill the toolchain gaps from nixpkgs.
#    - Nix ecosystem: direnv (+ nix-direnv), just, nushell
#    - Rust dev components missing from the base rustc/cargo image
#    Python's base tooling (uv/ruff/poetry/pytest/...) is already complete,
#    so we do not duplicate it here; per-project pins come from each repo's
#    own flake via `nix develop -c`.
# ---------------------------------------------------------------------------
nix profile install \
  nixpkgs#direnv \
  nixpkgs#nix-direnv \
  nixpkgs#just \
  nixpkgs#nushell \
  nixpkgs#rust-analyzer \
  nixpkgs#clippy \
  nixpkgs#rustfmt \
  nixpkgs#cargo-edit || true

# Wire nix-direnv so any repo's `use flake` .envrc resolves quickly.
install -d -m 0755 "$HOME/.config/direnv"
if ! grep -q nix-direnv "$HOME/.config/direnv/direnvrc" 2>/dev/null; then
  echo 'source "$HOME/.nix-profile/share/nix-direnv/direnvrc"' \
    >> "$HOME/.config/direnv/direnvrc"
fi

# ---------------------------------------------------------------------------
# 4. Put Nix + the profile tools on the default PATH (non-login shell safe).
# ---------------------------------------------------------------------------
ln -sf /root/.nix-profile/bin/* /usr/local/bin/

# bumble is repo-agnostic, so there is no devShell to pre-warm here. In a
# session, run `nix develop -c <cmd>` in a flake project to get that project's
# exact toolchain; the store it builds is cached for the life of the session.
