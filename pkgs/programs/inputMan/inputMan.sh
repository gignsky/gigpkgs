#!/usr/bin/env bash
set -euo pipefail

# Shared library (colours, patchers, discovery, news/commit plumbing, channel-map
# helpers). Path is substituted at build time; see default.nix.
# shellcheck source=inputman-lib.sh
source @INPUTMAN_LIB@

usage() {
  cat <<'EOF_USAGE'
Usage: inputman <command> [options]

Commands:
  install <url>          Add a flake input and expose its packages + modules
  update <name>          Refresh a locked input; prompt for new packages/modules
  remove <name>          Remove a flake input and its generated files
  group-install <prog>   Install a channel-aware multi-version input group
  freeze <prog>          Pin a channel to a frozen revision of a program
  help                   Show this help

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
  --no-branch            Skip creating add-input/<name> branch from origin/main
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

group-install options (channel-aware multi-version pins):
  --source <ch>=<input-name>=<url>   Sibling input for channel <ch>. Repeatable.
  --default <ch>                     Channel whose input backs the `default` map key.
  --follows, -f <spec>               Follows for every sibling (default nixpkgs=nixpkgs).
  --flake-false                      Add siblings as `flake = false` source pins (no follows).
  --no-branch / --yes,-y / --no-commit,-n

freeze options:
  --channel <ch>         Channel to repoint at the frozen input (required)
  --as <version>         Internal version label, e.g. v0.2.99 (required)
  --tag <tag>            Freeze an explicit committed tag instead of current main
  --rev <sha>            Freeze an explicit revision
  --from <input>         Moving input to snapshot (default <prog>-main)
  --yes,-y / --no-commit,-n

Examples:
  inputman install github:nix-community/nur
  inputman install github:gignsky/gigvim -f nixpkgs=nixpkgs --yes
  inputman update gigvim -y
  inputman remove gigvim --no-commit
  inputman group-install roll-flow \
    --source nixos-unstable=roll-flow-develop=github:gignsky/roll-flow/develop \
    --source nixos-stable=roll-flow-main=github:gignsky/roll-flow/main \
    --default nixos-stable
  inputman freeze roll-flow --channel nixos-2605 --as v0.2.99
  inputman freeze roll-flow --channel nixos-2605 --as v0.2.99 --tag v0.2.99
EOF_USAGE
}

# ── UI helpers (interactive prompts; inputMan-specific) ─────────────────────

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

# ── install rollback plumbing ───────────────────────────────────────────────

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

# Append lines describing new packages/modules to an existing aggregator file.
# Insert before the closing '}'.
append_lines_before_close() {
  local file="$1"
  shift
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

# ── Channel-aware multi-version pins ────────────────────────────────────────

cmd_group_install() {
  local program="" default_ch="" auto_commit="" no_commit="" no_branch="" flake_false=""
  local -a sources=() follows_pairs=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --source)
      [[ $# -ge 2 ]] || die "--source requires <channel>=<input-name>=<url>"
      sources+=("$2")
      shift 2
      ;;
    --default)
      default_ch="$2"
      shift 2
      ;;
    --flake-false)
      flake_false=1
      shift
      ;;
    --follows | -f)
      validate_follows_pair "$2"
      follows_pairs+=("$2")
      shift 2
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
      [[ -n "$program" ]] && die "Only one program name may be provided"
      program="$1"
      shift
      ;;
    esac
  done

  [[ -z "$program" ]] && die "Usage: inputman group-install <program> --source <ch>=<input-name>=<url> [...] [--default <ch>]"
  [[ ${#sources[@]} -eq 0 ]] && die "group-install requires at least one --source <channel>=<input-name>=<url>"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the repo root"
  [[ -f channel-sources.nix ]] || die "No channel-sources.nix found — run from the repo root"
  [[ "$program" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "Program name '${program}' is not a valid Nix identifier"

  [[ -z "$no_branch" ]] && create_feature_branch "${program}-group"
  [[ ${#follows_pairs[@]} -eq 0 ]] && follows_pairs=("nixpkgs=nixpkgs")

  ensure_channel_map_block "$program"

  local spec ch rest input_name url
  for spec in "${sources[@]}"; do
    ch="${spec%%=*}"
    rest="${spec#*=}"
    [[ "$rest" == *=* ]] || die "Invalid --source '${spec}' (expected <channel>=<input-name>=<url>)"
    input_name="${rest%%=*}"
    url="${rest#*=}"
    [[ "$input_name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "Input name '${input_name}' is not a valid Nix identifier"

    if grep -qP "^\s+${input_name}[. =]" flake.nix; then
      warn "Input '${input_name}' already in flake.nix; mapping channel only."
    elif [[ -n "$flake_false" ]]; then
      patch_flake_add_nonflake "$input_name" "$url"
      ok "Added input '${input_name}' (flake = false) -> ${url}"
    else
      patch_flake_add "$input_name" "$url" "${follows_pairs[@]}"
      ok "Added input '${input_name}' -> ${url}"
    fi
    patch_channel_map_set "$program" "$ch" "$input_name"
    ok "Mapped channel '${ch}' -> ${input_name}"
    if [[ -n "$default_ch" && "$ch" == "$default_ch" ]]; then
      patch_channel_map_set "$program" "default" "$input_name"
      ok "Set default -> ${input_name}"
    fi
  done

  local agg="pkgs/inputs/${program}.nix"
  if [[ ! -f "$agg" ]]; then
    generate_group_aggregator "$program" >"$agg"
    ok "Wrote ${agg}"
  fi

  info "Locking inputs (locker) ..."
  locker -n

  local news_file
  news_file=$(write_news_entry group-install "$program" "Sources: ${sources[*]}"$'\n'"Default channel: ${default_ch:-none}") || news_file=""

  git add flake.nix channel-sources.nix "$agg"
  git add flake.lock 2>/dev/null || true
  [[ -n "$news_file" ]] && git add "$news_file"
  finalize_commit "inputMan: group-install ${program}" "$auto_commit" "$no_commit"
}

cmd_freeze() {
  local program="" channel="" version="" tag="" rev="" from="" auto_commit="" no_commit=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --channel)
      channel="$2"
      shift 2
      ;;
    --as)
      version="$2"
      shift 2
      ;;
    --tag)
      tag="$2"
      shift 2
      ;;
    --rev)
      rev="$2"
      shift 2
      ;;
    --from)
      from="$2"
      shift 2
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
      [[ -n "$program" ]] && die "Only one program name may be provided"
      program="$1"
      shift
      ;;
    esac
  done

  [[ -z "$program" ]] && die "Usage: inputman freeze <program> --channel <ch> --as <version> [--tag <t>|--rev <sha>] [--from <input>]"
  [[ -z "$channel" ]] && die "freeze requires --channel <channel>"
  [[ -z "$version" ]] && die "freeze requires --as <version>"
  [[ -f flake.nix ]] || die "No flake.nix found — run from the repo root"
  [[ -f channel-sources.nix ]] || die "No channel-sources.nix found — run from the repo root"
  [[ "$program" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "Program name '${program}' is not a valid Nix identifier"

  [[ -z "$from" ]] && from="${program}-main"

  local base
  base=$(locked_github_base "$from" 2>/dev/null || true)
  [[ -z "$base" ]] &&
    die "Could not determine github base for '${from}' from flake.lock (only github inputs are supported)."

  local url
  if [[ -n "$tag" ]]; then
    url="${base}/${tag}"
  elif [[ -n "$rev" ]]; then
    url="${base}?rev=${rev}"
  else
    local cur_rev
    cur_rev=$(locked_input_rev "$from" 2>/dev/null || true)
    [[ -z "$cur_rev" ]] && die "Could not read current locked rev of '${from}' from flake.lock."
    url="${base}?rev=${cur_rev}"
    info "Freezing current rev of '${from}': ${cur_rev}"
  fi

  local slug frozen_name
  slug=$(slug_version "$version")
  frozen_name="${program}-frozen-${slug}"

  # Mirror the moving input's flake-ness: a `flake = false` source cannot carry
  # follows, so the frozen sibling must be flake=false too (and vice versa).
  local nonflake
  nonflake=$(locked_input_is_nonflake "$from" 2>/dev/null || true)

  if grep -qP "^\s+${frozen_name}[. =]" flake.nix; then
    warn "Frozen input '${frozen_name}' already exists in flake.nix; repointing channel only."
  elif [[ -n "$nonflake" ]]; then
    patch_flake_add_nonflake "$frozen_name" "$url"
    ok "Added frozen input '${frozen_name}' (flake = false) -> ${url}"
  else
    patch_flake_add "$frozen_name" "$url" "nixpkgs=nixpkgs"
    ok "Added frozen input '${frozen_name}' -> ${url}"
  fi

  ensure_channel_map_block "$program"
  patch_channel_map_set "$program" "$channel" "$frozen_name"
  ok "Repointed channel '${channel}' -> ${frozen_name}"

  info "Locking inputs (locker) ..."
  locker -n

  local news_file
  news_file=$(write_news_entry freeze "$program" \
    "Channel: ${channel}"$'\n'"Frozen input: ${frozen_name}"$'\n'"Version: ${version}"$'\n'"URL: ${url}") || news_file=""

  git add flake.nix channel-sources.nix
  git add flake.lock 2>/dev/null || true
  [[ -n "$news_file" ]] && git add "$news_file"
  finalize_commit "inputMan: freeze ${program} @ ${version} for ${channel}" "$auto_commit" "$no_commit"
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
group-install)
  shift
  cmd_group_install "$@"
  ;;
freeze)
  shift
  cmd_freeze "$@"
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
__patch-flake-add-nonflake)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman __patch-flake-add-nonflake <name> <url>"
  patch_flake_add_nonflake "$1" "$2"
  ;;
__locked-input-is-nonflake)
  shift
  [[ $# -eq 1 ]] || die "Usage: inputman __locked-input-is-nonflake <name>"
  locked_input_is_nonflake "$1"
  echo
  ;;
__parse-packages-spec)
  shift
  [[ $# -eq 2 ]] || die "Usage: inputman __parse-packages-spec <input-name> <spec>"
  parse_packages_spec "$1" "$2"
  ;;
__patch-channel-map-set)
  shift
  [[ $# -ge 3 ]] || die "Usage: inputman __patch-channel-map-set <program> <channel> <input-name> [file]"
  patch_channel_map_set "$@"
  ;;
__ensure-channel-map-block)
  shift
  [[ $# -ge 1 ]] || die "Usage: inputman __ensure-channel-map-block <program> [file]"
  ensure_channel_map_block "$@"
  ;;
__slug-version)
  shift
  [[ $# -eq 1 ]] || die "Usage: inputman __slug-version <version>"
  slug_version "$1"
  echo
  ;;
__generate-group-aggregator)
  shift
  [[ $# -eq 1 ]] || die "Usage: inputman __generate-group-aggregator <program>"
  generate_group_aggregator "$1"
  ;;
__locked-input-rev)
  shift
  [[ $# -eq 1 ]] || die "Usage: inputman __locked-input-rev <name>"
  locked_input_rev "$1"
  echo
  ;;
__locked-github-base)
  shift
  [[ $# -eq 1 ]] || die "Usage: inputman __locked-github-base <name>"
  locked_github_base "$1"
  echo
  ;;
help | -h | --help) usage ;;
*) die "Unknown command: ${1}. Run 'inputman help' for usage." ;;
esac
