#!/usr/bin/env bash
set -euo pipefail

LIB="@LIB_PATH@"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "${BLUE}[inputMan]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[inputMan]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[inputMan]${NC} %s\n" "$*" >&2; }
die()  { printf "${RED}[inputMan] error:${NC} %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: inputman <command> [options]

Commands:
  install <url>    Add a flake input and expose its packages
  help             Show this help

Options for install:
  --name <name>       Override the input name (default: inferred from URL)
  --packages <p1,p2>  Comma-separated packages to install (default: all discovered)
  --yes, -y           Commit without prompting
  --no-commit, -n     Stage changes but do not commit

EOF
}

# Infer input name from a flake URL: last path component, stripped of query params.
infer_name() {
  local url="$1"
  local base
  base="${url##*/}"
  base="${base%%\?*}"
  printf '%s' "$base"
}

# Emit one package name per line; falls back to "default" on any failure.
discover_packages() {
  local url="$1" system="$2"
  local pkgs
  pkgs=$(nix flake show "$url" --json 2>/dev/null \
    | jq -r --arg sys "$system" '.packages[$sys] // {} | keys[]' 2>/dev/null) || true
  if [[ -z "$pkgs" ]]; then
    echo "default"
  else
    echo "$pkgs"
  fi
}

generate_input_file() {
  local name="$1"; shift
  local nix_list=""
  local p
  for p in "$@"; do
    nix_list+=" \"${p}\""
  done
  nix eval --impure --expr \
    "(import ${LIB}).mkInputFile { name = \"${name}\"; packages = [${nix_list} ]; }" \
    --raw
}

# Insert `name.url = "url";` before the closing `};` of the inputs block.
# Matches the inputs-block close by looking for the 2-space `};` that precedes
# the blank line before `outputs`.
patch_flake_add() {
  local name="$1" url="$2"
  INPUT_NAME="$name" INPUT_URL="$url" perl -i -0pe '
    my ($n, $u) = ($ENV{INPUT_NAME}, $ENV{INPUT_URL});
    s/(\n  \};\n\n  outputs)/\n\n    $n.url = "$u";$1/s
      or die "inputMan: could not locate inputs block close in flake.nix\n";
  ' flake.nix
}

cmd_install() {
  local url="" name="" packages_override="" auto_commit="" no_commit=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)           name="$2";               shift 2 ;;
      --packages)       packages_override="$2";  shift 2 ;;
      --yes|-y)         auto_commit=1;            shift   ;;
      --no-commit|-n)   no_commit=1;              shift   ;;
      -*)               die "Unknown option: $1" ;;
      *)                url="$1";                 shift   ;;
    esac
  done

  [[ -z "$url" ]] && die "Usage: inputman install <url> [options]"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the repo root"

  [[ -z "$name" ]] && name=$(infer_name "$url")

  # Validate name is a safe Nix identifier
  if ! [[ "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    die "Input name '${name}' is not a valid Nix identifier (use --name to override)"
  fi

  info "Installing input '${name}' from ${url}"

  # Guard against duplicates
  if grep -qP "^\s+${name}[. =]" flake.nix; then
    die "Input '${name}' already exists in flake.nix (use --name to choose a different name)"
  fi

  local input_file="pkgs/inputs/${name}.nix"
  [[ -f "$input_file" ]] && die "Input file ${input_file} already exists"

  # Detect current system
  local system
  system=$(nix eval --impure --expr "builtins.currentSystem" --raw 2>/dev/null \
    || echo "x86_64-linux")

  # Discover or use provided package list
  local -a pkg_list=()
  if [[ -n "$packages_override" ]]; then
    IFS=',' read -ra pkg_list <<< "$packages_override"
  else
    info "Discovering packages from ${url} ..."
    while IFS= read -r line; do
      [[ -n "$line" ]] && pkg_list+=("$line")
    done < <(discover_packages "$url" "$system")
    [[ ${#pkg_list[@]} -eq 0 ]] && pkg_list=("default")
    ok "Found: ${pkg_list[*]}"
  fi

  # Generate and write the input file
  info "Generating ${input_file} ..."
  local content
  content=$(generate_input_file "$name" "${pkg_list[@]}")
  printf '%s' "$content" > "$input_file"
  ok "Wrote ${input_file}"

  # Patch flake.nix
  info "Adding input to flake.nix ..."
  patch_flake_add "$name" "$url"
  ok "Patched flake.nix"

  # Lock the new input
  info "Locking input ${name} ..."
  nix flake lock
  ok "flake.lock updated"

  # Stage all changes
  git add "$input_file" flake.nix flake.lock

  # Commit handling
  if [[ -n "$no_commit" ]]; then
    warn "Changes staged but not committed (--no-commit)."
    return
  fi

  if [[ -n "$auto_commit" ]]; then
    git commit -m "inputMan: add input ${name} (${url})"
    ok "Committed."
    return
  fi

  local answer
  read -rp "Commit changes? [Y/n]: " answer
  if [[ -z "$answer" || "${answer,,}" == "y"* ]]; then
    git commit -m "inputMan: add input ${name} (${url})"
    ok "Committed."
  else
    warn "Changes staged but not committed."
  fi
}

case "${1:-help}" in
  install)        shift; cmd_install "$@" ;;
  help|-h|--help) usage ;;
  *)              die "Unknown command: ${1}. Run 'inputman help' for usage." ;;
esac
