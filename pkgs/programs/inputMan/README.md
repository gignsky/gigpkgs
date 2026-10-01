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

## News entries

Every `install` / `update` / `remove` writes a `news/entries/*.nix` entry that
records *what* changed, not just that something did:

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
