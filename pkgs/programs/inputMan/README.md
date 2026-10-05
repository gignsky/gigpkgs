# inputMan

`inputman` manages external flake inputs for gigpkgs-style repositories: it
adds inputs, wires follows, exposes packages, and auto-discovers
`homeManagerModules` / `nixosModules` exposed by the input flake.

## Commands

- `inputman install <url>` — add an input; discover packages + modules; write
  `pkgs/inputs/<name>.nix` and, when applicable, `modules/home/inputs/<name>.nix`
  and `modules/nixos/inputs/<name>.nix`.
- `inputman update <name>` — refresh the lock; re-scan the input; prompt to
  include any new packages or modules.
- `inputman remove <name>` — drop the input, its packages/module files, and the
  entries in `flake.nix`.
- `inputman pin <name> <ref>` — lock a single input to a specific tag/rev,
  independent of every other input's locked version.
- `inputman versions <name>` — list known upstream tags for an input (and
  which one is currently locked), as candidates for `pin`.
- `inputman branch <name> [branch]` — point an input at a different branch and
  relock it; fuzzy-picks from the remote's branches via `fzf` when none is
  given.

## Install examples

```bash
inputman install github:nix-community/nur
inputman install github:gignsky/gigvim -f nixpkgs=nixpkgs --yes
inputman install github:gignsky/roll-flow -f gigpkgs/nixpkgs=nixpkgs-master
inputman install github:someone/flake -f              # follow the current gigpkgs
inputman install github:gignsky/gigvim -p default=gigvim,nightly=gigvim-nightly
```

## Update / remove examples

```bash
inputman update gigvim -y
inputman update gigvim               # prompts per new package/module
inputman remove gigvim --no-commit
```

## Pin / versions / branch examples

```bash
inputman versions roll-flow          # list upstream tags + recorded versions
inputman pin roll-flow v0.2.3        # lock just roll-flow back to that tag
inputman update roll-flow            # drop the pin, resume tracking the branch HEAD

inputman branch roll-flow develop    # track a rolling branch
inputman pin roll-flow 0.2.5         # ...then pin back to a version that branch
                                      # reported but never tagged upstream

inputman branch roll-flow            # fuzzy-pick a branch from the upstream repo
```

`pin` only edits that one input's node in `flake.lock` — every other input's
locked revision is untouched, so you don't have to roll back the whole
gigpkgs repo (and every other input with it) just to get one input back to an
older version. The pin sticks until you `update` or `pin` that input again.

`branch` instead rewrites the input's `url` in `flake.nix` (so it keeps
tracking that branch on future `update` runs) and relocks it. With no branch
argument it fetches the upstream repo's branches and opens an `fzf` picker.

Both `pin` and `branch` currently only support `github:owner/repo`-style
inputs (everything inputMan manages today).

### Local version ledger

`install`, `update`, `branch`, and `pin` all record every `{rev, date,
versions}` they observe into `pkgs/inputs/.versions.json` (committed like any
other generated file). This matters for inputs tracked against a rolling
branch rather than tagged releases: upstream only has git tags for actual
releases, so a `develop`-branch commit reporting version `0.2.6` has no tag
to pin back to later — only gigpkgs' own history knows which rev that was.

`pin <name> <ref>` uses this ledger automatically: it first checks whether
`<ref>` matches a version string this repo has previously recorded for
`<name>` (on any exposed package alias), and if so pins to the exact rev that
version came from. Only when there's no match does it fall back to treating
`<ref>` as a literal upstream tag/branch/rev. `inputman versions <name>`
shows both sources — upstream tags, and anything recorded locally that isn't
one — so you can see what's actually pinnable.

## Install options

- `--name <name>` — override the inferred input name.
- `--packages, -p <spec>` — package selection.
  - `pkg=alias,pkg2=alias2` → only listed packages exposed, with the given
    aliases. Use `pkg=-` to explicitly drop a package.
  - `pkg1,pkg2` → legacy include list; alias defaults to the input name for
    `default`, otherwise `<input>-<pkg>`.
  - Bare `-p` → prompt per discovered package (blank = default alias, `-` to
    skip).
- `--follows, -f <spec>` — follows override. Repeatable.
  - `key=target` → `<input>.inputs.<key>.follows = "target";`
  - `parent/child=target` or `parent.child=target` → nested chain
    `<input>.inputs.<parent>.inputs.<child>.follows = "target";`
  - Bare `-f` / `--follows` → `<input>.inputs.<self>.follows = "";` where
    `<self>` is `basename $(pwd)` (i.e., the current flake's name).
- `--no-info` — skip metadata probe output.
- `--no-branch` — skip creating `add-input/<name>` from `origin/master`.
- `--no-modules` — skip module discovery for this install.
- `--yes`, `-y` — accept prompts (default aliases) and commit without asking.
- `--no-commit`, `-n` — stage only.

## Update options

- `--no-modules` — skip module re-scan.
- `--yes`, `-y` — auto-include new packages/modules with default aliases; commit.
- `--no-commit`, `-n` — stage only.

## Pin options

- `--yes`, `-y` — commit without prompting.
- `--no-commit`, `-n` — stage only.

## Versions options

- `--limit <n>` — max tags to show (default: 25, newest first).

## Branch options

- `--yes`, `-y` — commit without prompting.
- `--no-commit`, `-n` — stage only.

## News entries

Every `install` / `update` / `remove` / `pin` / `branch` writes a
`news/entries/*.nix` entry that records *what* changed, not just that
something did:

- `update` — locked revision and upstream date on either side of the refresh,
  plus a version bump line for each exposed package that declares a `version`
  attribute. When exactly one package changed version, the bump is also put in
  the entry's first line, which `gignews` shows as the title:

  ```
  Updated flake input 'roll-flow' (0.2.3 -> 0.2.4)

  Revision: f9d75fc -> a1b2c3d
  Upstream date: 2026-09-15 -> 2026-09-19
  Versions:
    roll-flow 0.2.3 -> 0.2.4
  ```

  If the refresh found nothing new, the entry says so instead of implying a
  change.
- `install` — the revision, upstream date, and package versions the input
  entered the repo at, so the first `update` has a baseline to diff against.
- `remove` — the revision the input was locked at when it was dropped.
- `pin` — the ref it was pinned to and the resulting revision/version diff,
  same shape as `update`'s entry.
- `branch` — the new branch and the resulting revision/version diff.

Inputs whose packages carry no `version` attribute (a plain wrapper
derivation, for instance) simply report the revision diff.

## Notes

- On install failure after writing files, inputMan rolls back `flake.nix`, the
  generated `pkgs/inputs/<name>.nix`, generated module aggregators, and the news
  entry.
- Single-output input packages are auto-included in the gigpkgs devShell via
  `pkgs/inputs/devShellPackages.nix` — no per-package edit to `flake.nix`
  needed. Multi-variant inputs (no `packages.<system>.default`) must be added
  by name to `flake.nix` explicitly.
- Module aggregators generated under `modules/<home|nixos>/inputs/` are picked
  up automatically by `modules/<home|nixos>/default.nix`.
