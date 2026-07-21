# shellcheck shell=bash
# inputMan shared library.
#
# Sourced by inputMan.sh and inputman-lite.sh. Holds the repo-agnostic core:
# the Perl flake.nix patcher, input/module discovery, follows handling, news +
# commit plumbing, flake.lock introspection, and the channel-map helpers used
# by `inputman group-install`/`freeze` and the channel-aware pin mechanism.
#
# Do NOT `set -euo pipefail` here — the sourcing script owns shell options.

# Colour palette (guard against re-definition when multiple scripts source us).
: "${RED:=$'\033[0;31m'}"
: "${GREEN:=$'\033[0;32m'}"
: "${YELLOW:=$'\033[1;33m'}"
: "${BLUE:=$'\033[0;34m'}"
: "${NC:=$'\033[0m'}"

info() { printf "${BLUE}[inputMan]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[inputMan]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[inputMan]${NC} %s\n" "$*" >&2; }
die() {
  printf "${RED}[inputMan] error:${NC} %s\n" "$*" >&2
  exit 1
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
    if ($ENV{INPUT_FLAKE_FALSE}) {
      # `flake = false` source pins carry no inputs, so follows are invalid.
      push @insert_lines, qq{$entry_indent$n.flake = false;};
    } else {
      for my $raw (split /\n/, $follows_raw) {
        next if $raw eq q{};
        my ($k, $v) = split /=/, $raw, 2;
        $v = "" unless defined $v;
        my @segs = split /\./, $k;
        my $chain = join('.inputs.', @segs);
        push @insert_lines, qq{$entry_indent$n.inputs.$chain.follows = "$v";};
      }
    }

    my $insert = "\n" . join("\n", @insert_lines) . "\n";
    substr($_, $close_pos, 0, $insert);
PERL
  )

  local err_file
  err_file=$(mktemp)
  if ! INPUT_NAME="$name" INPUT_URL="$url" INPUT_FOLLOWS="$follows_newline" INPUT_FLAKE_FALSE="${INPUT_FLAKE_FALSE:-}" perl -i -0pe "$perl_script" flake.nix 2>"$err_file"; then
    local err
    err=$(cat "$err_file")
    rm -f "$err_file"
    die "Failed to patch flake.nix: ${err:-unknown patch error}"
  fi

  rm -f "$err_file"
}

# Add a `flake = false` source input (url + `flake = false;`, no follows).
patch_flake_add_nonflake() {
  local name="$1" url="$2"
  INPUT_FLAKE_FALSE=1 patch_flake_add "$name" "$url"
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
  group-install)
    headline="Added channel-mapped input group '${name}'"
    body="A channel-aware multi-version input group was installed by inputMan."
    ;;
  freeze)
    headline="Froze input '${name}' for a channel"
    body="A channel was pinned to a frozen revision of this program by inputMan."
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

# Read the locked git revision (.locked.rev) for input <name> from flake.lock.
# Pure JSON read via jq (no nix eval needed). Empty output if absent.
locked_input_rev() {
  local name="$1"
  [[ -f flake.lock ]] || return 1
  jq -r --arg n "$name" '.nodes[$n].locked.rev // empty' flake.lock 2>/dev/null
}

# Print "true" if input <name> is a `flake = false` source pin (per flake.lock),
# else nothing. Used to mirror a moving input's flake-ness when freezing.
locked_input_is_nonflake() {
  local name="$1"
  [[ -f flake.lock ]] || return 1
  jq -r --arg n "$name" 'if (.nodes[$n].flake == false) then "true" else empty end' flake.lock 2>/dev/null
}

# Print the immutable github base "github:OWNER/REPO" for a locked input.
# Reads flake.lock (original, falling back to locked). Empty if not a github input.
locked_github_base() {
  local name="$1"
  [[ -f flake.lock ]] || return 1
  jq -r --arg n "$name" '
    (.nodes[$n].original // .nodes[$n].locked) as $o
    | if ($o.type == "github") then "github:\($o.owner)/\($o.repo)" else empty end
  ' flake.lock 2>/dev/null
}

# Slugify a version/label into a valid Nix identifier segment: '.' and '/' -> '-'.
# Dies if the result is not a valid identifier (so patch_flake_add's own name
# check never rejects a computed sibling name downstream).
slug_version() {
  local v="$1"
  local slug="${v//./-}"
  slug="${slug//\//-}"
  [[ "$slug" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] ||
    die "Version/label '${v}' does not slugify to a valid Nix identifier (got '${slug}')"
  printf '%s' "$slug"
}

# Emit a channel-aware aggregator for pkgs/inputs/<program>.nix. The generated
# file reads the projected channel.nix and channel-sources.nix to pick which
# sibling input backs `pkgs.<program>`, so selection survives CI projection.
generate_group_aggregator() {
  local program="$1"
  printf '# gigpkgs inputMan: managed channel-mapped input (%s)\n' "$program"
  printf '{ inputs, system }:\n'
  printf 'let\n'
  printf '  channel   = import ../../channel.nix;\n'
  printf '  sources   = (import ../../channel-sources.nix).%s;\n' "$program"
  printf '  inputName = sources.${channel} or sources.default;\n'
  printf '  src       = inputs.${inputName};\n'
  printf 'in\n'
  printf '{\n'
  printf '  %s = src.packages.${system}.default;\n' "$program"
  printf '}\n'
}

# Upsert `"<channel>" = "<inputname>";` inside the `<program> = { … };` block of
# channel-sources.nix (default file, override with 4th arg). Replaces an existing
# entry for that channel, else inserts before the `default =` line. Brace-matched
# so it is robust to formatting; matches inputMan's one-attr-per-line style.
patch_channel_map_set() {
  local program="$1" channel="$2" inputname="$3"
  local file="${4:-channel-sources.nix}"
  [[ -f "$file" ]] || die "channel map file '${file}' not found"

  local err_file
  err_file=$(mktemp)
  if ! PROG="$program" CH="$channel" IN="$inputname" perl -0pi -e '
    use strict; use warnings;
    my ($p, $c, $i) = ($ENV{PROG}, $ENV{CH}, $ENV{IN});

    $_ =~ /(?<![\w-])\Q$p\E\s*=\s*\{/g
      or die "channel-sources.nix: no block for program \x27$p\x27\n";
    my $bo = pos($_) - 1;              # index of the opening brace

    my $depth = 1; my $j = $bo + 1; my $len = length($_);
    while ($j < $len) {
      my $ch = substr($_, $j, 1);
      if ($ch eq "{") { $depth++; }
      elsif ($ch eq "}") { $depth--; last if $depth == 0; }
      $j++;
    }
    die "channel-sources.nix: unterminated block for \x27$p\x27\n" if $depth != 0;

    my $body = substr($_, $bo + 1, $j - ($bo + 1));
    my $entry = qq{"$c" = "$i";};

    if ($body =~ s/"\Q$c\E"\s*=\s*"[^"]*";/$entry/) {
      # replaced an existing entry for this channel
    } elsif ($body =~ /\n([^\S\n]*)default\s*=/) {
      my $ind = $1;
      $body =~ s/(\n[^\S\n]*default\s*=)/\n$ind$entry$1/;
    } else {
      my $ind = ($body =~ /\n([^\S\n]*)\S/) ? $1 : "    ";
      $body =~ s/(\s*)\z/\n$ind$entry$1/;
    }

    substr($_, $bo + 1, $j - ($bo + 1), $body);
  ' "$file" 2>"$err_file"; then
    local err
    err=$(cat "$err_file")
    rm -f "$err_file"
    die "Failed to patch ${file}: ${err:-unknown patch error}"
  fi
  rm -f "$err_file"
}

# Ensure channel-sources.nix has a `<program> = { … };` block; create an empty
# one (inserted before the file's final closing brace) if absent. Idempotent.
ensure_channel_map_block() {
  local program="$1" file="${2:-channel-sources.nix}"
  [[ -f "$file" ]] || die "channel map file '${file}' not found"

  if PROG="$program" perl -0ne 'exit(($_ =~ /(?<![\w-])\Q$ENV{PROG}\E\s*=\s*\{/) ? 0 : 1)' "$file"; then
    return 0
  fi

  local err_file
  err_file=$(mktemp)
  if ! PROG="$program" perl -0pi -e '
    my $p = $ENV{PROG};
    s/(\n\})\s*\z/\n  $p = {\n  };$1/
      or die "channel-sources.nix: could not find top-level closing brace\n";
  ' "$file" 2>"$err_file"; then
    local err
    err=$(cat "$err_file")
    rm -f "$err_file"
    die "Failed to patch ${file}: ${err:-unknown patch error}"
  fi
  rm -f "$err_file"
}
