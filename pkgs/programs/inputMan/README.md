# inputMan

`inputman` manages external flake inputs for gigpkgs-style repositories: it
adds inputs, wires follows, exposes packages, and auto-discovers
`homeModules` / `nixosModules` exposed by the input flake.

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
- `--no-branch` — skip creating `add-input/<name>` from `origin/main`.
- `--no-modules` — skip module discovery for this install.
- `--yes`, `-y` — accept prompts (default aliases) and commit without asking.
- `--no-commit`, `-n` — stage only.

## Update options

- `--no-modules` — skip module re-scan.
- `--yes`, `-y` — auto-include new packages/modules with default aliases; commit.
- `--no-commit`, `-n` — stage only.

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
