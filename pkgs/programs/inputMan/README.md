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
- `inputman pin <name> <ref>` — materialize a permanent `<name>-<ref>` package
  (e.g. `roll-flow-0.2.5`), backed by its own frozen flake input. The bare
  `<name>` package is untouched. `update`/`branch` also do this automatically
  whenever they move `<name>` to a new version.
- `inputman versions <name>` — list known versions for an input: upstream
  tags, plus anything recorded in gigpkgs' own update/branch history, marking
  which ones are already materialized — as candidates for `pin`.
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
inputman pin roll-flow v0.2.3        # materialize roll-flow-v0.2.3, permanently

inputman branch roll-flow develop    # track a rolling branch — bare roll-flow
                                      # follows it (and roll-flow-0.2.5,
                                      # roll-flow-0.2.6 get materialized
                                      # automatically for the before/after
                                      # versions of that move)

inputman pin roll-flow 0.2.5         # materialize roll-flow-0.2.5 directly,
                                      # resolved from recorded history even
                                      # though 0.2.5 was never tagged upstream

inputman branch roll-flow            # fuzzy-pick a branch from the upstream repo
```

### How pin/versions/branch fit together

The bare `<name>` package (e.g. `roll-flow`) always reads from `<name>`'s own
flake input — exactly like before `pin`/`branch` existed. `update` moves it
forward within whatever ref it's on; `branch` points it at a different ref
entirely. Neither touches a package that's already been pinned.

`pin <name> <ref>` never redirects the bare package. Instead it adds a brand
new, separate flake input (e.g. `roll-flow-0_2_5`, locked once to `<ref>` and
never touched again) and exposes it as `"<name>-<ref>"` in
`pkgs/inputs/<name>.nix` (e.g. `"roll-flow-0.2.5"`, a quoted attribute name —
Nix allows dots there). It's idempotent: pinning the same `<ref>` twice is a
no-op the second time.

`<ref>` can be a literal upstream tag/branch/rev, or a version string this
repo has previously recorded for `<name>` — which matters because a rolling
branch (e.g. `develop`) only ever gets git tags for its actual releases, so a
commit reporting version `0.2.6` partway through `develop` has no tag to pin
back to later. `update` and `branch` both record every `{rev, date, versions}`
they observe into a local ledger at `pkgs/inputs/.versions.json` (committed
like any other generated file) precisely so `pin` can resolve a bare version
string like `0.2.5` back to the exact rev it came from.

`update` and `branch` also call this same materialization automatically
whenever they move `<name>`'s own version forward — for *both* the version
being left behind and the one just moved to — so every version a gigpkgs
input has ever actually run at stays available by name, not just the ones
you explicitly `pin`.

`inputman versions <name>` lists both sources (upstream tags, and anything
recorded locally that isn't one) and marks which ones already have a
materialized package.

`pin` and `branch` currently only support `github:owner/repo`-style inputs
(everything inputMan manages today). Materialized packages only cover the
primary/default package of an input, not every alias a multi-package input
might expose.

**CLI quoting:** a dotted attribute name like `"roll-flow-0.2.5"` works fine
from other Nix code (e.g. `pkgs."roll-flow-0.2.5"` in a home-manager config),
but `nix`'s `.#attr` terminal shorthand splits on dots, so
`nix build .#roll-flow-0.2.5` fails with "Did you mean roll-flow?". Quote the
attribute instead: `nix build '.#"roll-flow-0.2.5"'`.

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
  change. When the primary package's version actually changed, an `Archived
  as:` line lists any `<name>-<version>` packages materialized for it.
- `install` — the revision, upstream date, and package versions the input
  entered the repo at, so the first `update` has a baseline to diff against.
- `remove` — the revision the input was locked at when it was dropped.
- `pin` — which version was materialized and the permanent package name it
  got.
- `branch` — the new branch and the resulting revision/version diff, plus any
  versions `branch` materialized automatically along the way.

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
