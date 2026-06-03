# gigpkgs-news

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
  imports = [ inputs.gigpkgs.homeModules.gigpkgs-news ];
  
  # Optional: disable if you don't want news on activation
  # gigpkgs.news.enable = false;
}
```

### CLI Commands

```bash
# Show unread entries (default)
gigpkgs-news

# List all entries (read and unread)
gigpkgs-news list

# Mark a specific entry as read
gigpkgs-news read <entry-id>

# Mark all entries as read
gigpkgs-news read-all

# Show a specific entry
gigpkgs-news show <entry-id>
```

### Read State

News read state is tracked in `~/.local/share/gigpkgs/news-read` as a newline-separated list of entry IDs.

## Adding News Entries

Create a new file in `news/entries/` with the format: `YYYY-MM-DD-slug.nix`

```nix
{
  id = "2026-06-03-my-news";
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
- **date** (required): ISO date string (YYYY-MM-DD) for sorting
- **message** (required): Freeform text displayed to users
- **condition** (optional): Lambda that receives `{ pkgs, config, lib }` and returns bool

## Architecture

```
gigpkgs/
  news/
    entries/           # News entry files (.nix)
    default.nix        # Collector and JSON builder
  pkgs/programs/
    gigpkgs-news/      # CLI package
  modules/home/
    gigpkgs-news.nix   # HM activation module
```

The system works by:
1. Collecting all `.nix` files from `news/entries/`
2. Evaluating optional conditions at build time
3. Generating a JSON file in the Nix store
4. Baking that JSON path into the `gigpkgs-news` CLI
5. Running the CLI during HM activation to display unread entries

## Development

Test the news system:

```bash
# Build and test the CLI
nix build .#gigpkgs-news
./result/bin/gigpkgs-news

# Check news entries evaluation
nix eval .#news.entries --json

# View the homeModule
nix eval .#homeModules.gigpkgs-news
```
