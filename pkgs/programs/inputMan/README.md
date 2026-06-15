# inputMan

`inputman` manages external flake inputs for gigpkgs-style repositories.

## Commands

- `inputman install <url>`
- `inputman update <name>`
- `inputman remove <name>`

## Install examples

```bash
inputman install github:nix-community/nur
inputman install github:gignsky/gigvim --follows nixpkgs=nixpkgs --yes
inputman install github:nix-community/home-manager --name home-manager --no-info --no-branch
```

## Update / remove examples

```bash
inputman update gigvim -y
inputman remove gigvim --no-commit
```

## Install options

- `--name <name>`: override inferred input name
- `--packages <p1,p2>`: explicit package list (skip discovery)
- `--follows <key=value>`: add `inputs.<key>.follows` overrides (repeatable)
- `--no-info`: skip metadata probe output
- `--no-branch`: skip creating `add-input/<name>` from `origin/main`
- `--yes`, `-y`: commit automatically
- `--no-commit`, `-n`: stage only

## Notes

- On install failure after writing files, inputMan rolls back `flake.nix` and the generated `pkgs/inputs/<name>.nix` file.
- `update` and `remove` always refresh `flake.lock` and stage resulting changes.
