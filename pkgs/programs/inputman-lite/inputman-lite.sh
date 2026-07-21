#!/usr/bin/env bash
set -euo pipefail

# inputman-lite — a slim, consumer-facing companion to inputMan.
#
# For downstream flakes (e.g. dotfiles), it toggles LOCAL development of a
# program that is normally consumed from gigpkgs: it injects a temporary
# `<prog>-local` flake input plus a marker-bracketed `pkgs` shadow so
# `pkgs.<prog>` (and `pkgs.unstable.<prog>`) resolve to your local checkout —
# letting you iterate as if the program were already a configurable gigpkgs
# branch — and then cleanly removes all of that on `promote`, bumping gigpkgs so
# the promoted package flows back in at the identical attribute path.
#
# It shares inputMan's flake.nix patcher via the same inputman-lib.sh.
#
# shellcheck source=inputman-lib.sh
source @INPUTMAN_LIB@

# Stable anchor the consumer plants in flake.nix, just before the `;` that ends
# its `pkgs = …` binding. `dev` inserts a `// { … }` shadow right after it.
PKGS_ANCHOR="# inputman-lite:pkgs-anchor"

lite_usage() {
  cat <<'EOF_USAGE'
Usage: inputman-lite <command> [options]

Commands:
  dev <prog>       Point <prog> at a local checkout for development
  promote <prog>   Remove the local override; refresh gigpkgs (alias: remove)
  status [<prog>]  Show whether a local override is active
  help             Show this help

dev options:
  --local <path>   Local checkout path (default: $INPUTMAN_LITE_<PROG>_PATH,
                   else ~/local_repos/<prog>). Used as git+file://<path>.
  --remote <url>   Use a remote flakeref instead of a local path.
  --branch <ref>   Append ?ref=<ref> to the source URL.
  --yes, -y        Commit the scaffolding (default: leave uncommitted).
  --no-commit, -n  Lock but do not commit (default).

Notes:
  * <prog> defaults to roll-flow.
  * The local override is intentionally NOT committed by default — it encodes a
    machine-specific path. Use --yes only if you really want it in history.
  * Requires the consumer flake.nix to carry the anchor:
        # inputman-lite:pkgs-anchor
    on its own line just before the ';' terminating the `pkgs = …` binding.

Examples:
  inputman-lite dev roll-flow
  inputman-lite dev roll-flow --local ~/src/roll-flow --branch feature/x
  inputman-lite dev roll-flow --remote github:gignsky/roll-flow --branch develop
  inputman-lite status
  inputman-lite promote roll-flow
EOF_USAGE
}

marker_begin() { printf '# inputman-lite:begin %s-local' "$1"; }
marker_end() { printf '# inputman-lite:end %s-local' "$1"; }

# Build the marker-bracketed `pkgs` shadow for <program>/<input_name>.
render_pkgs_shadow() {
  local program="$1" input_name="$2"
  cat <<EOF
  $(marker_begin "$program")
  // {
    ${program} = inputs.${input_name}.packages.\${system}.default;
    unstable = (inputs.gigpkgs.legacyPackages.\${system}.unstable or { }) // {
      ${program} = inputs.${input_name}.packages.\${system}.default;
    };
  }
  $(marker_end "$program")
EOF
}

cmd_dev() {
  local program="" local_path="" remote_url="" branch="" auto_commit="" no_commit=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --local)
      local_path="$2"
      shift 2
      ;;
    --remote)
      remote_url="$2"
      shift 2
      ;;
    --branch)
      branch="$2"
      shift 2
      ;;
    --yes | -y)
      auto_commit=1
      no_commit=""
      shift
      ;;
    --no-commit | -n)
      no_commit=1
      auto_commit=""
      shift
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      [[ -n "$program" ]] && die "Only one program name may be provided"
      program="$1"
      shift
      ;;
    esac
  done

  [[ -z "$program" ]] && program="roll-flow"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the consumer repo root"
  [[ "$program" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "Program name '${program}' is not a valid Nix identifier"

  local input_name="${program}-local"

  if grep -qF -- "$(marker_begin "$program")" flake.nix; then
    die "Local dev already active for '${program}'. Run 'inputman-lite promote ${program}' first."
  fi
  grep -qF -- "$PKGS_ANCHOR" flake.nix ||
    die "Missing anchor in flake.nix. Add a line '${PKGS_ANCHOR}' just before the ';' ending your 'pkgs = …' binding."

  # Resolve the source URL.
  local url
  if [[ -n "$remote_url" ]]; then
    url="$remote_url"
  else
    local env_var="INPUTMAN_LITE_$(printf '%s' "$program" | tr '[:lower:]-' '[:upper:]_')_PATH"
    local path="${local_path:-${!env_var:-$HOME/local_repos/${program}}}"
    url="git+file://${path}"
  fi
  [[ -n "$branch" ]] && url="${url}?ref=${branch}"

  info "Enabling local dev for '${program}' -> ${url}"

  # 1. Add the input. `gigpkgs=gigpkgs` dedups the program's own gigpkgs dep
  #    against the consumer's, avoiding a second gigpkgs/nixpkgs in the lock.
  patch_flake_add "$input_name" "$url" "gigpkgs=gigpkgs"
  ok "Added input '${input_name}'"

  # 2. Insert the pkgs shadow after the anchor.
  local block
  block="$(render_pkgs_shadow "$program" "$input_name")"$'\n'
  insert_after_anchor flake.nix "$PKGS_ANCHOR" "$block"
  ok "Shadowed pkgs.${program} (and pkgs.unstable.${program})"

  # 3. Re-lock.
  info "Locking (locker) ..."
  if [[ -n "$auto_commit" ]]; then
    locker -y
  else
    locker -n
    warn "Local-dev scaffolding is uncommitted by design (machine-specific path)."
  fi

  ok "Local dev active for '${program}'. Edit your checkout and rebuild/enter the devShell."
}

cmd_promote() {
  local program="" auto_commit="" no_commit=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --yes | -y)
      auto_commit=1
      shift
      ;;
    --no-commit | -n)
      no_commit=1
      shift
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      [[ -n "$program" ]] && die "Only one program name may be provided"
      program="$1"
      shift
      ;;
    esac
  done

  [[ -z "$program" ]] && program="roll-flow"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the consumer repo root"

  local input_name="${program}-local"

  if ! grep -qF -- "$(marker_begin "$program")" flake.nix; then
    warn "No active local dev for '${program}' (nothing to promote)."
  fi

  info "Removing local override for '${program}' ..."

  # 1. Remove the shadow block(s).
  remove_marker_block flake.nix "$(marker_begin "$program")" "$(marker_end "$program")"
  ok "Removed pkgs shadow"

  # 2. Remove the input (ignore if already gone).
  if grep -qP "^\s+${input_name}[. =]" flake.nix; then
    patch_flake_remove "$input_name"
    ok "Removed input '${input_name}'"
  fi

  # 3. Bump gigpkgs so its (now-promoted) channel-selected ${program} flows in.
  #    `nix flake update` is used directly for portability; fupdate is available
  #    on PATH if you prefer it.
  info "Updating gigpkgs ..."
  nix flake update gigpkgs

  # 4. Re-lock.
  info "Locking (locker) ..."
  if [[ -n "$no_commit" ]]; then
    locker -n
  elif [[ -n "$auto_commit" ]]; then
    locker -y
  else
    locker -n
  fi

  ok "Promoted '${program}': it now resolves from gigpkgs at pkgs.${program}."
}

cmd_status() {
  local program="${1:-}"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the consumer repo root"

  local -a progs=()
  if [[ -n "$program" ]]; then
    progs=("$program")
  else
    # Discover active overrides from begin markers.
    while IFS= read -r p; do
      [[ -n "$p" ]] && progs+=("$p")
    done < <(grep -oE 'inputman-lite:begin [A-Za-z0-9_-]+-local' flake.nix 2>/dev/null |
      sed -E 's/inputman-lite:begin (.*)-local/\1/')
  fi

  if [[ ${#progs[@]} -eq 0 ]]; then
    info "No active local overrides."
    return 0
  fi

  local p
  for p in "${progs[@]}"; do
    if grep -qF -- "$(marker_begin "$p")" flake.nix; then
      ok "local dev ACTIVE for '${p}' (input ${p}-local + pkgs shadow present)"
    else
      info "local dev inactive for '${p}'"
    fi
  done
}

case "${1:-help}" in
dev)
  shift
  cmd_dev "$@"
  ;;
promote | remove)
  shift
  cmd_promote "$@"
  ;;
status)
  shift
  cmd_status "$@"
  ;;
__render-pkgs-shadow)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman-lite __render-pkgs-shadow <program> <input-name>"
  render_pkgs_shadow "$1" "$2"
  ;;
help | -h | --help) lite_usage ;;
*) die "Unknown command: ${1}. Run 'inputman-lite help' for usage." ;;
esac
