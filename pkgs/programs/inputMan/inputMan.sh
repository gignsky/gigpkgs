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
  install <url>        Add a flake input and expose its packages + modules
  update <name>        Refresh a locked input; prompt for new packages/modules
  remove <name>        Remove a flake input and its generated files
  pin <name> <ref>     Materialize a permanent "<name>-<ref>" package (e.g.
                        roll-flow-0.2.5), backed by its own frozen flake
                        input. The bare <name> package is untouched and keeps
                        tracking whatever 'update'/'branch' has it at. <ref>
                        may be an upstream tag/branch/rev, OR a version
                        string this repo has previously seen for <name> (even
                        one never tagged upstream, e.g. on a rolling branch).
                        'update'/'branch' also do this automatically whenever
                        they change <name>'s version, for both the version
                        being left behind and the one just moved to
  versions <name>      List known versions for an input: upstream tags, plus
                        anything recorded in gigpkgs' own update/branch
                        history — as candidates for 'pin'. Marks which ones
                        are already materialized
  branch <name> [b]    Point an input at a different branch (fuzzy-picked via
                        fzf when no branch is given) and relock it
  doctor [--fix]       Report inputs that track gigpkgs (a circular dependency)
                        with the exact -f overrides that break the loop;
                        --fix applies them to flake.nix and relocks. install,
                        update, branch and pin apply them automatically
  tidy                 Rewrite flake.nix inputs split across several lines
                        (a.url = ..; a.inputs.x.follows = ..) into the single
                        attribute-set form statix and nixfmt expect
  help                 Show this help

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
  --no-auto-follows      Do not auto-add follows for inputs that track gigpkgs
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

Pin options:
  --yes, -y              Commit without prompting
  --no-commit, -n        Stage changes but do not commit

Versions options:
  --limit <n>            Max tags to show (default: 25, newest first)

Branch options:
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
  inputman versions roll-flow                      # list tags/recorded versions to pin to
  inputman pin roll-flow v0.2.3                    # materialize roll-flow-v0.2.3, permanently
  inputman branch roll-flow develop                # track a rolling branch (bare pkg follows it)
  inputman pin roll-flow 0.2.5                     # materialize roll-flow-0.2.5 from a version
                                                    # develop reported but never tagged upstream
  inputman branch roll-flow                        # fuzzy-pick a branch
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

# One `alias = rhs;` attribute line, wrapped the way nixfmt wraps one that runs
# past 100 columns, so generated aggregators pass the nixfmt pre-commit hook.
nix_attr_line() {
  local alias="$1" rhs="$2" line
  line="  ${alias} = ${rhs};"
  if ((${#line} > 100)); then
    printf '  %s =\n    %s;\n' "$alias" "$rhs"
  else
    printf '%s\n' "$line"
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
    nix_attr_line "$alias" "inputs.${name}.packages.\${system}.${pkg}"
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
    nix_attr_line "$alias" "inputs.${name}.${attr}.${mod}"
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

# ── Circular nixpkgs tracking ───────────────────────────────────────────
# An input whose own `nixpkgs` is github:gignsky/gigpkgs/<ref> makes gigpkgs
# depend on (an older copy of) itself. These helpers find such inputs and work
# out the follows that break the loop: the input should follow the nixpkgs
# channel that <ref> is derived from, not gigpkgs.

# Map a gigpkgs ref to the top-level gigpkgs input it is derived from
# (see .github/workflows/channels.yml). Trunk refs map to `nixpkgs`, which
# channel derivation already re-points on every derived branch.
gigpkgs_channel_input() {
  local ref="$1"
  case "$ref" in
  gigpkgs-unstable) printf 'nixpkgs-unstable' ;;
  gigos-unstable) printf 'nixos-unstable' ;;
  gigos-[0-9]*) printf 'nixos-%s' "${ref#gigos-}" ;;
  "" | master | main | rolling) printf 'nixpkgs' ;;
  *)
    warn "Unknown gigpkgs ref '${ref}'; assuming it is trunk-derived (nixpkgs)." >&2
    printf 'nixpkgs'
    ;;
  esac
}

# Is <name> a top-level input of this repo's flake.lock? True when there is no
# flake.lock to check against (fixtures, fresh repos).
gigpkgs_has_input() {
  local name="$1"
  [[ -f flake.lock ]] || return 0
  jq -e --arg n "$name" '.nodes.root.inputs | has($n)' flake.lock >/dev/null 2>&1
}

# Scan one node of a lock file for inputs that track gigpkgs.
#   $1 lock file   $2 node key to inspect   $3 root input name that follows
#   paths are prefixed with (empty when $2 is the lock's own root)
# Prints `key=target` lines in `inputman -f` syntax, one per override needed:
#   - an input locked to gigpkgs        -> the channel input for its ref
#   - an input following <tracker>/<x>  -> gigpkgs' own top-level <x>
detect_circular_follows() {
  local lock="$1" node="$2" prefix="${3:-}"
  local kind key val target seg
  while IFS=$'\t' read -r kind key val; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
    track) target=$(gigpkgs_channel_input "$val") ;;
    via) target="$val" ;;
    *) continue ;;
    esac
    seg="${target%%/*}"
    if ! gigpkgs_has_input "$seg"; then
      warn "Input '${key}' needs a follows to '${target}', but gigpkgs has no top-level '${seg}' input; skipped." >&2
      continue
    fi
    printf '%s=%s\n' "$key" "$target"
  done < <(
    jq -r --arg node "$node" --arg prefix "$prefix" '
      .nodes as $n
      | ($n[$node].inputs // {}) as $ins
      | ($ins | to_entries
         | map(select((.value | type) == "string"
                      and ($n[.value].original.repo // "") == "gigpkgs"
                      and ($n[.value].original.owner // "") == "gignsky")
               | {key: .key, ref: ($n[.value].original.ref // "")})) as $trk
      | ($trk | map({(.key): .ref}) | add // {}) as $trkmap
      | ($trk[] | "track\t\(.key)\t\(.ref)"),
        ($ins | to_entries[] | select(.value | type == "array")
         | (if $prefix != "" and .value[0] == $prefix then .value[1:] else .value end) as $p
         | select(($p | length) >= 2 and ($trkmap | has($p[0])))
         | "via\t\(.key)\t\($p[1:] | join("/"))")
    ' "$lock"
  )
}

# Overrides needed for an input already locked in ./flake.lock.
detect_follows_installed() {
  local name="$1" node
  [[ -f flake.lock ]] || return 0
  node=$(jq -r --arg n "$name" '.nodes.root.inputs[$n] | if type == "string" then . else empty end' flake.lock)
  [[ -n "$node" ]] || return 0
  detect_circular_follows flake.lock "$node" "$name"
}

# Overrides needed for an input that is not in the repo yet (install, pin):
# its own lock, as nix reports it, is the source of truth.
detect_follows_for_url() {
  local url="$1" tmp
  tmp=$(mktemp)
  if ! nix flake metadata --json "$url" 2>/dev/null | jq '.locks' >"$tmp" 2>/dev/null; then
    warn "Could not read the lock of '${url}'; skipping circular-follows detection." >&2
    rm -f "$tmp"
    return 0
  fi
  [[ "$(jq -r 'type' "$tmp")" == "object" ]] && detect_circular_follows "$tmp" root ""
  rm -f "$tmp"
}

# Install-time helper: add the detected overrides for <url> to the explicit
# ones in the named array, unless the user already chose that key.
#   usage: add_detected_follows <url> <array-name>
add_detected_follows() {
  local url="$1"
  local -n arr="$2"
  local pair key existing taken
  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    key="${pair%%=*}"
    taken=""
    for existing in "${arr[@]}"; do
      [[ "$(normalize_follows_pair "$existing")" == "${key}="* ]] && taken=1
    done
    if [[ -n "$taken" ]]; then
      info "Keeping your --follows for '${key}' (detected: ${pair#*=})."
    else
      info "Circular gigpkgs tracking detected: following ${pair#*=} for '${key}'."
      arr+=("$pair")
    fi
  done < <(detect_follows_for_url "$url")
}

# After a relock: if <name> has started tracking gigpkgs (an upstream can
# change its nixpkgs ref at any time), declare the follows that break the
# loop and relock. Restores flake.nix/flake.lock if that fails.
ensure_no_circular_follows() {
  local name="$1"
  local -a pairs=()
  local pair
  while IFS= read -r pair; do
    [[ -n "$pair" ]] && pairs+=("$pair")
  done < <(detect_follows_installed "$name")
  [[ ${#pairs[@]} -eq 0 ]] && return 0

  info "'${name}' tracks gigpkgs; adding: ${pairs[*]}"
  local backup
  backup=$(mktemp -d)
  cp flake.nix flake.lock "$backup/"
  patch_flake_follows "$name" "${pairs[@]}"
  if ! nix flake lock; then
    cp "$backup/flake.nix" "$backup/flake.lock" .
    rm -rf "$backup"
    warn "Could not apply circular-follows fix for '${name}'; restored flake.nix/flake.lock. Add by hand: ${pairs[*]}"
    return 0
  fi
  rm -rf "$backup"
  git add flake.nix flake.lock 2>/dev/null || true
  ok "Broke circular tracking for '${name}'"
}

cmd_tidy() {
  local auto_commit="" no_commit=""
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
    *) die "Usage: inputman tidy [options]" ;;
    esac
  done
  [[ -f flake.nix ]] || die "No flake.nix found — run from the repo root"

  patch_flake_tidy
  if git diff --quiet -- flake.nix; then
    ok "flake.nix inputs already tidy."
    return 0
  fi
  git add flake.nix
  finalize_commit "inputMan: tidy flake.nix inputs" "$auto_commit" "$no_commit"
}

cmd_doctor() {
  local fix="" auto_commit="" no_commit=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --fix)
      fix=1
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
    *) die "Usage: inputman doctor [--fix] [options]" ;;
    esac
  done

  [[ -f flake.nix && -f flake.lock ]] || die "No flake.nix/flake.lock found — run from the repo root"

  local name pair found=0
  local -A findings=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    local -a pairs=()
    while IFS= read -r pair; do
      [[ -n "$pair" ]] && pairs+=("$pair")
    done < <(detect_follows_installed "$name")
    if [[ ${#pairs[@]} -gt 0 ]]; then
      findings["$name"]="${pairs[*]}"
      found=1
      warn "${name} tracks gigpkgs:"
      for pair in "${pairs[@]}"; do
        printf '    -f %s\n' "$pair" >&2
      done
    fi
  done < <(jq -r '.nodes.root.inputs | to_entries[] | select(.value | type == "string") | .key' flake.lock)

  if [[ "$found" -eq 0 ]]; then
    ok "No circular gigpkgs tracking."
    return 0
  fi
  [[ -n "$fix" ]] || die "Circular tracking found (re-run with --fix to apply the overrides)."

  local -a to_fix
  for name in "${!findings[@]}"; do
    read -ra to_fix <<<"${findings[$name]}"
    patch_flake_follows "$name" "${to_fix[@]}"
  done
  nix flake lock
  git add flake.nix flake.lock
  finalize_commit "inputMan: break circular gigpkgs tracking (${!findings[*]})" "$auto_commit" "$no_commit"
}

# ── flake.nix input editing ─────────────────────────────────────────────
# Every edit to an input in flake.nix goes through one perl program that
# reads that input's statements (dotted lines or a block, in any mix), applies
# the change, and writes the input back in the form statix and nixfmt accept:
#
#   name.url = "github:owner/repo";            # url only: one dotted line
#
#   name = {                                    # anything more: one block,
#     url = "github:owner/repo";                # never repeated `name.` keys
#     inputs = {
#       nixpkgs.follows = "nixpkgs-unstable";
#       pre-commit-hooks.follows = "pre-commit-hooks";
#     };
#   };
#
# Operations (INPUT_OP): add (set url + follows), follows (add missing
# follows, keep existing), seturl, remove, tidy (re-render every input that
# is split across several statements).
edit_flake_input() {
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

    # Split $text[$from,$to) into `path = value;` statements. Returns hashes
    # with path (segments), value (source text), start/end (byte span; start
    # is the line start when only indentation precedes the statement, end
    # includes the trailing newline).
    sub scan_statements {
      my ($text, $from, $to) = @_;
      my @out;
      my $i = $from;
      while (1) {
        pos($text) = $i;
        $text =~ /\G\s*/gc;
        $i = pos($text);
        if ($i < $to && substr($text, $i, 1) eq "#") {
          my $nl = index($text, "\n", $i);
          $i = $nl < 0 ? $to : $nl + 1;
          next;
        }
        last if $i >= $to;

        my $start = $i;
        my $ls = rindex($text, "\n", $i - 1) + 1;
        $start = $ls if substr($text, $ls, $i - $ls) =~ /^[ \t]*$/;

        pos($text) = $i;
        $text =~ /\G([A-Za-z_][A-Za-z0-9_'-]*(?:\.(?:[A-Za-z_][A-Za-z0-9_'-]*|"[^"]*"))*)\s*=\s*/gc
          or die "inputMan: cannot parse flake.nix inputs near: " . substr($text, $i, 40) . "\n";
        my @path = split /\./, $1;
        my $vstart = pos($text);

        my ($depth, $in_dq, $in_sq, $in_comment) = (0, 0, 0, 0);
        my $j = $vstart;
        while ($j < $to) {
          my $ch = substr($text, $j, 1);
          my $next2 = substr($text, $j, 2);
          if ($in_comment) { $in_comment = 0 if $ch eq "\n"; $j++; next; }
          if ($in_dq) {
            if ($ch eq "\\") { $j += 2; next; }
            $in_dq = 0 if $ch eq "\"";
            $j++;
            next;
          }
          if ($in_sq) {
            if ($next2 eq "''") { $in_sq = 0; $j += 2; next; }
            $j++;
            next;
          }
          if ($ch eq "#") { $in_comment = 1; $j++; next; }
          if ($next2 eq "''") { $in_sq = 1; $j += 2; next; }
          if ($ch eq "\"") { $in_dq = 1; $j++; next; }
          if ($ch eq "{" || $ch eq "[") { $depth++; $j++; next; }
          if ($ch eq "}" || $ch eq "]") { $depth--; $j++; next; }
          last if $ch eq ";" && $depth == 0;
          $j++;
        }
        die "inputMan: unterminated statement in flake.nix inputs\n" if $j >= $to;

        my $value = substr($text, $vstart, $j - $vstart);
        my $end = $j + 1;
        pos($text) = $end;
        $text =~ /\G[ \t]*\n?/gc;
        $end = pos($text);
        push @out, { path => \@path, value => $value, start => $start, end => $end };
        $i = $end;
      }
      return @out;
    }

    # Flatten a statement into [chain, rhs] leaves, descending into `{ ... }`.
    sub leaves_of {
      my ($path, $value) = @_;
      $value =~ s/^\s+|\s+$//g;
      if ($value =~ /^\{(.*)\}$/s) {
        my $inner = $1;
        warn "inputMan: comments inside input '$path->[0]' are not preserved\n" if $inner =~ /^\s*#/m;
        my @r;
        for my $s (scan_statements($inner, 0, length $inner)) {
          push @r, leaves_of([@$path, @{ $s->{path} }], $s->{value});
        }
        return @r;
      }
      return ([$path, $value]);
    }

    sub new_node { return { keys => [], kids => {}, val => undef }; }

    sub set_leaf {
      my ($root, $chain, $rhs, $keep) = @_;
      my $n = $root;
      for my $seg (@$chain) {
        unless (exists $n->{kids}{$seg}) {
          push @{ $n->{keys} }, $seg;
          $n->{kids}{$seg} = new_node();
        }
        $n = $n->{kids}{$seg};
      }
      return if $keep && defined $n->{val};
      $n->{val} = $rhs;
    }

    sub get_leaf {
      my ($root, $chain) = @_;
      my $n = $root;
      for my $seg (@$chain) {
        $n = $n->{kids}{$seg} or return undef;
      }
      return $n->{val};
    }

    sub render {
      my ($node, $indent) = @_;
      my @keys = @{ $node->{keys} };
      @keys = ((grep { $_ eq "url" } @keys), (grep { $_ ne "url" } @keys));
      my $out = "";
      for my $k (@keys) {
        my ($path, $n) = ($k, $node->{kids}{$k});
        while (!defined $n->{val} && @{ $n->{keys} } == 1) {
          my $c = $n->{keys}[0];
          $path .= ".$c";
          $n = $n->{kids}{$c};
        }
        if (defined $n->{val}) {
          $out .= "$indent$path = $n->{val};\n";
        } else {
          $out .= "$indent$path = {\n" . render($n, "$indent  ") . "$indent};\n";
        }
      }
      return $out;
    }

    # An input's statements -> a tree rooted below the input name.
    sub input_tree {
      my (@stmts) = @_;
      my $root = new_node();
      for my $s (@stmts) {
        my @p = @{ $s->{path} };
        shift @p;
        for my $leaf (leaves_of(\@p, $s->{value})) {
          set_leaf($root, $leaf->[0], $leaf->[1]);
        }
      }
      return $root;
    }

    sub render_input {
      my ($name, $tree, $indent) = @_;
      my $top = new_node();
      push @{ $top->{keys} }, $name;
      $top->{kids}{$name} = $tree;
      return render($top, $indent);
    }

    sub follows_chain {
      my ($key) = @_;
      return ((map { ("inputs", $_) } split /\./, $key), "follows");
    }

    my $op = $ENV{INPUT_OP};
    my $n = $ENV{INPUT_NAME} // "";
    my $u = $ENV{INPUT_URL} // "";
    my @pairs = grep { length } split /\n/, ($ENV{INPUT_FOLLOWS} // "");

    my ($open_pos, $close_pos) = find_inputs_block($_);
    my $inner_start = $open_pos + 1;
    my @stmts = scan_statements($_, $inner_start, $close_pos);

    # Indentation of the inputs entries: that of the first statement, else
    # two past the line holding `inputs = {`.
    my $line_start = rindex($_, "\n", $open_pos) + 1;
    my ($open_indent) = substr($_, $line_start) =~ /^([ \t]*)/;
    my $indent = @stmts ? (substr($_, $stmts[0]{start}) =~ /^([ \t]*)/)[0] : $open_indent . "  ";

    # Replace [start,end) spans (given back-to-front) and insert $new at $at.
    my $apply = sub {
      my ($spans, $at, $new) = @_;
      for my $s (sort { $b->{start} <=> $a->{start} } @$spans) {
        substr($_, $s->{start}, $s->{end} - $s->{start}, "");
        $at -= ($s->{end} - $s->{start}) if $s->{start} < $at;
      }
      substr($_, $at, 0, $new);
    };

    if ($op eq "tidy") {
      # Rescan after every rewrite: spans shift as inputs are re-rendered.
      while (1) {
        my ($o, $c) = find_inputs_block($_);
        my @all = scan_statements($_, $o + 1, $c);
        my (%by, @order);
        for my $s (@all) {
          my $k = $s->{path}[0];
          push @order, $k unless $by{$k};
          push @{ $by{$k} }, $s;
        }
        my ($target) = grep {
          my @g = @{ $by{$_} };
          @g > 1;
        } @order;
        last unless defined $target;
        my @g = @{ $by{$target} };
        my ($ind) = substr($_, $g[0]{start}) =~ /^([ \t]*)/;
        $apply->(\@g, $g[0]{start}, render_input($target, input_tree(@g), $ind));
      }
    } else {
      my @mine = grep { $_->{path}[0] eq $n } @stmts;

      if ($op eq "remove") {
        die "inputMan: input '$n' not found in flake.nix inputs block\n" unless @mine;
        # A comment block directly above the input belongs to it.
        my $first = $mine[0];
        while ($first->{start} > 0) {
          my $prev = rindex($_, "\n", $first->{start} - 2) + 1;
          last unless substr($_, $prev, $first->{start} - $prev) =~ /^[ \t]*#.*\n$/;
          $first->{start} = $prev;
        }
        $apply->(\@mine, $mine[0]{start}, "");
      } else {
        my $tree = input_tree(@mine);
        if ($op eq "add") {
          set_leaf($tree, ["url"], "\"$u\"");
          set_leaf($tree, [follows_chain((split /=/, $_, 2)[0])], "\"" . ((split /=/, $_, 2)[1] // "") . "\"") for @pairs;
        } elsif ($op eq "follows") {
          die "inputMan: could not find input '$n' in flake.nix\n" unless @mine;
          set_leaf($tree, [follows_chain((split /=/, $_, 2)[0])], "\"" . ((split /=/, $_, 2)[1] // "") . "\"", 1) for @pairs;
        } elsif ($op eq "seturl") {
          die "inputMan: could not find '$n.url' in flake.nix\n" unless defined get_leaf($tree, ["url"]);
          set_leaf($tree, ["url"], "\"$u\"");
        } else {
          die "inputMan: unknown edit '$op'\n";
        }
        my $new = render_input($n, $tree, @mine ? (substr($_, $mine[0]{start}) =~ /^([ \t]*)/)[0] : $indent);
        if (@mine) {
          $apply->(\@mine, $mine[0]{start}, $new);
        } else {
          # New input: just before the closing brace's own line.
          my $cls = rindex($_, "\n", $close_pos) + 1;
          my $at = substr($_, $cls, $close_pos - $cls) =~ /^[ \t]*$/ ? $cls : $close_pos;
          $new = "\n$new" if $at == $close_pos;
          $new = "\n$new" if @stmts && substr($_, 0, $at) !~ /\n\n$/ && $at != $close_pos;
          substr($_, $at, 0, $new);
        }
      }

      # Edits can leave two blank lines in a row; nixfmt allows one.
      my ($o2, $c2) = find_inputs_block($_);
      my $region = substr($_, $o2 + 1, $c2 - $o2 - 1);
      $region =~ s/\n{3,}/\n\n/g;
      substr($_, $o2 + 1, $c2 - $o2 - 1, $region);
    }
PERL
  )

  local err_file
  err_file=$(mktemp)
  if ! perl -i -0pe "$perl_script" flake.nix 2>"$err_file"; then
    local err
    err=$(cat "$err_file")
    rm -f "$err_file"
    die "Failed to patch flake.nix: ${err:-unknown patch error}"
  fi
  # Non-fatal perl warnings (e.g. dropped comments) still deserve a line.
  [[ -s "$err_file" ]] && warn "$(cat "$err_file")"
  rm -f "$err_file"
}

# Run `edit_flake_input` with its inputs in the environment.
#   usage: flake_input_op <op> <name> <url> [key=target...]
flake_input_op() {
  local op="$1" name="$2" url="$3"
  shift 3
  local follows_newline="" pair
  for pair in "$@"; do
    follows_newline+="$(normalize_follows_pair "$pair")"$'\n'
  done
  INPUT_OP="$op" INPUT_NAME="$name" INPUT_URL="$url" INPUT_FOLLOWS="$follows_newline" edit_flake_input
}

# Add an input (url + optional follows) to flake.nix.
patch_flake_add() {
  local name="$1" url="$2"
  shift 2
  flake_input_op add "$name" "$url" "$@"
}

# Add follows lines to an input already in flake.nix; keys already declared
# are left alone.
#   usage: patch_flake_follows <name> key=target...
patch_flake_follows() {
  local name="$1"
  shift
  flake_input_op follows "$name" "" "$@"
}

# Remove an input and everything declared under its name.
patch_flake_remove() {
  flake_input_op remove "$1" ""
}

# Point an existing input at a new URL (used by `inputman branch`), keeping
# its follows.
patch_flake_set_url() {
  flake_input_op seturl "$1" "$2"
}

# Rewrite inputs split across several statements (`a.url = ...; a.inputs.x...`)
# into the single-block form.
patch_flake_tidy() {
  flake_input_op tidy "" ""
}

# Read the set of pkg=alias pairs currently exposed by pkgs/inputs/<name>.nix.
# Print an aggregator with nixfmt-wrapped `alias =\n    rhs;` entries joined
# back onto one line, so the line-oriented parsers below see every entry whole.
unwrap_nix_file() {
  perl -0pe 's/=\n[ \t]+/= /g' "$1"
}

current_package_pairs() {
  local name="$1"
  local file="pkgs/inputs/${name}.nix"
  [[ -f "$file" ]] || return 0
  local pattern='^\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*inputs\.'"$name"'\.packages\.\$\{system\}\.([A-Za-z0-9_-]+);'
  while IFS= read -r line; do
    if [[ "$line" =~ $pattern ]]; then
      printf '%s=%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
    fi
  done < <(unwrap_nix_file "$file")
}

# Detect a hand-customized managed input file: one that exists but exposes no
# standard `inputs.<name>.packages.${system}.<pkg>` passthrough entries (e.g. it
# rebuilds packages from source, like claude-desktop's asar shim). inputMan can't
# recover the pkg=alias mapping from such a file, so `update` must not treat it as
# "zero packages exposed" and re-append the naive (possibly broken) form.
input_file_is_custom() {
  local name="$1"
  local file="pkgs/inputs/${name}.nix"
  [[ -f "$file" ]] || return 1
  local pattern='^\s*[A-Za-z][A-Za-z0-9_-]*\s*=\s*inputs\.'"$name"'\.packages\.\$\{system\}\.'
  unwrap_nix_file "$file" | grep -qE "$pattern" && return 1
  return 0
}

# ── Version / revision tracking ─────────────────────────────────────────
# News entries record *what changed*, not just *that something changed*, so
# install/update/remove capture the locked revision and the evaluated package
# versions on either side of the operation.

# Read a field ("rev", "lastModified", "ref", ...) from an input's `locked`
# node in flake.lock. Prints nothing when the node or field is absent.
locked_input_field() {
  local name="$1" field="$2"
  [[ -f flake.lock ]] || return 0
  jq -r --arg n "$name" --arg f "$field" \
    '(.nodes[$n].locked[$f] // empty) | tostring' flake.lock 2>/dev/null || true
}

# Read a field ("owner", "repo", "type", "ref", ...) from an input's `original`
# node in flake.lock — i.e. what was requested, not what got resolved. Used to
# rebuild a flake ref for pinning without inheriting any ref already baked in.
original_input_field() {
  local name="$1" field="$2"
  [[ -f flake.lock ]] || return 0
  jq -r --arg n "$name" --arg f "$field" \
    '(.nodes[$n].original[$f] // empty) | tostring' flake.lock 2>/dev/null || true
}

# Human-sized form of a lock revision (git sha -> 7 chars, others verbatim).
short_rev() {
  local rev="$1"
  [[ -z "$rev" ]] && return 0
  if [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s' "${rev:0:7}"
  else
    printf '%s' "$rev"
  fi
}

# Render a lastModified epoch as a UTC date. Empty if it can't be formatted
# (BSD date on Darwin uses -r, everything else is GNU -d).
lock_date() {
  local epoch="$1"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 0
  date -u -d "@${epoch}" +%Y-%m-%d 2>/dev/null ||
    date -u -r "$epoch" +%Y-%m-%d 2>/dev/null ||
    true
}

# ── Local version ledger ────────────────────────────────────────────────
# flake.lock only ever holds the CURRENT revision of an input, and upstream
# git tags only exist for actual tagged releases — an input tracked against a
# rolling branch (e.g. 'develop') can report a version string like "0.2.5"
# that was never tagged anywhere. So every install/update/branch/pin records
# what revision each version string was observed at in a small JSON ledger,
# letting `pin` later resolve "0.2.5" back to its rev even without a tag.
versions_ledger_file() {
  printf 'pkgs/inputs/.versions.json'
}

# Record a {rev, date, versions} observation for <name>, merging it into the
# shared ledger (one entry per rev per input; a later write for the same rev
# replaces the earlier one rather than duplicating it). `versions` is an
# "alias=version" line list, the same shape `input_package_versions` emits.
# A no-op when there's no rev or no version info to record.
record_input_version() {
  local name="$1" rev="$2" date="$3" versions="$4"
  [[ -n "$rev" && -n "$versions" ]] || return 0

  local versions_json="{}"
  local line alias ver
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    alias="${line%%=*}"
    ver="${line#*=}"
    versions_json=$(jq -c --arg k "$alias" --arg v "$ver" '. + {($k): $v}' <<<"$versions_json")
  done <<<"$versions"
  [[ "$versions_json" == "{}" ]] && return 0

  local file
  file=$(versions_ledger_file)
  [[ -f "$file" ]] || printf '{}' >"$file"

  local tmp
  tmp=$(mktemp)
  jq --arg n "$name" --arg rev "$rev" --arg date "$date" --argjson versions "$versions_json" '
    .[$n] = (((.[$n] // []) | map(select(.rev != $rev))) + [{rev: $rev, date: $date, versions: $versions}])
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Resolve a version string previously observed for <name> (on any exposed
# alias) back to the rev it was locked at, via the local ledger. Prints
# nothing if there's no ledger or no match — callers then fall back to
# treating the argument as a literal upstream git ref (tag/branch/rev).
# When a version was observed at more than one rev, the most recent wins.
lookup_version_rev() {
  local name="$1" version="$2"
  local file
  file=$(versions_ledger_file)
  [[ -f "$file" ]] || return 0
  jq -r --arg n "$name" --arg v "$version" '
    (.[$n] // [])
    | map(select([.versions[]] | index($v) != null))
    | sort_by(.date)
    | last
    | .rev // empty
  ' "$file" 2>/dev/null || true
}

# Package aliases this repo exposes for <name>, one per line.
exposed_package_aliases() {
  local name="$1"
  local file="pkgs/inputs/${name}.nix"
  [[ -f "$file" ]] || return 0

  local pair found=0
  while IFS= read -r pair; do
    [[ -z "$pair" ]] && continue
    found=1
    printf '%s\n' "${pair#*=}"
  done < <(current_package_pairs "$name")
  ((found)) && return 0

  # Hand-customized aggregator (see input_file_is_custom): the pkg=alias mapping
  # isn't recoverable, so fall back to every top-level binding and `inherit`
  # name in the file. Candidates that aren't real packages evaluate to "" in
  # input_package_versions and are dropped there.
  perl -ne '
    print "$1\n" if /^\s{1,4}([A-Za-z][A-Za-z0-9_-]*)\s*=[^=]/;
    if (/^\s*inherit\s+([A-Za-z0-9_\s-]+);/) {
      for my $n (split /\s+/, $1) { print "$n\n" if length $n }
    }
  ' "$file" | sort -u
}

# Evaluate `version` for every alias exposed by <name>, in a single nix eval.
# Emits "alias=version" lines; aliases with no version attr (or that fail to
# evaluate) are skipped, so inputs that don't version their packages simply
# contribute nothing.
input_package_versions() {
  local name="$1" system="$2"

  local -a aliases=()
  local alias
  while IFS= read -r alias; do
    [[ -n "$alias" ]] && aliases+=("$alias")
  done < <(exposed_package_aliases "$name")
  [[ ${#aliases[@]} -eq 0 ]] && return 0

  local nix_list=""
  for alias in "${aliases[@]}"; do
    nix_list+=" \"${alias}\""
  done

  local json
  if ! json=$(nix eval --json ".#packages.${system}" --apply "
    ps:
      builtins.listToAttrs (map (n: {
        name = n;
        value =
          let r = builtins.tryEval (ps.\${n}.version or \"\");
          in if r.success && builtins.isString r.value then r.value else \"\";
      }) [${nix_list} ])
  " 2>/dev/null); then
    warn "Could not evaluate package versions for '${name}'; news entry will report revisions only."
    return 0
  fi

  printf '%s' "$json" |
    jq -r 'to_entries[] | select(.value != "") | "\(.key)=\(.value)"' 2>/dev/null || true
}

# Diff two "alias=version" lists. Emits pipe-separated "alias|old|new" records
# for every alias whose version changed or that is newly exposed (old is empty
# in that case). Unchanged aliases are omitted. '|' rather than a tab because
# `read` collapses runs of whitespace delimiters, which would hide the empty
# `old` field of a newly exposed package.
version_changes() {
  local before="$1" after="$2"
  local -A old=()
  local line alias ver

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    old["${line%%=*}"]="${line#*=}"
  done <<<"$before"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    alias="${line%%=*}"
    ver="${line#*=}"
    if [[ -z "${old[$alias]:-}" ]]; then
      printf '%s||%s\n' "$alias" "$ver"
    elif [[ "${old[$alias]}" != "$ver" ]]; then
      printf '%s|%s|%s\n' "$alias" "${old[$alias]}" "$ver"
    fi
  done <<<"$after"
}

# Render a version_changes record as a human-readable line.
format_version_change() {
  local alias="$1" old="$2" new="$3"
  if [[ -z "$old" ]]; then
    printf '%s %s (new)' "$alias" "$new"
  else
    printf '%s %s -> %s' "$alias" "$old" "$new"
  fi
}

# Extract the version string for the primary alias (the one matching <name>
# itself, e.g. "roll-flow") from an "alias=version" line list. Prints nothing
# if that alias isn't present or doesn't declare a version.
primary_version_from() {
  local name="$1" versions="$2"
  local line
  while IFS= read -r line; do
    [[ "${line%%=*}" == "$name" ]] && { printf '%s' "${line#*=}"; return 0; }
  done <<<"$versions"
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
  done < <(unwrap_nix_file "$file")
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
  # headline_suffix lands in the first line of the message, which gignews uses
  # as the entry title — that's where a version bump is most useful.
  local action="$1" name="$2" details="$3" headline_suffix="${4:-}" ref_label="${5:-}"
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
    headline="Added flake input '${name}'${headline_suffix}"
    body="This input was installed by inputMan and is now available via gigpkgs."
    ;;
  update)
    headline="Updated flake input '${name}'${headline_suffix}"
    body="The flake.lock entry for this input was refreshed by inputMan."
    ;;
  remove)
    headline="Removed flake input '${name}'${headline_suffix}"
    body="This input was removed from gigpkgs by inputMan."
    ;;
  pin)
    headline="Pinned '${name}' version ${ref_label}${headline_suffix}"
    body="A permanent package was materialized for this version by inputMan, backed by its own frozen flake input. The bare '${name}' package is unaffected and keeps tracking whatever 'update'/'branch' currently has it at."
    ;;
  branch)
    headline="Switched flake input '${name}' to branch '${ref_label}'${headline_suffix}"
    body="This input's tracked ref was changed to '${ref_label}' by inputMan; 'inputman update ${name}' will now follow that branch."
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
      nix_attr_line "$alias2" "inputs.${name}.${attr}.${mod2}"
    done
    printf '}\n'
  } >"$file"

  ok "Wrote ${file}" >&2
  printf '%s' "$file"
}

cmd_install() {
  local url="" name="" packages_arg="" packages_flag="" auto_commit="" no_commit=""
  local no_info="" no_branch="" no_modules=""
  local no_auto_follows=""
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
    --no-auto-follows)
      no_auto_follows=1
      shift
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
  printf '%s\n' "$content" >>"$input_file"
  ok "Wrote ${input_file}"

  if [[ -z "$no_auto_follows" ]]; then
    add_detected_follows "$url" follows_pairs
  fi

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

  # Record the revision/versions this input entered the repo at, so a later
  # `inputman update` has a baseline to diff against in its news entry.
  local locked_rev locked_modified locked_date
  locked_rev=$(locked_input_field "$name" rev)
  locked_modified=$(locked_input_field "$name" lastModified)
  locked_date=$(lock_date "$locked_modified")
  [[ -n "$locked_rev" ]] &&
    news_details+=$'\n'"Revision: $(short_rev "$locked_rev")${locked_date:+ (${locked_date})}"

  local installed_versions
  installed_versions=$(input_package_versions "$name" "$system")

  local -a version_lines=()
  local headline_suffix="" pair_version
  while IFS= read -r pair_version; do
    [[ -z "$pair_version" ]] && continue
    version_lines+=("${pair_version%%=*} ${pair_version#*=}")
  done <<<"$installed_versions"
  if [[ ${#version_lines[@]} -gt 0 ]]; then
    news_details+=$'\n'"Versions:"
    local version_line
    for version_line in "${version_lines[@]}"; do
      news_details+=$'\n'"  ${version_line}"
    done
    [[ ${#version_lines[@]} -eq 1 ]] && headline_suffix=" (${version_lines[0]#* })"
  fi

  record_input_version "$name" "$locked_rev" "$locked_date" "$installed_versions"

  [[ -n "$home_mod_file" ]] && news_details+=$'\n'"Home modules aggregator: ${home_mod_file}"
  [[ -n "$nixos_mod_file" ]] && news_details+=$'\n'"NixOS modules aggregator: ${nixos_mod_file}"
  local news_file
  news_file=$(write_news_entry install "$name" "$news_details" "$headline_suffix") || news_file=""
  INPUTMAN_CLEANUP_NEWS_FILE="$news_file"

  git add "$input_file" flake.nix flake.lock
  [[ -n "$home_mod_file" ]] && git add "$home_mod_file"
  [[ -n "$nixos_mod_file" ]] && git add "$nixos_mod_file"
  [[ -n "$news_file" ]] && git add "$news_file"
  [[ -f "$(versions_ledger_file)" ]] && git add "$(versions_ledger_file)"

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
    lines+=("$(nix_attr_line "$alias" "inputs.${name}.packages.\${system}.${pkg}")")
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
    lines+=("$(nix_attr_line "$alias" "inputs.${name}.${attr}.${mod}")")
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

  local system
  system=$(nix eval --impure --expr "builtins.currentSystem" --raw 2>/dev/null || echo "x86_64-linux")

  # Snapshot the "before" side of the update so the news entry can report a
  # revision/version diff rather than just "this input was refreshed".
  local before_rev before_modified before_versions
  before_rev=$(locked_input_field "$name" rev)
  before_modified=$(locked_input_field "$name" lastModified)
  info "Recording current versions of '${name}' ..."
  before_versions=$(input_package_versions "$name" "$system")

  info "Updating input '${name}' ..."
  nix flake update "$name"
  ok "flake.lock updated for '${name}'"
  ensure_no_circular_follows "$name"

  local after_rev after_modified
  after_rev=$(locked_input_field "$name" rev)
  after_modified=$(locked_input_field "$name" lastModified)
  if [[ -n "$before_rev" && "$before_rev" == "$after_rev" ]]; then
    info "Revision unchanged: $(short_rev "$after_rev")"
  else
    ok "Revision: ${before_rev:+$(short_rev "$before_rev") -> }$(short_rev "${after_rev:-unknown}")"
  fi

  local before_date after_date
  before_date=$(lock_date "$before_modified")
  after_date=$(lock_date "$after_modified")
  # Record the "before" side in the local ledger now — it may be the first
  # time this exact rev/version pair has ever been observed, so `pin` can
  # resolve back to it later even if it's never been tagged upstream. The
  # "after" side is recorded once its versions are (re-)evaluated below.
  record_input_version "$name" "$before_rev" "$before_date" "$before_versions"

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
    if input_file_is_custom "$name"; then
      warn "pkgs/inputs/${name}.nix is hand-customized (no standard passthrough entries); skipping package rescan. Review it manually if the input's package set changed."
      new_pkg_list=()
    fi
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

  # Re-evaluate versions now that any newly exposed packages are wired up, so
  # they show in the diff too.
  local after_versions
  after_versions=$(input_package_versions "$name" "$system")
  record_input_version "$name" "$after_rev" "$after_date" "$after_versions"

  # When the bare <name> package's own version actually changed, materialize
  # permanent version-named packages for BOTH sides of the move — the one
  # being left behind (so it stays available after the bare package moves
  # on) and the new one (so it's immediately citable by exact version too).
  local -a archived_aliases=()
  local before_primary after_primary archived_alias
  before_primary=$(primary_version_from "$name" "$before_versions")
  after_primary=$(primary_version_from "$name" "$after_versions")
  if [[ -n "$before_primary" && -n "$after_primary" && "$before_primary" != "$after_primary" ]]; then
    archived_alias=$(materialize_version_package "$name" "$before_primary" "$before_rev")
    [[ -n "$archived_alias" ]] && archived_aliases+=("$archived_alias")
    archived_alias=$(materialize_version_package "$name" "$after_primary" "$after_rev")
    [[ -n "$archived_alias" ]] && archived_aliases+=("$archived_alias")
  fi

  local -a version_lines=()
  local change alias old_v new_v first_change=""
  while IFS='|' read -r alias old_v new_v; do
    [[ -z "$alias" ]] && continue
    change=$(format_version_change "$alias" "$old_v" "$new_v")
    version_lines+=("$change")
    [[ -z "$first_change" ]] && first_change="${old_v:+${old_v} -> }${new_v}"
    ok "Version: ${change}"
  done < <(version_changes "$before_versions" "$after_versions")

  local news_details="" headline_suffix=""
  if [[ -n "$before_rev" && "$before_rev" == "$after_rev" ]]; then
    news_details+="No upstream changes — still locked at $(short_rev "$after_rev")."$'\n'
  else
    [[ -n "$after_rev" ]] &&
      news_details+="Revision: ${before_rev:+$(short_rev "$before_rev") -> }$(short_rev "$after_rev")"$'\n'
    [[ -n "$after_date" ]] &&
      news_details+="Upstream date: ${before_date:+${before_date} -> }${after_date}"$'\n'
  fi
  if [[ ${#version_lines[@]} -gt 0 ]]; then
    news_details+="Versions:"$'\n'
    for change in "${version_lines[@]}"; do
      news_details+="  ${change}"$'\n'
    done
    # A single changed package is the common case (one input, one program), so
    # put it right in the headline where gignews shows it as the entry title.
    [[ ${#version_lines[@]} -eq 1 ]] && headline_suffix=" (${first_change})"
  fi
  [[ ${#added_pkgs[@]} -gt 0 ]] && news_details+="New packages: ${added_pkgs[*]}"$'\n'
  [[ ${#added_home[@]} -gt 0 ]] && news_details+="New home modules: ${added_home[*]}"$'\n'
  [[ ${#added_nixos[@]} -gt 0 ]] && news_details+="New nixos modules: ${added_nixos[*]}"$'\n'
  [[ ${#archived_aliases[@]} -gt 0 ]] && news_details+="Archived as: ${archived_aliases[*]}"$'\n'
  local news_file
  news_file=$(write_news_entry update "$name" "$news_details" "$headline_suffix") || news_file=""

  git add flake.lock "pkgs/inputs/${name}.nix" 2>/dev/null || true
  [[ -n "$home_mod_file" ]] && git add "$home_mod_file"
  [[ -n "$nixos_mod_file" ]] && git add "$nixos_mod_file"
  [[ -n "$news_file" ]] && git add "$news_file"
  [[ -f "$(versions_ledger_file)" ]] && git add "$(versions_ledger_file)"
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

  # Capture the lock state before it's torn out, so the news entry records what
  # was actually dropped.
  local locked_rev locked_date
  locked_rev=$(locked_input_field "$name" rev)
  locked_date=$(lock_date "$(locked_input_field "$name" lastModified)")

  info "Removing input '${name}' ..."
  rm -f "$input_file"
  [[ -f "$home_mod_file" ]] && rm -f "$home_mod_file"
  [[ -f "$nixos_mod_file" ]] && rm -f "$nixos_mod_file"
  patch_flake_remove "$name"
  nix flake lock
  ok "Removed input '${name}' and updated flake.lock"

  local news_details=""
  [[ -n "$locked_rev" ]] &&
    news_details="Was locked at $(short_rev "$locked_rev")${locked_date:+ (${locked_date})}."
  local news_file
  news_file=$(write_news_entry remove "$name" "$news_details") || news_file=""

  git add "$input_file" flake.nix flake.lock
  [[ -f "$home_mod_file" ]] || git add "$home_mod_file" 2>/dev/null || true
  [[ -f "$nixos_mod_file" ]] || git add "$nixos_mod_file" 2>/dev/null || true
  git rm --ignore-unmatch "$home_mod_file" "$nixos_mod_file" >/dev/null 2>&1 || true
  [[ -n "$news_file" ]] && git add "$news_file"
  finalize_commit "inputMan: remove input ${name}" "$auto_commit" "$no_commit"
}

# Resolve a github-type input's owner/repo from flake.lock's `original` node
# (i.e. the un-resolved request, not whatever `locked` currently points at).
# Dies if the input isn't locked yet or isn't a github-type input — pin/versions
# only know how to build a `github:owner/repo/<ref>` flake ref.
github_owner_repo() {
  local name="$1" purpose="$2"
  local otype owner repo
  otype=$(original_input_field "$name" type)
  [[ -n "$otype" ]] || die "Input '${name}' is not locked in flake.lock (run 'inputman update ${name}' first)"
  [[ "$otype" == "github" ]] || die "inputman ${purpose} only supports github-type inputs (found '${otype}' for '${name}')"
  owner=$(original_input_field "$name" owner)
  repo=$(original_input_field "$name" repo)
  [[ -n "$owner" && -n "$repo" ]] || die "Could not determine owner/repo for '${name}' from flake.lock"
  # Trailing newline matters: callers consume this via `read -r o r < <(...)`,
  # and `read` returns non-zero at EOF without one, which `set -e` would treat
  # as a hard failure even though both variables were assigned correctly.
  printf '%s %s\n' "$owner" "$repo"
}

# Nix-identifier-safe form of a version string, for use as a flake input name
# (input identifiers can't contain dots; the exposed PACKAGE alias keeps the
# dots, since a quoted Nix attribute name like "roll-flow-0.2.5" is fine).
version_ident() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
}

# Ensure a permanent, version-named package exists for <name> at <version> —
# e.g. "roll-flow-0.2.5" — backed by its own flake input frozen to <ref>
# (a tag, branch, or exact rev; nix resolves it once and locks it in place).
# This is how versions stay available by name even after the bare <name>
# package moves on to track something newer: the bare package always reads
# from the shared <name> input, untouched here, while each version gets its
# own independent input that nothing else will ever move.
#
# Idempotent — a no-op if that input already exists. Prints the alias it
# created on success, or nothing if there was nothing new to do.
# Whether a permanent "<name>-<version>" package has already been
# materialized (i.e. exposed in pkgs/inputs/<name>.nix).
is_version_materialized() {
  local name="$1" version="$2"
  [[ -f "pkgs/inputs/${name}.nix" ]] || return 1
  unwrap_nix_file "pkgs/inputs/${name}.nix" | grep -qF "\"${name}-${version}\" = inputs."
}

materialize_version_package() {
  local name="$1" version="$2" ref="$3"
  [[ -n "$version" && -n "$ref" ]] || return 0

  local alias="${name}-${version}"
  local ident_suffix
  ident_suffix=$(version_ident "$version")
  local ident="${name}-${ident_suffix}"
  local file="pkgs/inputs/${name}.nix"

  local have_input=0 have_alias=0
  grep -qP "^\s+${ident}[. =]" flake.nix 2>/dev/null && have_input=1
  is_version_materialized "$name" "$version" && have_alias=1

  [[ "$have_input" -eq 1 && "$have_alias" -eq 1 ]] && return 0

  if [[ "$have_input" -eq 0 ]]; then
    local owner repo
    read -r owner repo < <(github_owner_repo "$name" "pin")
    info "Materializing '${alias}' (flake input '${ident}') at ${ref} ..." >&2
    local pin_url="github:${owner}/${repo}/${ref}"
    local -a pin_follows=()
    add_detected_follows "$pin_url" pin_follows >&2
    patch_flake_add "$ident" "$pin_url" "${pin_follows[@]}"
    if ! nix flake lock >&2; then
      git checkout -- flake.nix >/dev/null 2>&1 || true
      warn "Failed to lock '${ident}' for '${alias}'; skipped (rolled back flake.nix)." >&2
      return 0
    fi
  fi

  if [[ "$have_alias" -eq 0 && -f "$file" ]]; then
    append_lines_before_close "$file" "$(nix_attr_line "\"${alias}\"" "inputs.${ident}.packages.\${system}.default")"
  fi

  git add flake.nix flake.lock "$file" 2>/dev/null || true
  ok "Materialized '${alias}'" >&2
  printf '%s' "$alias"
}

cmd_pin() {
  local name="" ref="" auto_commit="" no_commit=""

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
      if [[ -z "$name" ]]; then
        name="$1"
      elif [[ -z "$ref" ]]; then
        ref="$1"
      else
        die "Usage: inputman pin <name> <ref> [options]"
      fi
      shift
      ;;
    esac
  done

  [[ -z "$name" || -z "$ref" ]] && die "Usage: inputman pin <name> <ref> [options]"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the repo root"
  [[ -f flake.lock ]] || die "No flake.lock found — run 'inputman update ${name}' first"

  # A version string (e.g. "0.2.5") may never have been an upstream git tag —
  # on a rolling branch like 'develop' it's just whatever the derivation
  # happened to report at some commit. Check the local ledger first (built up
  # by install/update/branch) for a rev that reported it; fall back to
  # treating the argument as a literal upstream ref (tag/branch/rev) when
  # there's no match.
  local resolved_rev target_ref
  resolved_rev=$(lookup_version_rev "$name" "$ref")
  if [[ -n "$resolved_rev" ]]; then
    info "'${ref}' matches a recorded version of '${name}' at $(short_rev "$resolved_rev")."
    target_ref="$resolved_rev"
  else
    target_ref="$ref"
  fi

  local alias
  alias=$(materialize_version_package "$name" "$ref" "$target_ref")
  if [[ -z "$alias" ]]; then
    ok "'${name}-${ref}' is already materialized; nothing to do."
    return 0
  fi

  local news_details
  news_details="A permanent package '${alias}' was materialized for '${name}' at version ${ref} (${target_ref}), independent of the bare '${name}' package — which keeps tracking whatever 'update'/'branch' currently has it at."
  local news_file
  news_file=$(write_news_entry pin "$name" "$news_details" " (${alias})" "$ref") || news_file=""
  [[ -n "$news_file" ]] && git add "$news_file"

  finalize_commit "inputMan: pin ${name} ${ref} as ${alias}" "$auto_commit" "$no_commit"
}

cmd_versions() {
  local name="" limit=25

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --limit)
      limit="$2"
      shift 2
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

  [[ -z "$name" ]] && die "Usage: inputman versions <name> [--limit N]"
  [[ -f flake.lock ]] || die "No flake.lock found — run 'inputman update ${name}' first"

  local owner repo
  read -r owner repo < <(github_owner_repo "$name" "versions")

  local current_rev
  current_rev=$(locked_input_field "$name" rev)

  info "Fetching tags for github:${owner}/${repo} ..."

  local -A tag_rev=()
  local raw_rev raw_ref tag
  while IFS=$'\t' read -r raw_rev raw_ref; do
    [[ "$raw_ref" == refs/tags/* ]] || continue
    tag="${raw_ref#refs/tags/}"
    if [[ "$tag" == *^\{\} ]]; then
      tag="${tag%^\{\}}"
      tag_rev["$tag"]="$raw_rev" # peeled commit sha wins over the tag object sha
    elif [[ -z "${tag_rev[$tag]:-}" ]]; then
      tag_rev["$tag"]="$raw_rev"
    fi
  done < <(git ls-remote --tags "https://github.com/${owner}/${repo}.git" 2>/dev/null)

  if [[ ${#tag_rev[@]} -eq 0 ]]; then
    warn "No tags found for github:${owner}/${repo}"
  else
    local -a sorted_tags=()
    while IFS= read -r tag; do
      sorted_tags+=("$tag")
    done < <(printf '%s\n' "${!tag_rev[@]}" | sort -V)

    local total=${#sorted_tags[@]} start=0
    ((total > limit)) && start=$((total - limit))

    local i rev marker
    for ((i = start; i < total; i++)); do
      tag="${sorted_tags[$i]}"
      rev="${tag_rev[$tag]}"
      marker=""
      [[ -n "$current_rev" && "$rev" == "$current_rev" ]] && marker+="  <- currently locked"
      is_version_materialized "$name" "$tag" && marker+="  [materialized as ${name}-${tag}]"
      printf '  %-20s %s%s\n' "$tag" "$(short_rev "$rev")" "$marker"
    done
  fi

  # Versions this repo's own update/branch history has observed for this
  # input — this is what covers a rolling branch (e.g. 'develop'), where the
  # version string a derivation reports usually isn't backed by any upstream
  # git tag at all, so `pin` has to resolve it from here instead.
  local ledger
  ledger=$(versions_ledger_file)
  if [[ -f "$ledger" ]]; then
    local recorded
    recorded=$(jq -r --arg n "$name" '
      (.[$n] // [])
      | map(select(.versions[$n] != null))
      | sort_by(.date)
      | reverse
      | .[]
      | [.date, .versions[$n], .rev] | @tsv
    ' "$ledger" 2>/dev/null)
    if [[ -n "$recorded" ]]; then
      printf '\n'
      info "Recorded in gigpkgs' own history for '${name}' (may not be tagged upstream):"
      local date ver rev marker
      while IFS=$'\t' read -r date ver rev; do
        marker=""
        [[ -n "$current_rev" && "$rev" == "$current_rev" ]] && marker+="  <- currently locked"
        is_version_materialized "$name" "$ver" && marker+="  [materialized as ${name}-${ver}]"
        printf '  %-20s %-10s %s%s\n' "$ver" "$date" "$(short_rev "$rev")" "$marker"
      done <<<"$recorded"
    fi
  fi

  info "Pin with: inputman pin ${name} <tag-or-version>  (materializes a permanent ${name}-<version> package)"
}

cmd_branch() {
  local name="" branch="" auto_commit="" no_commit=""

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
      if [[ -z "$name" ]]; then
        name="$1"
      elif [[ -z "$branch" ]]; then
        branch="$1"
      else
        die "Usage: inputman branch <name> [branch] [options]"
      fi
      shift
      ;;
    esac
  done

  [[ -z "$name" ]] && die "Usage: inputman branch <name> [branch] [options]"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the repo root"
  [[ -f flake.lock ]] || die "No flake.lock found — run 'inputman update ${name}' first"

  local owner repo
  read -r owner repo < <(github_owner_repo "$name" "branch")

  if [[ -z "$branch" ]]; then
    command -v fzf >/dev/null 2>&1 ||
      die "fzf is required for interactive branch selection (or pass a branch name directly: inputman branch ${name} <branch>)"

    info "Fetching branches for github:${owner}/${repo} ..."
    local -a branches=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && branches+=("$line")
    done < <(git ls-remote --heads "https://github.com/${owner}/${repo}.git" 2>/dev/null |
      awk '{print $2}' | sed 's#^refs/heads/##' | sort)

    [[ ${#branches[@]} -eq 0 ]] && die "No branches found for github:${owner}/${repo}"

    branch=$(printf '%s\n' "${branches[@]}" |
      fzf --prompt="${name} branch> " --height=~40% --reverse) || true
    [[ -z "$branch" ]] && die "No branch selected."
  fi

  local new_url="github:${owner}/${repo}/${branch}"

  local system
  system=$(nix eval --impure --expr "builtins.currentSystem" --raw 2>/dev/null || echo "x86_64-linux")

  local before_rev before_modified before_versions
  before_rev=$(locked_input_field "$name" rev)
  before_modified=$(locked_input_field "$name" lastModified)
  info "Recording current versions of '${name}' ..."
  before_versions=$(input_package_versions "$name" "$system")

  info "Switching input '${name}' to branch '${branch}' (${new_url}) ..."
  patch_flake_set_url "$name" "$new_url"
  if ! nix flake update "$name"; then
    git checkout -- flake.nix >/dev/null 2>&1 || true
    die "Failed to relock '${name}' against branch '${branch}'; rolled back flake.nix."
  fi
  ok "flake.nix and flake.lock updated for '${name}'"
  ensure_no_circular_follows "$name"

  local after_rev after_modified
  after_rev=$(locked_input_field "$name" rev)
  after_modified=$(locked_input_field "$name" lastModified)
  ok "Revision: ${before_rev:+$(short_rev "$before_rev") -> }$(short_rev "${after_rev:-unknown}")"

  local before_date after_date
  before_date=$(lock_date "$before_modified")
  after_date=$(lock_date "$after_modified")
  record_input_version "$name" "$before_rev" "$before_date" "$before_versions"

  local after_versions
  after_versions=$(input_package_versions "$name" "$system")
  record_input_version "$name" "$after_rev" "$after_date" "$after_versions"

  # When the bare <name> package's own version actually changed, materialize
  # permanent version-named packages for BOTH sides of the move — see the
  # matching comment in cmd_update for why.
  local -a archived_aliases=()
  local before_primary after_primary archived_alias
  before_primary=$(primary_version_from "$name" "$before_versions")
  after_primary=$(primary_version_from "$name" "$after_versions")
  if [[ -n "$before_primary" && -n "$after_primary" && "$before_primary" != "$after_primary" ]]; then
    archived_alias=$(materialize_version_package "$name" "$before_primary" "$before_rev")
    [[ -n "$archived_alias" ]] && archived_aliases+=("$archived_alias")
    archived_alias=$(materialize_version_package "$name" "$after_primary" "$after_rev")
    [[ -n "$archived_alias" ]] && archived_aliases+=("$archived_alias")
  fi

  local -a version_lines=()
  local change alias old_v new_v first_change=""
  while IFS='|' read -r alias old_v new_v; do
    [[ -z "$alias" ]] && continue
    change=$(format_version_change "$alias" "$old_v" "$new_v")
    version_lines+=("$change")
    [[ -z "$first_change" ]] && first_change="${old_v:+${old_v} -> }${new_v}"
    ok "Version: ${change}"
  done < <(version_changes "$before_versions" "$after_versions")

  local news_details="Branch: ${branch}"$'\n'
  [[ -n "$after_rev" ]] &&
    news_details+="Revision: ${before_rev:+$(short_rev "$before_rev") -> }$(short_rev "$after_rev")"$'\n'
  [[ -n "$after_date" ]] &&
    news_details+="Upstream date: ${before_date:+${before_date} -> }${after_date}"$'\n'

  local headline_suffix=""
  if [[ ${#version_lines[@]} -gt 0 ]]; then
    news_details+="Versions:"$'\n'
    for change in "${version_lines[@]}"; do
      news_details+="  ${change}"$'\n'
    done
    [[ ${#version_lines[@]} -eq 1 ]] && headline_suffix=" (${first_change})"
  fi
  [[ ${#archived_aliases[@]} -gt 0 ]] && news_details+="Archived as: ${archived_aliases[*]}"$'\n'

  local news_file
  news_file=$(write_news_entry branch "$name" "$news_details" "$headline_suffix" "$branch") || news_file=""

  git add flake.nix flake.lock
  [[ -n "$news_file" ]] && git add "$news_file"
  [[ -f "$(versions_ledger_file)" ]] && git add "$(versions_ledger_file)"
  finalize_commit "inputMan: switch input ${name} to branch ${branch}" "$auto_commit" "$no_commit"
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
pin)
  shift
  cmd_pin "$@"
  ;;
versions)
  shift
  cmd_versions "$@"
  ;;
branch)
  shift
  cmd_branch "$@"
  ;;
doctor)
  shift
  cmd_doctor "$@"
  ;;
tidy)
  shift
  cmd_tidy "$@"
  ;;
__generate-input-file)
  shift
  [[ $# -ge 2 ]] || die "Usage: inputman __generate-input-file <name> <pkg=alias>..."
  generate_input_file "$@"
  ;;
__patch-flake-tidy)
  patch_flake_tidy
  ;;
__detect-circular-follows)
  shift
  [[ $# -ge 2 ]] || die "Usage: inputman __detect-circular-follows <lock> <node> [prefix]"
  detect_circular_follows "$1" "$2" "${3:-}"
  ;;
__detect-follows-url)
  shift
  [[ $# -eq 1 ]] || die "Usage: inputman __detect-follows-url <flake-url>"
  detect_follows_for_url "$1"
  ;;
__gigpkgs-channel-input)
  shift
  [[ $# -eq 1 ]] || die "Usage: inputman __gigpkgs-channel-input <ref>"
  gigpkgs_channel_input "$1"
  echo
  ;;
__patch-flake-follows)
  shift
  [[ $# -ge 2 ]] || die "Usage: inputman __patch-flake-follows <name> <key=target>..."
  patch_flake_follows "$@"
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
__patch-flake-set-url)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman __patch-flake-set-url <name> <url>"
  patch_flake_set_url "$1" "$2"
  ;;
__parse-packages-spec)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman __parse-packages-spec <input-name> <spec>"
  parse_packages_spec "$1" "$2"
  ;;
__version-changes)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman __version-changes <before> <after>"
  while IFS='|' read -r alias old_v new_v; do
    [[ -z "$alias" ]] && continue
    format_version_change "$alias" "$old_v" "$new_v"
    echo
  done < <(version_changes "$1" "$2")
  ;;
__write-news-entry)
  shift
  [[ $# -ge 3 ]] || die "Usage: inputman __write-news-entry <action> <name> <details> [suffix]"
  write_news_entry "$1" "$2" "$3" "${4:-}" >/dev/null
  ;;
help | -h | --help) usage ;;
*) die "Unknown command: ${1}. Run 'inputman help' for usage." ;;
esac
