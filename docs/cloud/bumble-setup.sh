#!/usr/bin/env bash
# =============================================================================
# Setup script for the "bumble" cloud environment (Claude Code on the web).
#
# Where it goes: claude.ai/code -> environment selector -> Add environment ->
#                name it "bumble" -> "Setup script" field. Paste this whole file.
#
# Target: a general polyglot runner for Nix + Rust + Python + Nushell projects
#         (not tied to any single repo).
#
# Same philosophy as buzz: `nix` fully usable for build / run / eval / flake
# operations; any repo's flake devShell is NOT auto-loaded, because a devShell
# whose inputs include personal / non-authorized github: flakes will 403 under
# the GitHub proxy (see docs/cloud-environments.md). Plain nix build/run/eval
# do not need the devShell.
# =============================================================================
set -euo pipefail
echo "==> bumble nix setup starting"

# --- 1. Install Nix if absent (install-if-missing, NOT assert) --------------
#    The base image (Ubuntu 24.04) does NOT ship Nix; a prior run bakes /nix
#    into the environment-cache snapshot, so this is a no-op on a warm cache
#    and installs on a cold one (incl. every time you edit this script). nix.conf
#    is written first so single-user Nix installs as root without the nixbld
#    group; the installer is pinned from releases.nixos.org (allowlisted; the
#    bare apex nixos.org is not).
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
export USER="${USER:-root}"
export HOME="${HOME:-/root}"
# shellcheck disable=SC1091
[ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && . "$HOME/.nix-profile/etc/profile.d/nix.sh"
export PATH="$HOME/.nix-profile/bin:$PATH"
command -v nix >/dev/null 2>&1 || { echo "ERROR: nix not on PATH after install step" >&2; exit 1; }
echo "    nix: $(nix --version)"

# --- 3. Ensure flake / nix-command features are on (idempotent) -------------
install -d -m 0755 /etc/nix
grep -qs '^experimental-features' /etc/nix/nix.conf 2>/dev/null || \
  echo 'experimental-features = nix-command flakes fetch-tree' >> /etc/nix/nix.conf
echo "    experimental-features: $(nix config show experimental-features 2>/dev/null || echo '?')"

# --- 4. Fill the toolchain gaps from nixpkgs (idempotent) -------------------
#    Nix ecosystem: direnv (+ nix-direnv), just, nushell.
#    Rust dev components the base rustc/cargo image omits: clippy, rustfmt,
#    rust-analyzer, cargo-edit. Python's base stack (uv/ruff/poetry/pytest/...)
#    is already complete; per-project pins come from each repo's own
#    `nix develop -c`. All substitute from cache.nixos.org, never github.
nix profile install \
  nixpkgs#direnv \
  nixpkgs#nix-direnv \
  nixpkgs#just \
  nixpkgs#nushell \
  nixpkgs#rust-analyzer \
  nixpkgs#clippy \
  nixpkgs#rustfmt \
  nixpkgs#cargo-edit 2>/dev/null || true
install -d -m 0755 "$HOME/.config/direnv"
if ! grep -q nix-direnv "$HOME/.config/direnv/direnvrc" 2>/dev/null; then
  # $HOME must stay literal — it is expanded by direnv at runtime, not now.
  # shellcheck disable=SC2016
  echo 'source "$HOME/.nix-profile/share/nix-direnv/direnvrc"' \
    >> "$HOME/.config/direnv/direnvrc"
fi
ln -sf "$HOME"/.nix-profile/bin/* /usr/local/bin/

# --- 5. Do not auto-load a devShell -----------------------------------------
#    If the cloned repo has an .envrc (`use flake`), revoke any stale allow so
#    a devShell with unauthorized github inputs cannot 403 on cd. Opt in per
#    project with `direnv allow` once its inputs are reachable.
if command -v direnv >/dev/null 2>&1 && [ -f .envrc ]; then
  direnv deny . 2>/dev/null || direnv revoke . 2>/dev/null || true
  echo "    .envrc DENIED -> devShell will not auto-load on cd"
fi

# --- 6. Warm flake metadata if a flake is present (safe) --------------------
if [ -f flake.nix ]; then
  nix flake metadata >/dev/null 2>&1 || echo "    (flake metadata warm skipped)"
fi

echo "==> bumble nix setup complete: nix + rust/python/nushell ready; no devShell auto-load"
