# gignews

A lightweight news and changelog system for gigpkgs, modeled on home-manager's news mechanism.

## Overview

When you activate a new home-manager generation built with gigpkgs, unread news entries are automatically displayed. This keeps you informed about:
- New packages added to gigpkgs
- Breaking changes or deprecations
- Important updates and improvements

## Usage

### As a gigpkgs Consumer

Import the home-manager module in your home configuration:

```nix
# In your home.nix or similar
{
  imports = [ inputs.gigpkgs.homeModules.gignews ];

  # Optional: disable if you don't want news on activation
  # gigpkgs.news.enable = false;
}
```

### CLI Commands

Entries are shown with a short, stable number (e.g. `#3`). Commands that take an
entry accept either that number or the full string id.

```bash
# Show unread entries (default)
gignews

# List all entries (read and unread)
gignews list

# Mark one or more entries as read (by number or id)
gignews read 3
gignews read 2026-06-03-news-system-launch
gignews read 3 4 5    # multiple at once (space- or comma-separated)
gignews read 3,4,5

# Mark all entries as read
gignews read-all

# Show a specific entry (by number or id)
gignews show 3
```

### Read State

News read state is tracked in `~/.local/share/gigpkgs/news-read` as a newline-separated list of entry ids (the string `id`, not the number).

## Adding News Entries

Create a new file in `news/entries/` with the format: `YYYY-MM-DD-slug.nix`

```nix
{
  id = "2026-06-03-my-news";
  num = 10; # next unused number (see below)
  date = "2026-06-03";

  # Optional: only show if condition is true
  # condition = { pkgs, ... }: pkgs ? myNewPackage;

  message = ''
    My News Title

    This is the news content. It will be displayed to users
    when they activate a new home-manager generation.
  '';
}
```

### Entry Fields

- **id** (required): Unique identifier, typically matches filename
- **num** (required): Short, stable integer id. Unique across all entries and never
  reused — give a new entry the next unused number. Used so entries can be marked
  read by number (`gignews read <num>`) instead of the full id. The build fails if
  any entry is missing `num` or if two entries share the same `num`.
- **date** (required): ISO date string (YYYY-MM-DD) for sorting
- **message** (required): Freeform text displayed to users
- **condition** (optional): Lambda that receives `{ pkgs, config, lib }` and returns bool

## Architecture

```
gigpkgs/
  news/
    entries/           # News entry files (.nix)
    default.nix        # Collector, num validation, and JSON builder
  pkgs/programs/
    gignews/           # CLI package
  modules/home/
    gignews.nix        # HM activation module
```

The system works by:
1. Collecting all `.nix` files from `news/entries/`
2. Evaluating optional conditions at build time
3. Validating that every entry has a unique `num`
4. Generating a JSON file in the Nix store
5. Baking that JSON path into the `gignews` CLI
6. Running the CLI during HM activation to display unread entries

## Development

Test the news system:

```bash
# Build and test the CLI
nix build .#gignews
./result/bin/gignews

# Check news entries evaluation
nix eval .#news.entries --json

# View the homeModule
nix eval .#homeModules.gignews
```
