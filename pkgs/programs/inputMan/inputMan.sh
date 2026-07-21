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
  install <url>    Add a flake input and expose its packages + modules
  update <name>    Refresh a locked input; prompt for new packages/modules
  remove <name>    Remove a flake input and its generated files
  help             Show this help

Install options:
  --name <name>          Override the input name (default: inferred from URL)
  --packages, -p <spec>  Package selection. Formats:
                           pkg=alias,pkg2=alias2   (only listed pkgs exposed)
                           pkg1,pkg2               (legacy include list)
                         Bare -p prompts per discovered package.
  --follows, -f <spec>   Follows override. Formats:
                           key=target                    (single-level)
                           parent/child=target           (nested via '/')
                           parent.child=target           (nested via '.')
                         Bare -f/--follows sets
                           <input>.inputs.<self>.follows = ""
                         where <self> is derived from the current flake name.
                         Repeatable.
  --no-info              Skip flake metadata probe output
  --no-branch            Skip creating add-input/<name> branch from origin/master
  --no-modules           Skip module auto-discovery
  --yes, -y              Accept prompts and commit without asking
  --no-commit, -n        Stage changes but do not commit

Update options:
  --no-modules           Skip module re-scan
  --yes, -y              Auto-include new packages/modules with default aliases; commit
  --no-commit, -n        Stage changes but do not commit

Remove options:
  --yes, -y              Commit without prompting
  --no-commit, -n        Stage changes but do not commit

Examples:
  inputman install github:nix-community/nur
  inputman install github:gignsky/gigvim -f nixpkgs=nixpkgs --yes
  inputman install github:gignsky/roll-flow -f gigpkgs/nixpkgs=nixpkgs-master
  inputman install github:some/flake -f            # follow current gigpkgs
  inputman install github:gignsky/gigvim -p default=gigvim,nightly=gigvim-nightly
  inputman update gigvim -y
  inputman remove gigvim --no-commit
EOF_USAGE
}

self_name() {
  basename "$(pwd)"
}

infer_name() {
  local url="$1"
  local base
  base="${url##*/}"
  base="${base%%\?*}"
  printf '%s' "$base"
}

# Discover packages for a given system by probing the input flake.
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

# Discover module names from an input flake for a given output attribute
# (homeManagerModules or nixosModules). Outputs one name per line, or nothing.
discover_modules() {
  local url="$1" attr="$2"
  local names_json
  if names_json=$(nix eval --json "${url}#${attr}" --apply 'set: builtins.attrNames set' 2>/dev/null); then
    echo "$names_json" | jq -r '.[]' 2>/dev/null || true
    return
  fi
  # Legacy attribute name for older home-manager flakes (pre-standardization
  # gigpkgs and some inputs exposed `homeModules`).
  if [[ "$attr" == "homeManagerModules" ]]; then
    if names_json=$(nix eval --json "${url}#homeModules" --apply 'set: builtins.attrNames set' 2>/dev/null); then
      echo "$names_json" | jq -r '.[]' 2>/dev/null || true
      return
    fi
  fi
}

generate_input_file() {
  # Args: name, then pkg=alias pairs.
  local name="$1"
  shift

  printf '# gigpkgs inputMan: managed input\n'
  printf '{ inputs, system }:\n'
  printf '{\n'

  local pair pkg alias
  for pair in "$@"; do
    pkg="${pair%%=*}"
    alias="${pair#*=}"
    printf "  %s = inputs.%s.packages.\${system}.%s;\n" "$alias" "$name" "$pkg"
  done

  printf '}\n'
}

generate_module_file() {
  # Args: input_name, attr (homeManagerModules/nixosModules), then module names.
  local name="$1" attr="$2"
  shift 2

  printf '# gigpkgs inputMan: managed %s aggregator\n' "$attr"
  printf '{ inputs }:\n'
  printf '{\n'

  local mod alias
  for mod in "$@"; do
    if [[ "$mod" == "default" || "$mod" == "$name" ]]; then
      alias="$name"
    else
      alias="${name}-${mod}"
    fi
    printf "  %s = inputs.%s.%s.%s;\n" "$alias" "$name" "$attr" "$mod"
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

# Validate a follows spec: KEY=VALUE where KEY may contain '/' or '.' segments.
# VALUE may be empty (means "follow current top-level flake").
validate_follows_pair() {
  local pair="$1"
  [[ "$pair" == *=* ]] || die "Invalid --follows value '${pair}' (expected key=value)"

  local key="${pair%%=*}"
  local value="${pair#*=}"

  [[ -n "$key" ]] || die "Invalid --follows value '${pair}' (empty key)"

  local normalized="${key//\//.}"
  local seg
  local IFS=.
  # shellcheck disable=SC2206
  local segs=($normalized)
  for seg in "${segs[@]}"; do
    [[ "$seg" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "Invalid follows key segment '${seg}' in '${key}'"
  done
  unset IFS

  if [[ -n "$value" ]]; then
    [[ "$value" =~ ^[a-zA-Z0-9._/-]+$ ]] || die "Invalid follows target '${value}'"
  fi
}

# Normalize a follows key so the perl side sees dot-separated segments.
normalize_follows_pair() {
  local pair="$1"
  local key="${pair%%=*}"
  local value="${pair#*=}"
  key="${key//\//.}"
  printf '%s=%s' "$key" "$value"
}

patch_flake_add() {
  local name="$1" url="$2"
  shift 2

  local follows_newline=""
  local pair
  for pair in "$@"; do
    follows_newline+="$(normalize_follows_pair "$pair")"$'\n'
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
      $v = "" unless defined $v;
      my @segs = split /\./, $k;
      my $chain = join('.inputs.', @segs);
      push @insert_lines, qq{$entry_indent$n.inputs.$chain.follows = "$v";};
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
    $inner =~ s/^\h*\Q$n\E(?:\.inputs\.[a-zA-Z][a-zA-Z0-9_-]*)+\.follows\h*=\h*".*?";\h*\n//mg;

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

# Read the set of pkg=alias pairs currently exposed by pkgs/inputs/<name>.nix.
current_package_pairs() {
  local name="$1"
  local file="pkgs/inputs/${name}.nix"
  [[ -f "$file" ]] || return 0
  local pattern='^\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*inputs\.'"$name"'\.packages\.\$\{system\}\.([A-Za-z0-9_-]+);'
  while IFS= read -r line; do
    if [[ "$line" =~ $pattern ]]; then
      printf '%s=%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
    fi
  done <"$file"
}

# Read mod=alias pairs currently exposed by modules/<home|nixos>/inputs/<name>.nix.
current_module_pairs() {
  local name="$1" kind="$2"
  local attr
  case "$kind" in
  home) attr="homeManagerModules" ;;
  nixos) attr="nixosModules" ;;
  *) return 1 ;;
  esac
  local file="modules/${kind}/inputs/${name}.nix"
  [[ -f "$file" ]] || return 0
  local pattern='^\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*inputs\.'"$name"'\.'"$attr"'\.([A-Za-z0-9_-]+);'
  while IFS= read -r line; do
    if [[ "$line" =~ $pattern ]]; then
      printf '%s=%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
    fi
  done <"$file"
}

# Render a rescan-section header for `inputman update` output. Streams the
# announcement + list of currently-exposed entries to stderr so the caller can
# still capture command output.
print_rescan_section() {
  local label="$1" input_name="$2"
  shift 2
  printf '\n%b[inputMan]%b %s rescan for %s\n' "$BLUE" "$NC" "$label" "'${input_name}'" >&2
  if [[ $# -eq 0 ]]; then
    printf '    %bcurrently exposed:%b (none)\n' "$YELLOW" "$NC" >&2
  else
    printf '    %bcurrently exposed:%b\n' "$YELLOW" "$NC" >&2
    local item
    for item in "$@"; do
      printf '      - %s\n' "$item" >&2
    done
  fi
}

# Prompt for a single new package: emits `pkg=alias` on stdout, or nothing to
# skip. All UI goes to stderr.
prompt_package_alias() {
  local input_name="$1" pkg="$2"
  local default_alias
  if [[ "$pkg" == "default" || "$pkg" == "$input_name" ]]; then
    default_alias="$input_name"
  else
    default_alias="${input_name}-${pkg}"
  fi
  printf '\n    %bnew package:%b %s  (packages.%s)\n' "$YELLOW" "$NC" "$pkg" "$pkg" >&2
  local answer
  read -rp "      alias [${default_alias}] (blank=default, '-' to skip): " answer </dev/tty
  case "$answer" in
  "") printf '%s=%s\n' "$pkg" "$default_alias" ;;
  -) : ;;
  *) printf '%s=%s\n' "$pkg" "$answer" ;;
  esac
}

# Prompt for a single new module: emits `mod=alias` on stdout, or nothing to skip.
prompt_module_alias() {
  local input_name="$1" mod="$2" attr="$3"
  local default_alias
  if [[ "$mod" == "default" || "$mod" == "$input_name" ]]; then
    default_alias="$input_name"
  else
    default_alias="${input_name}-${mod}"
  fi
  printf '\n    %bnew module:%b %s  (%s.%s)\n' "$YELLOW" "$NC" "$mod" "$attr" "$mod" >&2
  local answer
  read -rp "      alias [${default_alias}] (blank=default, '-' to skip): " answer </dev/tty
  case "$answer" in
  "") printf '%s=%s\n' "$mod" "$default_alias" ;;
  -) : ;;
  *) printf '%s=%s\n' "$mod" "$answer" ;;
  esac
}

# Parse a --packages spec into pkg=alias pairs.
# Accepts:
#   pkg1=alias,pkg2=alias   (key=value list)
#   pkg1,pkg2               (legacy include list; alias defaults to pkg / input-name)
parse_packages_spec() {
  local input_name="$1" spec="$2"
  local IFS=','
  # shellcheck disable=SC2206
  local items=($spec)
  unset IFS
  local item pkg alias
  for item in "${items[@]}"; do
    [[ -z "$item" ]] && continue
    if [[ "$item" == *=* ]]; then
      pkg="${item%%=*}"
      alias="${item#*=}"
      [[ "$alias" == "-" ]] && continue
    else
      pkg="$item"
      if [[ "$pkg" == "default" || "$pkg" == "$input_name" ]]; then
        alias="$input_name"
      else
        alias="${input_name}-${pkg}"
      fi
    fi
    printf '%s=%s\n' "$pkg" "$alias"
  done
}

# Default selection: expose every discovered package with the default alias.
default_package_selection() {
  local input_name="$1"
  shift
  local pkg alias
  for pkg in "$@"; do
    if [[ "$pkg" == "default" || "$pkg" == "$input_name" ]]; then
      alias="$input_name"
    else
      alias="${input_name}-${pkg}"
    fi
    printf '%s=%s\n' "$pkg" "$alias"
  done
}

# Next monotonic `num` for a news entry: max existing num + 1 (1 if none).
# Every entry must carry a unique `num` or the gignews collector throws
# (news/default.nix), which fails `nix flake check`.
next_news_num() {
  local news_dir="news/entries" max=0 n f
  for f in "$news_dir"/*.nix; do
    [[ -e "$f" ]] || continue
    n=$(grep -oE 'num[[:space:]]*=[[:space:]]*[0-9]+' "$f" | grep -oE '[0-9]+' | head -1)
    if [[ -n "$n" ]] && ((n > max)); then max="$n"; fi
  done
  printf '%s' "$((max + 1))"
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

  local num
  num=$(next_news_num)

  {
    printf '{\n'
    printf '  id = "%s";\n' "$id"
    printf '  num = %s;\n' "$num"
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

  if ! git show-ref --verify --quiet refs/remotes/origin/master; then
    if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
      git fetch --unshallow origin >/dev/null 2>&1 || die "Failed to fetch full history from origin"
    fi
    git fetch origin master:refs/remotes/origin/master >/dev/null 2>&1 ||
      die "Failed to fetch origin/master"
  fi

  git checkout -b "$branch" refs/remotes/origin/master >/dev/null 2>&1 ||
    die "Failed to create branch '${branch}' from origin/master"
  ok "Created and switched to branch '${branch}'"
}

INPUTMAN_CLEANUP_ACTIVE=0
INPUTMAN_CLEANUP_FILE=""
INPUTMAN_CLEANUP_FLAKE=0
INPUTMAN_CLEANUP_NEWS_FILE=""
INPUTMAN_CLEANUP_HOME_MOD=""
INPUTMAN_CLEANUP_NIXOS_MOD=""

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

  if [[ -n "${INPUTMAN_CLEANUP_HOME_MOD:-}" && -f "${INPUTMAN_CLEANUP_HOME_MOD}" ]]; then
    rm -f "${INPUTMAN_CLEANUP_HOME_MOD}"
    rolled_back=1
  fi

  if [[ -n "${INPUTMAN_CLEANUP_NIXOS_MOD:-}" && -f "${INPUTMAN_CLEANUP_NIXOS_MOD}" ]]; then
    rm -f "${INPUTMAN_CLEANUP_NIXOS_MOD}"
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
    warn "Install failed. Rolled back flake.nix and generated files."
  fi
}

# Write a module aggregator file if the input exposes modules of the given kind.
# Returns the generated file path on stdout, or empty if none written.
maybe_generate_module_aggregator() {
  local name="$1" url="$2" kind="$3" auto_yes="$4"
  local attr subdir
  case "$kind" in
  home)
    attr="homeManagerModules"
    subdir="modules/home/inputs"
    ;;
  nixos)
    attr="nixosModules"
    subdir="modules/nixos/inputs"
    ;;
  *) return 1 ;;
  esac

  local -a mods=()
  while IFS= read -r mod; do
    [[ -n "$mod" ]] && mods+=("$mod")
  done < <(discover_modules "$url" "$attr")

  [[ ${#mods[@]} -eq 0 ]] && return 0

  info "Discovered ${#mods[@]} ${kind} module(s) in '${name}': ${mods[*]}" >&2

  # Selection: default aliases; when interactive (no --yes), prompt per module.
  local -a selection=()
  local mod pair
  if [[ -n "$auto_yes" ]]; then
    for mod in "${mods[@]}"; do
      if [[ "$mod" == "default" || "$mod" == "$name" ]]; then
        selection+=("${mod}=${name}")
      else
        selection+=("${mod}=${name}-${mod}")
      fi
    done
  else
    for mod in "${mods[@]}"; do
      pair=$(prompt_module_alias "$name" "$mod" "$attr" || true)
      [[ -n "$pair" ]] && selection+=("$pair")
    done
  fi

  [[ ${#selection[@]} -eq 0 ]] && return 0

  mkdir -p "$subdir"
  local file="${subdir}/${name}.nix"
  # Convert selection (mod=alias) into args to generate_module_file: input name, attr, module names…
  # Then emit alias directly.
  {
    printf '# gigpkgs inputMan: managed %s aggregator\n' "$attr"
    printf '{ inputs }:\n'
    printf '{\n'
    local sel mod2 alias2
    for sel in "${selection[@]}"; do
      mod2="${sel%%=*}"
      alias2="${sel#*=}"
      printf "  %s = inputs.%s.%s.%s;\n" "$alias2" "$name" "$attr" "$mod2"
    done
    printf '}\n'
  } >"$file"

  ok "Wrote ${file}" >&2
  printf '%s' "$file"
}

cmd_install() {
  local url="" name="" packages_arg="" packages_flag="" auto_commit="" no_commit=""
  local no_info="" no_branch="" no_modules=""
  local -a follows_pairs=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --name)
      name="$2"
      shift 2
      ;;
    --packages | -p)
      if [[ $# -ge 2 && "$2" != -* ]]; then
        packages_arg="$2"
        shift 2
      else
        packages_flag="prompt"
        shift
      fi
      ;;
    --follows | -f)
      if [[ $# -ge 2 && "$2" != -* && "$2" == *=* ]]; then
        validate_follows_pair "$2"
        follows_pairs+=("$2")
        shift 2
      else
        follows_pairs+=("$(self_name)=")
        shift
      fi
      ;;
    --no-info)
      no_info=1
      shift
      ;;
    --no-branch)
      no_branch=1
      shift
      ;;
    --no-modules)
      no_modules=1
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
  INPUTMAN_CLEANUP_HOME_MOD=""
  INPUTMAN_CLEANUP_NIXOS_MOD=""
  trap 'inputman_install_cleanup "$?"' RETURN

  local system
  system=$(nix eval --impure --expr "builtins.currentSystem" --raw 2>/dev/null || echo "x86_64-linux")

  local -a discovered=()
  info "Discovering packages from ${url} ..."
  while IFS= read -r line; do
    [[ -n "$line" ]] && discovered+=("$line")
  done < <(discover_packages "$url" "$system")
  [[ ${#discovered[@]} -eq 0 ]] && discovered=("default")
  ok "Discovered packages: ${discovered[*]}"

  local -a selection=()
  if [[ "$packages_flag" == "prompt" ]]; then
    info "Prompting per package (blank=default alias, '-' to skip):"
    local pkg pair
    for pkg in "${discovered[@]}"; do
      pair=$(prompt_package_alias "$name" "$pkg" || true)
      [[ -n "$pair" ]] && selection+=("$pair")
    done
  elif [[ -n "$packages_arg" ]]; then
    while IFS= read -r pair; do
      [[ -n "$pair" ]] && selection+=("$pair")
    done < <(parse_packages_spec "$name" "$packages_arg")
  else
    while IFS= read -r pair; do
      [[ -n "$pair" ]] && selection+=("$pair")
    done < <(default_package_selection "$name" "${discovered[@]}")
  fi

  [[ ${#selection[@]} -eq 0 ]] && die "No packages selected for '${name}'."

  info "Generating ${input_file} ..."
  local content
  content=$(generate_input_file "$name" "${selection[@]}")
  printf '%s' "$content" >>"$input_file"
  ok "Wrote ${input_file}"

  info "Adding input to flake.nix ..."
  INPUTMAN_CLEANUP_FLAKE=1
  if [[ ${#follows_pairs[@]} -eq 0 ]]; then
    patch_flake_add "$name" "$url"
  else
    patch_flake_add "$name" "$url" "${follows_pairs[@]}"
  fi
  ok "Patched flake.nix"

  info "Locking input ${name} ..."
  nix flake lock
  ok "flake.lock updated"

  local home_mod_file="" nixos_mod_file=""
  if [[ -z "$no_modules" ]]; then
    info "Scanning ${name} for home-manager / NixOS modules ..."
    home_mod_file=$(maybe_generate_module_aggregator "$name" "$url" home "$auto_commit" || true)
    INPUTMAN_CLEANUP_HOME_MOD="$home_mod_file"
    nixos_mod_file=$(maybe_generate_module_aggregator "$name" "$url" nixos "$auto_commit" || true)
    INPUTMAN_CLEANUP_NIXOS_MOD="$nixos_mod_file"
  fi

  local pkg_summary
  pkg_summary=$(printf '%s ' "${selection[@]}")
  local news_details="Source: ${url}"$'\n'"Packages: ${pkg_summary%% }"
  [[ -n "$home_mod_file" ]] && news_details+=$'\n'"Home modules aggregator: ${home_mod_file}"
  [[ -n "$nixos_mod_file" ]] && news_details+=$'\n'"NixOS modules aggregator: ${nixos_mod_file}"
  local news_file
  news_file=$(write_news_entry install "$name" "$news_details") || news_file=""
  INPUTMAN_CLEANUP_NEWS_FILE="$news_file"

  git add "$input_file" flake.nix flake.lock
  [[ -n "$home_mod_file" ]] && git add "$home_mod_file"
  [[ -n "$nixos_mod_file" ]] && git add "$nixos_mod_file"
  [[ -n "$news_file" ]] && git add "$news_file"

  finalize_commit "inputMan: add input ${name} (${url})" "$auto_commit" "$no_commit"

  INPUTMAN_CLEANUP_ACTIVE=0
  INPUTMAN_CLEANUP_FILE=""
  INPUTMAN_CLEANUP_FLAKE=0
  INPUTMAN_CLEANUP_HOME_MOD=""
  INPUTMAN_CLEANUP_NIXOS_MOD=""
  INPUTMAN_CLEANUP_NEWS_FILE=""
  trap - RETURN
}

# Read a locked URL for input <name> from flake.lock so update rescans use the
# same source of truth as the flake.
locked_input_url() {
  local name="$1"
  [[ -f flake.lock ]] || return 1
  nix eval --json --impure --expr "
    let lock = builtins.fromJSON (builtins.readFile ./flake.lock);
        node = lock.nodes.\"${name}\" or null;
    in
      if node == null then null
      else if node ? original then
        let o = node.original; in
        if o.type == \"github\" then
          \"github:\${o.owner}/\${o.repo}\" + (if o ? ref then \"/\${o.ref}\" else \"\")
        else if o.type == \"git\" then o.url
        else if o.type == \"path\" then \"path:\${o.path}\"
        else if o ? url then o.url
        else null
      else null
  " 2>/dev/null | jq -r 'select(. != null)' 2>/dev/null || return 1
}

# Append lines describing new packages/modules to an existing aggregator file.
# Insert before the closing '}'.
append_lines_before_close() {
  local file="$1"
  shift
  # remaining args: lines to insert
  local tmp
  tmp=$(mktemp)
  local inserted=0
  while IFS= read -r line; do
    if [[ "$inserted" -eq 0 && "$line" =~ ^\}[[:space:]]*$ ]]; then
      local extra
      for extra in "$@"; do
        printf '%s\n' "$extra"
      done >>"$tmp"
      inserted=1
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$file"
  mv "$tmp" "$file"
}

# Append pkg=alias entries to pkgs/inputs/<name>.nix.
append_package_entries() {
  local name="$1"
  shift
  local file="pkgs/inputs/${name}.nix"
  [[ -f "$file" ]] || die "Input file '${file}' missing; cannot append entries"

  local -a lines=()
  local pair pkg alias
  for pair in "$@"; do
    pkg="${pair%%=*}"
    alias="${pair#*=}"
    lines+=("  ${alias} = inputs.${name}.packages.\${system}.${pkg};")
  done
  append_lines_before_close "$file" "${lines[@]}"
}

# Append module entries to modules/<kind>/inputs/<name>.nix; create if missing.
append_module_entries() {
  local name="$1" kind="$2"
  shift 2
  local attr subdir
  case "$kind" in
  home)
    attr="homeManagerModules"
    subdir="modules/home/inputs"
    ;;
  nixos)
    attr="nixosModules"
    subdir="modules/nixos/inputs"
    ;;
  *) return 1 ;;
  esac

  mkdir -p "$subdir"
  local file="${subdir}/${name}.nix"
  if [[ ! -f "$file" ]]; then
    {
      printf '# gigpkgs inputMan: managed %s aggregator\n' "$attr"
      printf '{ inputs }:\n'
      printf '{\n'
      printf '}\n'
    } >"$file"
  fi

  local -a lines=()
  local pair mod alias
  for pair in "$@"; do
    mod="${pair%%=*}"
    alias="${pair#*=}"
    lines+=("  ${alias} = inputs.${name}.${attr}.${mod};")
  done
  append_lines_before_close "$file" "${lines[@]}"

  printf '%s' "$file"
}

cmd_update() {
  local name="" auto_commit="" no_commit="" no_modules=""

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
    --no-modules)
      no_modules=1
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
  nix flake update "$name"
  ok "flake.lock updated for '${name}'"

  local system
  system=$(nix eval --impure --expr "builtins.currentSystem" --raw 2>/dev/null || echo "x86_64-linux")

  local url=""
  url=$(locked_input_url "$name" 2>/dev/null || true)
  if [[ -z "$url" ]]; then
    warn "Could not determine locked URL for '${name}'; skipping rescan."
  fi

  local -a added_pkgs=() added_home=() added_nixos=()

  if [[ -n "$url" ]]; then
    local pair pkg mod

    # ── Package rescan ────────────────────────────────────────────────
    local -a discovered=() existing_pkg_display=() new_pkg_list=()
    local -A current_pkg_map=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && discovered+=("$line")
    done < <(discover_packages "$url" "$system")
    while IFS= read -r pair; do
      [[ -z "$pair" ]] && continue
      current_pkg_map["${pair%%=*}"]=1
      existing_pkg_display+=("${pair#*=}  <-  packages.${pair%%=*}")
    done < <(current_package_pairs "$name")
    for pkg in "${discovered[@]}"; do
      [[ -z "${current_pkg_map[$pkg]:-}" ]] && new_pkg_list+=("$pkg")
    done
    if [[ ${#new_pkg_list[@]} -gt 0 ]]; then
      print_rescan_section "packages" "$name" "${existing_pkg_display[@]}"
      for pkg in "${new_pkg_list[@]}"; do
        if [[ -n "$auto_commit" ]]; then
          if [[ "$pkg" == "default" || "$pkg" == "$name" ]]; then
            added_pkgs+=("${pkg}=${name}")
          else
            added_pkgs+=("${pkg}=${name}-${pkg}")
          fi
        else
          pair=$(prompt_package_alias "$name" "$pkg" || true)
          [[ -n "$pair" ]] && added_pkgs+=("$pair")
        fi
      done
    fi

    if [[ -z "$no_modules" ]]; then
      # ── Home modules rescan ────────────────────────────────────────
      local -a discovered_home=() existing_home_display=() new_home_list=()
      local -A current_home_map=()
      while IFS= read -r line; do
        [[ -n "$line" ]] && discovered_home+=("$line")
      done < <(discover_modules "$url" "homeManagerModules")
      while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        current_home_map["${pair%%=*}"]=1
        existing_home_display+=("${pair#*=}  <-  homeManagerModules.${pair%%=*}")
      done < <(current_module_pairs "$name" home)
      for mod in "${discovered_home[@]}"; do
        [[ -z "${current_home_map[$mod]:-}" ]] && new_home_list+=("$mod")
      done
      if [[ ${#new_home_list[@]} -gt 0 ]]; then
        print_rescan_section "home modules" "$name" "${existing_home_display[@]}"
        for mod in "${new_home_list[@]}"; do
          if [[ -n "$auto_commit" ]]; then
            if [[ "$mod" == "default" || "$mod" == "$name" ]]; then
              added_home+=("${mod}=${name}")
            else
              added_home+=("${mod}=${name}-${mod}")
            fi
          else
            pair=$(prompt_module_alias "$name" "$mod" "homeManagerModules" || true)
            [[ -n "$pair" ]] && added_home+=("$pair")
          fi
        done
      fi

      # ── NixOS modules rescan ───────────────────────────────────────
      local -a discovered_nixos=() existing_nixos_display=() new_nixos_list=()
      local -A current_nixos_map=()
      while IFS= read -r line; do
        [[ -n "$line" ]] && discovered_nixos+=("$line")
      done < <(discover_modules "$url" "nixosModules")
      while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        current_nixos_map["${pair%%=*}"]=1
        existing_nixos_display+=("${pair#*=}  <-  nixosModules.${pair%%=*}")
      done < <(current_module_pairs "$name" nixos)
      for mod in "${discovered_nixos[@]}"; do
        [[ -z "${current_nixos_map[$mod]:-}" ]] && new_nixos_list+=("$mod")
      done
      if [[ ${#new_nixos_list[@]} -gt 0 ]]; then
        print_rescan_section "nixos modules" "$name" "${existing_nixos_display[@]}"
        for mod in "${new_nixos_list[@]}"; do
          if [[ -n "$auto_commit" ]]; then
            if [[ "$mod" == "default" || "$mod" == "$name" ]]; then
              added_nixos+=("${mod}=${name}")
            else
              added_nixos+=("${mod}=${name}-${mod}")
            fi
          else
            pair=$(prompt_module_alias "$name" "$mod" "nixosModules" || true)
            [[ -n "$pair" ]] && added_nixos+=("$pair")
          fi
        done
      fi
    fi
  fi

  local home_mod_file="" nixos_mod_file=""
  if [[ ${#added_pkgs[@]} -gt 0 ]]; then
    append_package_entries "$name" "${added_pkgs[@]}"
    ok "Added ${#added_pkgs[@]} new package entry(ies) to pkgs/inputs/${name}.nix"
  fi
  if [[ ${#added_home[@]} -gt 0 ]]; then
    home_mod_file=$(append_module_entries "$name" home "${added_home[@]}")
    ok "Added ${#added_home[@]} new home module entry(ies) to ${home_mod_file}"
  fi
  if [[ ${#added_nixos[@]} -gt 0 ]]; then
    nixos_mod_file=$(append_module_entries "$name" nixos "${added_nixos[@]}")
    ok "Added ${#added_nixos[@]} new nixos module entry(ies) to ${nixos_mod_file}"
  fi

  local news_details=""
  [[ ${#added_pkgs[@]} -gt 0 ]] && news_details+="New packages: ${added_pkgs[*]}"$'\n'
  [[ ${#added_home[@]} -gt 0 ]] && news_details+="New home modules: ${added_home[*]}"$'\n'
  [[ ${#added_nixos[@]} -gt 0 ]] && news_details+="New nixos modules: ${added_nixos[*]}"$'\n'
  local news_file
  news_file=$(write_news_entry update "$name" "$news_details") || news_file=""

  git add flake.lock "pkgs/inputs/${name}.nix" 2>/dev/null || true
  [[ -n "$home_mod_file" ]] && git add "$home_mod_file"
  [[ -n "$nixos_mod_file" ]] && git add "$nixos_mod_file"
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

  local home_mod_file="modules/home/inputs/${name}.nix"
  local nixos_mod_file="modules/nixos/inputs/${name}.nix"

  info "Removing input '${name}' ..."
  rm -f "$input_file"
  [[ -f "$home_mod_file" ]] && rm -f "$home_mod_file"
  [[ -f "$nixos_mod_file" ]] && rm -f "$nixos_mod_file"
  patch_flake_remove "$name"
  nix flake lock
  ok "Removed input '${name}' and updated flake.lock"

  local news_file
  news_file=$(write_news_entry remove "$name" "") || news_file=""

  git add "$input_file" flake.nix flake.lock
  [[ -f "$home_mod_file" ]] || git add "$home_mod_file" 2>/dev/null || true
  [[ -f "$nixos_mod_file" ]] || git add "$nixos_mod_file" 2>/dev/null || true
  git rm --ignore-unmatch "$home_mod_file" "$nixos_mod_file" >/dev/null 2>&1 || true
  [[ -n "$news_file" ]] && git add "$news_file"
  finalize_commit "inputMan: remove input ${name}" "$auto_commit" "$no_commit"
}

# Run pre-commit on all files (letting hooks reformat), re-stage the files
# inputman touched, then commit.  Falls back to a plain commit if pre-commit
# is not installed or has no config.
do_commit() {
  local msg="$1"
  shift
  local -a files=("$@")

  if command -v pre-commit &>/dev/null; then
    info "Running pre-commit hooks ..."
    pre-commit run --all-files 2>&1 || true
    git add "${files[@]}"
    ok "Pre-commit done."
  fi

  git commit -m "$msg"
  ok "Committed."
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
__self-name)
  shift
  self_name
  echo
  ;;
__discover-packages)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman __discover-packages <url> <system>"
  discover_packages "$1" "$2"
  ;;
__discover-modules)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman __discover-modules <url> <attr>"
  discover_modules "$1" "$2"
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
__parse-packages-spec)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman __parse-packages-spec <input-name> <spec>"
  parse_packages_spec "$1" "$2"
  ;;
help | -h | --help) usage ;;
*) die "Unknown command: ${1}. Run 'inputman help' for usage." ;;
esac
