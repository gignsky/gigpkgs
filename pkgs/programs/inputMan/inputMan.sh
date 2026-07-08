#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "${BLUE}[inputMan]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[inputMan]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[inputMan]${NC} %s\n" "$*" >&2; }
die() {
  printf "${RED}[inputMan] error:${NC} %s\n" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF_USAGE'
Usage: inputman <command> [options]

Commands:
  install <url>    Add a flake input and expose its packages
  update <name>    Update an existing flake input lock entry
  remove <name>    Remove an existing flake input and generated package file
  help             Show this help

Install options:
  --name <name>        Override the input name (default: inferred from URL)
  --packages <p1,p2>   Comma-separated packages to install (default: discovered)
  --follows <k=v>      Add follows override (repeatable)
  --no-info            Skip flake metadata probe output
  --no-branch          Skip creating add-input/<name> branch from origin/main
  --yes, -y            Commit without prompting
  --no-commit, -n      Stage changes but do not commit

Update/remove options:
  --yes, -y            Commit without prompting
  --no-commit, -n      Stage changes but do not commit

Examples:
  inputman install github:nix-community/nur
  inputman install github:gignsky/gigvim --follows nixpkgs=nixpkgs --yes
  inputman update gigvim -y
  inputman remove gigvim --no-commit
EOF_USAGE
}

infer_name() {
  local url="$1"
  local base
  base="${url##*/}"
  base="${base%%\?*}"
  printf '%s' "$base"
}

discover_packages() {
  local url="$1" system="$2"
  local pkgs=""

  if ! pkgs=$(nix flake show "$url" --json 2>/dev/null |
    jq -r --arg sys "$system" '.packages[$sys] // {} | keys[]' 2>/dev/null); then
    warn "Package discovery failed for '${url}', falling back to package 'default'."
  fi

  if [[ -z "$pkgs" ]]; then
    warn "No packages discovered for '${url}', using package 'default'."
    echo "default"
  else
    echo "$pkgs"
  fi
}

generate_input_file() {
  local name="$1"
  shift

  printf '# gigpkgs inputMan: managed input\n'
  printf '{ inputs, system }:\n'
  printf '{\n'

  local pkg alias
  for pkg in "$@"; do
    alias="$name"
    if [[ "$pkg" != "default" ]]; then
      alias="${name}-${pkg}"
    fi
    printf "  %s = inputs.%s.packages.\${system}.%s;\n" "$alias" "$name" "$pkg"
  done

  printf '}\n'
}

show_input_metadata() {
  local url="$1"
  local metadata description resolved_url rev last_modified

  if ! metadata=$(nix flake metadata "$url" --json 2>/dev/null); then
    warn "Unable to read flake metadata for '${url}'."
    return
  fi

  description=$(jq -r '.description // "n/a"' <<<"$metadata")
  resolved_url=$(jq -r '.resolvedUrl // .resolved.url // .originalUrl // "n/a"' <<<"$metadata")
  rev=$(jq -r '.revision // .locked.rev // "n/a"' <<<"$metadata")
  last_modified=$(jq -r '.lastModified // .locked.lastModified // "n/a"' <<<"$metadata")

  info "Input metadata"
  info "  description : ${description}"
  info "  resolved URL: ${resolved_url}"
  info "  revision    : ${rev}"
  info "  lastModified: ${last_modified}"
}

validate_follows_pair() {
  local pair="$1"
  [[ "$pair" == *=* ]] || die "Invalid --follows value '${pair}' (expected key=value)"

  local key="${pair%%=*}"
  local value="${pair#*=}"

  [[ -n "$key" && -n "$value" ]] || die "Invalid --follows value '${pair}' (expected key=value)"
  [[ "$key" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "Invalid follows key '${key}'"
  [[ "$value" =~ ^[a-zA-Z0-9._/-]+$ ]] || die "Invalid follows target '${value}'"
}

patch_flake_add() {
  local name="$1" url="$2"
  shift 2

  local follows_newline=""
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    follows_newline+="${key}=${value}"$'\n'
  done

  local perl_script
  perl_script=$(
    cat <<'PERL'
    use strict;
    use warnings;

    sub find_inputs_block {
      my ($text) = @_;

      $text =~ /inputs\s*=\s*\{/g or die "inputMan: could not locate inputs block in flake.nix\n";
      my $open_pos = pos($text) - 1;

      my $depth = 1;
      my $i = $open_pos + 1;
      my $len = length($text);
      my ($in_dq, $in_sq, $in_comment) = (0, 0, 0);

      while ($i < $len) {
        my $ch = substr($text, $i, 1);
        my $next2 = ($i + 1 < $len) ? substr($text, $i, 2) : "";

        if ($in_comment) {
          if ($ch eq "\n") { $in_comment = 0; }
          $i++;
          next;
        }

        if ($in_dq) {
          if ($ch eq "\\") { $i += 2; next; }
          if ($ch eq "\"") { $in_dq = 0; }
          $i++;
          next;
        }

        if ($in_sq) {
          if ($next2 eq "''") { $in_sq = 0; $i += 2; next; }
          $i++;
          next;
        }

        if ($ch eq "#") { $in_comment = 1; $i++; next; }
        if ($next2 eq "''") { $in_sq = 1; $i += 2; next; }
        if ($ch eq "\"") { $in_dq = 1; $i++; next; }

        if ($ch eq "{") { $depth++; $i++; next; }
        if ($ch eq "}") {
          $depth--;
          return ($open_pos, $i) if $depth == 0;
        }

        $i++;
      }

      die "inputMan: could not find end of inputs block in flake.nix\n";
    }

    my $n = $ENV{INPUT_NAME};
    my $u = $ENV{INPUT_URL};
    my $follows_raw = $ENV{INPUT_FOLLOWS} // "";

    my ($open_pos, $close_pos) = find_inputs_block($_);

    my $line_start = rindex($_, "\n", $open_pos);
    $line_start = -1 if $line_start < 0;
    my $line_end = index($_, "\n", $open_pos);
    $line_end = length($_) if $line_end < 0;
    my $line = substr($_, $line_start + 1, $line_end - ($line_start + 1));
    my ($indent) = ($line =~ /^(\s*)/);
    my $entry_indent = ($indent // "") . "  ";

    my @insert_lines = (qq{$entry_indent$n.url = "$u";});
    for my $raw (split /\n/, $follows_raw) {
      next if $raw eq q{};
      my ($k, $v) = split /=/, $raw, 2;
      push @insert_lines, qq{$entry_indent$n.inputs.$k.follows = "$v";};
    }

    my $insert = "\n" . join("\n", @insert_lines) . "\n";
    substr($_, $close_pos, 0, $insert);
PERL
  )

  local err_file
  err_file=$(mktemp)
  if ! INPUT_NAME="$name" INPUT_URL="$url" INPUT_FOLLOWS="$follows_newline" perl -i -0pe "$perl_script" flake.nix 2>"$err_file"; then
    local err
    err=$(cat "$err_file")
    rm -f "$err_file"
    die "Failed to patch flake.nix: ${err:-unknown patch error}"
  fi

  rm -f "$err_file"
}

patch_flake_remove() {
  local name="$1"
  local perl_script
  perl_script=$(
    cat <<'PERL'
    use strict;
    use warnings;

    sub find_inputs_block {
      my ($text) = @_;

      $text =~ /inputs\s*=\s*\{/g or die "inputMan: could not locate inputs block in flake.nix\n";
      my $open_pos = pos($text) - 1;

      my $depth = 1;
      my $i = $open_pos + 1;
      my $len = length($text);
      my ($in_dq, $in_sq, $in_comment) = (0, 0, 0);

      while ($i < $len) {
        my $ch = substr($text, $i, 1);
        my $next2 = ($i + 1 < $len) ? substr($text, $i, 2) : "";

        if ($in_comment) {
          if ($ch eq "\n") { $in_comment = 0; }
          $i++;
          next;
        }

        if ($in_dq) {
          if ($ch eq "\\") { $i += 2; next; }
          if ($ch eq "\"") { $in_dq = 0; }
          $i++;
          next;
        }

        if ($in_sq) {
          if ($next2 eq "''") { $in_sq = 0; $i += 2; next; }
          $i++;
          next;
        }

        if ($ch eq "#") { $in_comment = 1; $i++; next; }
        if ($next2 eq "''") { $in_sq = 1; $i += 2; next; }
        if ($ch eq "\"") { $in_dq = 1; $i++; next; }

        if ($ch eq "{") { $depth++; $i++; next; }
        if ($ch eq "}") {
          $depth--;
          return ($open_pos, $i) if $depth == 0;
        }

        $i++;
      }

      die "inputMan: could not find end of inputs block in flake.nix\n";
    }

    my $n = $ENV{INPUT_NAME};
    my ($open_pos, $close_pos) = find_inputs_block($_);

    my $inner_start = $open_pos + 1;
    my $inner_len = $close_pos - $inner_start;
    my $inner = substr($_, $inner_start, $inner_len);

    my $removed_url = ($inner =~ s/^\h*\Q$n\E\.url\h*=\h*".*?";\h*\n//mg);
    $inner =~ s/^\h*\Q$n\E\.inputs\.[a-zA-Z][a-zA-Z0-9_-]*\.follows\h*=\h*".*?";\h*\n//mg;

    die "inputMan: input '$n' not found in flake.nix inputs block\n" unless $removed_url;

    substr($_, $inner_start, $inner_len, $inner);
PERL
  )

  local err_file
  err_file=$(mktemp)

  if ! INPUT_NAME="$name" perl -i -0pe "$perl_script" flake.nix 2>"$err_file"; then
    local err
    err=$(cat "$err_file")
    rm -f "$err_file"
    die "Failed to patch flake.nix: ${err:-unknown patch error}"
  fi

  rm -f "$err_file"
}

write_news_entry() {
  local action="$1" name="$2" details="$3"
  local news_dir="news/entries"

  if [[ ! -d "$news_dir" ]]; then
    warn "News directory '${news_dir}' not present; skipping news entry."
    return 0
  fi

  local today
  today=$(date +%Y-%m-%d)

  local base_id="${today}-inputman-${action}-${name}"
  local id="$base_id"
  local n=2
  while [[ -f "${news_dir}/${id}.nix" ]]; do
    id="${base_id}-${n}"
    n=$((n + 1))
  done
  local file="${news_dir}/${id}.nix"

  local headline body
  case "$action" in
  install)
    headline="Added flake input '${name}'"
    body="This input was installed by inputMan and is now available via gigpkgs."
    ;;
  update)
    headline="Updated flake input '${name}'"
    body="The flake.lock entry for this input was refreshed by inputMan."
    ;;
  remove)
    headline="Removed flake input '${name}'"
    body="This input was removed from gigpkgs by inputMan."
    ;;
  *)
    warn "Unknown news action '${action}'; skipping news entry."
    return 0
    ;;
  esac

  {
    printf '{\n'
    printf '  id = "%s";\n' "$id"
    printf '  date = "%s";\n' "$today"
    printf "  message = ''\n"
    printf '    %s\n' "$headline"
    printf '\n'
    printf '    %s\n' "$body"
    if [[ -n "$details" ]]; then
      printf '\n'
      while IFS= read -r line; do
        if [[ -z "$line" ]]; then
          printf '\n'
        else
          printf '    %s\n' "$line"
        fi
      done <<<"$details"
    fi
    printf "  '';\n"
    printf '}\n'
  } >"$file"

  ok "Wrote news entry ${file}" >&2
  printf '%s' "$file"
}

finalize_commit() {
  local commit_message="$1" auto_commit="$2" no_commit="$3"

  # # pre-commit check
  # info "Running pre-commit checks..."
  # set +e
  # pre-commit run --all-files
  # set -e
  # info "Pre-commit checks finished."

  if git diff --cached --quiet; then
    warn "No staged changes to commit."
    return
  fi

  if [[ -n "$no_commit" ]]; then
    warn "Changes staged but not committed (--no-commit)."
    return
  fi

  if [[ -n "$auto_commit" ]]; then
    git commit -m "$commit_message" --no-verify
    ok "Committed."
    return
  fi

  local answer
  read -rp "Commit changes? [Y/n]: " answer
  if [[ -z "$answer" || "${answer,,}" == "y"* ]]; then
    git commit -m "$commit_message" --no-verify
    ok "Committed."
  else
    warn "Changes staged but not committed."
  fi
}

create_feature_branch() {
  local name="$1"
  local branch="add-input/${name}"

  [[ -d .git ]] || die "No git repository found."

  local current
  current=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$current" == "$branch" ]]; then
    info "Already on branch ${branch}"
    return
  fi

  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    die "Branch '${branch}' already exists"
  fi

  if ! git show-ref --verify --quiet refs/remotes/origin/main; then
    if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
      git fetch --unshallow origin >/dev/null 2>&1 || die "Failed to fetch full history from origin"
    fi
    git fetch origin main:refs/remotes/origin/main >/dev/null 2>&1 ||
      die "Failed to fetch origin/main"
  fi

  git checkout -b "$branch" refs/remotes/origin/main >/dev/null 2>&1 ||
    die "Failed to create branch '${branch}' from origin/main"
  ok "Created and switched to branch '${branch}'"
}

INPUTMAN_CLEANUP_ACTIVE=0
INPUTMAN_CLEANUP_FILE=""
INPUTMAN_CLEANUP_FLAKE=0
INPUTMAN_CLEANUP_NEWS_FILE=""

inputman_install_cleanup() {
  local status="$1"
  if [[ "$status" -eq 0 || "${INPUTMAN_CLEANUP_ACTIVE:-0}" -ne 1 ]]; then
    return
  fi

  local rolled_back=0

  if [[ -n "${INPUTMAN_CLEANUP_FILE:-}" && -f "${INPUTMAN_CLEANUP_FILE}" ]]; then
    rm -f "${INPUTMAN_CLEANUP_FILE}"
    rolled_back=1
  fi

  if [[ -n "${INPUTMAN_CLEANUP_NEWS_FILE:-}" && -f "${INPUTMAN_CLEANUP_NEWS_FILE}" ]]; then
    rm -f "${INPUTMAN_CLEANUP_NEWS_FILE}"
    rolled_back=1
  fi

  if [[ "${INPUTMAN_CLEANUP_FLAKE:-0}" -eq 1 && -f flake.nix ]]; then
    git checkout -- flake.nix >/dev/null 2>&1 || true
    rolled_back=1
  fi

  if [[ "$rolled_back" -eq 1 ]]; then
    warn "Install failed. Rolled back flake.nix, generated input file, and news entry."
  fi
}

cmd_install() {
  local url="" name="" packages_override="" auto_commit="" no_commit=""
  local no_info="" no_branch=""
  local -a follows_pairs=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --name)
      name="$2"
      shift 2
      ;;
    --packages)
      packages_override="$2"
      shift 2
      ;;
    --follows)
      validate_follows_pair "$2"
      follows_pairs+=("$2")
      shift 2
      ;;
    --no-info)
      no_info=1
      shift
      ;;
    --no-branch)
      no_branch=1
      shift
      ;;
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
      if [[ -n "$url" ]]; then
        die "Only one URL may be provided"
      fi
      url="$1"
      shift
      ;;
    esac
  done

  [[ -z "$url" ]] && die "Usage: inputman install <url> [options]"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the repo root"

  [[ -z "$name" ]] && name=$(infer_name "$url")

  if ! [[ "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    die "Input name '${name}' is not a valid Nix identifier (use --name to override)"
  fi

  if [[ -z "$no_info" ]]; then
    show_input_metadata "$url"
  fi

  if [[ -z "$no_branch" ]]; then
    create_feature_branch "$name"
  fi

  info "Installing input '${name}' from ${url}"

  if grep -qP "^\s+${name}[. =]" flake.nix; then
    die "Input '${name}' already exists in flake.nix (use --name to choose a different name)"
  fi

  local input_file="pkgs/inputs/${name}.nix"
  [[ -f "$input_file" ]] && die "Input file ${input_file} already exists"

  INPUTMAN_CLEANUP_ACTIVE=1
  INPUTMAN_CLEANUP_FILE="$input_file"
  INPUTMAN_CLEANUP_FLAKE=0
  trap 'inputman_install_cleanup "$?"' RETURN

  local system
  system=$(nix eval --impure --expr "builtins.currentSystem" --raw 2>/dev/null || echo "x86_64-linux")

  local -a pkg_list=()
  if [[ -n "$packages_override" ]]; then
    IFS=',' read -ra pkg_list <<<"$packages_override"
  else
    info "Discovering packages from ${url} ..."
    while IFS= read -r line; do
      [[ -n "$line" ]] && pkg_list+=("$line")
    done < <(discover_packages "$url" "$system")
    [[ ${#pkg_list[@]} -eq 0 ]] && pkg_list=("default")
    ok "Using packages: ${pkg_list[*]}"
  fi

  info "Generating ${input_file} ..."
  local content
  content=$(generate_input_file "$name" "${pkg_list[@]}")
  printf '%s' "$content" >>"$input_file"
  ok "Wrote ${input_file}"

  info "Adding input to flake.nix ..."
  INPUTMAN_CLEANUP_FLAKE=1
  patch_flake_add "$name" "$url" "${follows_pairs[@]}"
  ok "Patched flake.nix"

  info "Locking input ${name} ..."
  nix flake lock
  ok "flake.lock updated"

  local news_details="Source: ${url}"$'\n'"Packages: ${pkg_list[*]}"
  local news_file
  news_file=$(write_news_entry install "$name" "$news_details") || news_file=""
  INPUTMAN_CLEANUP_NEWS_FILE="$news_file"

  git add "$input_file" flake.nix flake.lock
  [[ -n "$news_file" ]] && git add "$news_file"

  finalize_commit "inputMan: add input ${name} (${url})" "$auto_commit" "$no_commit"

  INPUTMAN_CLEANUP_ACTIVE=0
  INPUTMAN_CLEANUP_FILE=""
  INPUTMAN_CLEANUP_FLAKE=0
  INPUTMAN_CLEANUP_NEWS_FILE=""
  trap - RETURN
}

cmd_update() {
  local name="" auto_commit="" no_commit=""

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
      if [[ -n "$name" ]]; then
        die "Only one input name may be provided"
      fi
      name="$1"
      shift
      ;;
    esac
  done

  [[ -z "$name" ]] && die "Usage: inputman update <name> [options]"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the repo root"

  info "Updating input '${name}' ..."
  nix flake lock --update-input "$name"
  ok "flake.lock updated for '${name}'"

  local news_file
  news_file=$(write_news_entry update "$name" "") || news_file=""

  git add flake.lock
  [[ -n "$news_file" ]] && git add "$news_file"
  finalize_commit "inputMan: update input ${name}" "$auto_commit" "$no_commit"
}

cmd_remove() {
  local name="" auto_commit="" no_commit=""

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
      if [[ -n "$name" ]]; then
        die "Only one input name may be provided"
      fi
      name="$1"
      shift
      ;;
    esac
  done

  [[ -z "$name" ]] && die "Usage: inputman remove <name> [options]"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the repo root"

  local input_file="pkgs/inputs/${name}.nix"
  [[ -f "$input_file" ]] || die "Input file '${input_file}' not found"

  info "Removing input '${name}' ..."
  rm -f "$input_file"
  patch_flake_remove "$name"
  nix flake lock
  ok "Removed input '${name}' and updated flake.lock"

  local news_file
  news_file=$(write_news_entry remove "$name" "") || news_file=""

  git add "$input_file" flake.nix flake.lock
  [[ -n "$news_file" ]] && git add "$news_file"
  finalize_commit "inputMan: remove input ${name}" "$auto_commit" "$no_commit"
}

case "${1:-help}" in
install)
  shift
  cmd_install "$@"
  ;;
update)
  shift
  cmd_update "$@"
  ;;
remove)
  shift
  cmd_remove "$@"
  ;;
__infer-name)
  shift
  [[ $# -eq 1 ]] || die "Usage: inputman __infer-name <url>"
  infer_name "$1"
  echo
  ;;
__discover-packages)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman __discover-packages <url> <system>"
  discover_packages "$1" "$2"
  ;;
__patch-flake-add)
  shift
  [[ $# -ge 2 ]] || die "Usage: inputman __patch-flake-add <name> <url> [follows...]"
  patch_flake_add "$@"
  ;;
__patch-flake-remove)
  shift
  [[ $# -eq 1 ]] || die "Usage: inputman __patch-flake-remove <name>"
  patch_flake_remove "$1"
  ;;
help | -h | --help) usage ;;
*) die "Unknown command: ${1}. Run 'inputman help' for usage." ;;
esac
