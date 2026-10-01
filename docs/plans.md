# gigpkgs: Implementation Plans

---

## 1. `add-input` — Interactive Flake Input Installer

### Goal

A Nu script that fully onboards a new flake input into gigpkgs: fetches metadata, prompts for configuration decisions, writes a per-input package file, updates the lock, and commits — all from one command.

### Invocation

```
add-input <flake-url>
# e.g.
add-input github:gignsky/gigvim
add-input github:nix-community/nixos-anywhere
```

### Execution Flow

1. **Probe the input**
   - Run `nix flake metadata <url>` — capture description, resolved URL, last modified
   - Run `nix flake show <url> --json` — capture the output schema (packages, overlays, nixosModules, homeManagerModules, lib, …)
   - Display a summary to the user

2. **Collect configuration (interactive prompts)**
   - **Name**: suggested from the repo name, user can override
   - **Branch / ref**: default to what was given; allow override
   - **Follows overrides**: list each of the new input's declared inputs; user checks which to override (e.g. `nixpkgs → gigpkgs/nixos-stable`) — circular-dep prevention shown for inputs that match existing gigpkgs inputs
   - **Circular-dep break**: if the new input declares a `gigpkgs` or `dotfiles` input, auto-suggest `follows = ""` to break the cycle; confirm with user
   - **Package aliases**: if the input exports `packages.*` or `legacyPackages.*`, prompt for which to surface as top-level `pkgs.X` attributes (e.g. `gigvim.packages.x86_64-linux.default → pkgs.gigvim`)
   - **Overlay wiring**: if the input exports `overlays.*`, prompt whether to compose into `overlays/default.nix`

3. **Branch**
   - Create a new git branch from `main`: `add-input/<name>` (e.g. `add-input/gigvim`)

4. **Write per-input file**
   - Create `pkgs/inputs/<name>.nix` (auto-scanned by `pkgs/default.nix`)
   - File structure:
     ```nix
     # pkgs/inputs/gigvim.nix
     { inputs, pkgs, system, ... }:
     {
       gigvim       = inputs.gigvim.packages.${system}.default;
       gigvim-mini  = inputs.gigvim.packages.${system}.mini;
     }
     ```
   - Only generated for aliases the user confirmed

5. **Patch `flake.nix` inputs section**
   - Append the new input block (with follows overrides) to `flake.nix`
   - Use a structured edit (sed-like) targeting the `inputs = { … };` block
   - If the user requested overlay wiring, patch `overlays/default.nix` too

6. **Update lock**
   - Run `locker -y` (gigpkgs's lock-update tool) to fetch and pin the new input

7. **Commit**
   - Stage `flake.nix`, `flake.lock`, `pkgs/inputs/<name>.nix`, `overlays/default.nix` (if changed)
   - Commit message: `add input: <name> (<resolved-url>)`

### File Layout

```
pkgs/
  inputs/         ← auto-scanned directory (one file per external input)
    gigvim.nix
    wrapd.nix
    …
  default.nix     ← scanPaths ./inputs ++ local defs
```

`pkgs/default.nix` should call `lib.scanPaths ./inputs` (or a builtins equivalent) so dropping a new file here automatically includes it — no manual registration.

### Error Handling

- If `nix flake metadata` fails (network, bad URL): print error and exit cleanly
- If the input name already exists in `flake.nix`: warn and ask to update or abort
- If pre-commit hooks fail on commit: leave branch in place, print instructions

### Script Location

`scripts/add-input.nu` — exposed as `pkgs.add-input` and included in the gigpkgs devShell.

---

## 2. `gigpkgs-news` — Versioned News & Changelog System

### Goal

A lightweight news system modelled on home-manager's own news mechanism. When a user activates a new home-manager generation (built from gigpkgs), unread news entries are displayed. A CLI lets users read, list, and dismiss entries.

### Architecture

```
gigpkgs/
  news/
    entries/
      2025-06-01-scanPaths-available.nix
      2025-06-03-gigvim-packaged.nix
      …
    default.nix     ← imports all entries, returns list
  pkgs/
    gigpkgs-news/   ← the CLI package
      gigpkgs-news.nu
      default.nix
  modules/
    home/
      gigpkgs-news.nix  ← HM activation module
```

### News Entry Format

```nix
# news/entries/2025-06-03-gigvim-packaged.nix
{
  id      = "2025-06-03-gigvim-packaged";
  date    = "2025-06-03";
  # Optional condition: only show if this evaluates true in the HM context
  # condition = { pkgs, ... }: pkgs ? gigvim;
  message = ''
    gigvim is now available as pkgs.gigvim and pkgs.gigvim-mini.
    Use it in your home config: programs.neovim.package = pkgs.gigvim;
  '';
}
```

Fields:
- `id` — unique slug (also the key used for read-state tracking)
- `date` — ISO date string, used for sorting
- `condition` — optional lambda `{ pkgs, config, ... } → bool`; entry is skipped when false
- `message` — freeform string displayed to the user

### Build-time Baking

`news/default.nix` collects all entries and evaluates conditions at build time (for conditions that don't need runtime context):

```nix
{ pkgs, config, ... }:
let
  allEntries = import lib.scanPaths ./entries;  # list of entry attrsets
  applicable = builtins.filter
    (e: if e ? condition then e.condition { inherit pkgs config; } else true)
    allEntries;
in
{
  # Baked as a JSON file in the store at activation time
  newsJson = pkgs.writeText "gigpkgs-news.json"
    (builtins.toJSON applicable);
}
```

The resulting JSON is a store path embedded in the activation script — no network access needed at read time.

### `gigpkgs-news` CLI

A Nu script at `pkgs/gigpkgs-news/gigpkgs-news.nu`:

```
gigpkgs-news            # show all unread entries (default)
gigpkgs-news list       # list all entries (read and unread)
gigpkgs-news read <id>  # mark a specific entry as read
gigpkgs-news read-all   # mark all as read
gigpkgs-news show <id>  # display a specific entry regardless of read state
```

**State file**: `~/.local/share/gigpkgs/news-read` — newline-separated list of read entry IDs.

**Display**: entries shown as formatted blocks with date header; unread count shown in summary line.

### HM Activation Module

`modules/home/gigpkgs-news.nix` — imported by gigpkgs's HM homeManagerModules:

```nix
{ config, pkgs, lib, newsJson, ... }:
{
  options.gigpkgs.news.enable = lib.mkEnableOption "gigpkgs news on activation" // { default = true; };

  config = lib.mkIf config.gigpkgs.news.enable {
    home.activation.gigpkgsNews = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.gigpkgs-news}/bin/gigpkgs-news --news-file ${newsJson}
    '';
  };
}
```

The `newsJson` store path is injected via `_module.args` from the `news/default.nix` evaluation, so it's always the JSON matching the current generation.

### Consumer Integration (dotfiles side)

In a home config, import the module:

```nix
imports = [ inputs.gigpkgs.homeManagerModules.gigpkgs-news ];
```

Or disable it:

```nix
gigpkgs.news.enable = false;
```

No other configuration required — the news list is baked into the package at build time.

### Implementation Phases

**Phase 1 — Core machinery**
- `news/entries/` directory with 2–3 seed entries
- `news/default.nix` collector (returns list of attrsets)
- JSON baking via `pkgs.writeText`

**Phase 2 — CLI**
- `gigpkgs-news.nu` with `list`, `read`, `read-all`, `show` subcommands
- State file read/write
- Formatted output

**Phase 3 — HM activation module**
- `modules/home/gigpkgs-news.nix`
- Wire `newsJson` through `_module.args`
- Export as `homeManagerModules.gigpkgs-news` in `flake.nix`

**Phase 4 — `add-input` integration**
- When `add-input` onboards a new input that exposes packages, auto-generate a news entry announcing the new `pkgs.X` aliases
