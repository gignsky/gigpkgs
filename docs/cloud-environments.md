# Claude Code cloud environments for gigpkgs

Settings for [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)
cloud environments used to develop `gigpkgs` and other Nix / Rust / Python /
Nushell projects.

Two environments:

| Environment | Purpose | Setup script |
| :---------- | :------ | :----------- |
| **buzz**   | `gigpkgs` + general Nix / Rust work. | [`docs/cloud/buzz-setup.sh`](cloud/buzz-setup.sh) |
| **bumble** | Repo-agnostic polyglot runner: Nix + Rust + Python + Nushell. | [`docs/cloud/bumble-setup.sh`](cloud/bumble-setup.sh) |

Both make `nix` fully usable for **build / run / eval / flake** operations. The
flake **devShell is intentionally not auto-loaded** — see
[The devShell & the GitHub proxy](#the-devshell--the-github-proxy) for why.

The scripts are the source of truth, kept in-repo. To apply them you **paste
the script text into the environment's "Setup script" field** in the web UI —
cloud environment config (setup script, env vars, network access) lives in the
Anthropic account, not in the repo, so editing these files does not change a
live environment until you re-paste.

> **Environment config applies at session start, not to running sessions.**
> After editing an environment, start a *fresh* session to pick up the change.
> Editing the setup script also invalidates the environment cache (below), so
> the script re-runs from the bare base image on the next new session.

## How a cloud environment is configured

Each session runs in a fresh, isolated Anthropic-managed VM with the repo
cloned. An *environment* has three configurable knobs, all edited at
`claude.ai/code` (environment selector → hover → settings icon; or **Add
environment**):

1. **Network access** — `None` / `Trusted` / `Full` / `Custom`.
2. **Environment variables** — `.env` format, one `KEY=value` per line, no
   quotes. No secrets store yet: treat them as visible to anyone who can edit
   the environment.
3. **Setup script** — Bash, runs **as root on Ubuntu 24.04**, once, before
   Claude Code launches.

### Caching — and why the install must be "install-if-missing"

After the setup script finishes, Anthropic snapshots the filesystem and reuses
it for later sessions, skipping the script. So the `/nix` store our script
builds is baked into the snapshot and present at the start of later sessions.
The cache rebuilds (script re-runs on the bare base image) when you **edit the
setup script**, change allowed hosts, or after ~7 days.

This is why step 1 of each script is **install-if-missing**
(`if ! command -v nix …; then install; fi`), not a bare
`command -v nix || exit 1` assert. Nix appears "already installed" only because
a prior run cached it — the base image does **not** ship Nix. An assert-only
script hard-fails on every cache rebuild; install-if-missing is a no-op on a
warm cache and a correct install on a cold one.

### What the base image already provides

Do **not** reinstall these — the cloud image ships them:

- **Rust:** `rustc`, `cargo` (but *not* clippy / rustfmt / rust-analyzer —
  `bumble` adds those).
- **Python 3.x:** `pip`, `poetry`, `uv`, `black`, `mypy`, `pytest`, `ruff`.
- Node (20/21/22 via nvm), Go, Java, Ruby, PHP, C/C++, Docker, PostgreSQL 16,
  Redis 7, plus `git`, `jq`, `yq`, `ripgrep`, `tmux`.

**Not shipped, and added by our scripts:** Nix, flakes, `direnv` /
`nix-direnv`, Nushell (and for `bumble`, the Rust dev components).

## Network access

`Trusted` is sufficient to **install and use Nix**: the default allowlist
already covers everything the scripts and non-devShell flake operations reach:

- `*.nixos.org` → `releases.nixos.org` (the pinned installer + tarball) and
  `cache.nixos.org` (the binary cache). Note the wildcard is subdomains only —
  see [the apex gotcha](#gotcha-the-bare-nixosorg-apex-is-blocked).
- `crates.io` / `pypi.org` for Rust / Python.

You may run buzz on `Full` or `Custom` if you like, but **a higher network
level does not fix the devShell** — that is gated by a different proxy (below),
not the security allowlist.

### Gotcha: the bare `nixos.org` apex is blocked

The default allowlist entry `*.nixos.org` matches **subdomains only**, not the
apex `nixos.org`. So `curl -L https://nixos.org/nix/install` 403s at the egress
proxy. The scripts fetch a **pinned** installer from
`releases.nixos.org/nix/nix-<version>/install` instead (a subdomain); its
tarball is on `releases.nixos.org` and Nix substitutes from `cache.nixos.org`,
so nothing touches the blocked apex. Bump `NIX_VERSION` to upgrade (browse
<https://releases.nixos.org/?prefix=nix/>).

## The devShell & the GitHub proxy

**The single most important limitation.** `nix develop` (and direnv
`use flake`) does **not** work in a cloud session scoped to `gigpkgs`, and no
network setting fixes it. The scripts therefore keep the devShell *off* and
rely on plain `nix build/run/eval/flake`, which need only the local flake and
`cache.nixos.org`.

### Root cause (verified 2026-07-21)

The `gigpkgs` devShell's `shellHook` runs `self.pre-commit-check`, which comes
from the `pre-commit-hooks` flake input, `github:cachix/git-hooks.nix`. Entering
the devShell forces Nix to fetch that input's tarball from `github.com`.

There are **two independent proxies** in a cloud session:

| Proxy | Governs | Blocked request looks like |
| :---- | :------ | :------------------------- |
| **Security proxy** | all outbound HTTPS, per the network **access level** | `example.com` → `curl: (56) CONNECT tunnel failed, response 403` |
| **GitHub proxy** | all `github.com` traffic, scoped to the session's **authorized repos** | app-level `HTTP 403` with body `{"message":"GitHub access to this repository is not enabled for this session. Use add_repo to request access."}` |

`github:cachix/git-hooks.nix` is not one of the session's authorized repos
(only `gignsky/gigpkgs` is), so the GitHub proxy returns a **403**. This is
**independent of the network access level** — adding `github.com` to a `Custom`
allowlist changes only the *security* proxy and does nothing here. Verified: an
*unauthorized* repo's archive 403s whether public (`NixOS/nix`) or personal
(`gignsky/fupdate`, another such input); only the authorized `gigpkgs`
resolves; `raw.githubusercontent.com/<public repo>/…` (individual files) is not
gated. Common inputs like `nixpkgs` resolve only because their **source is
substituted from `cache.nixos.org`**, so no GitHub fetch happens.

There is **no environment setting that pre-authorizes extra GitHub repos**.
`add_repo` is the only mechanism and it is **interactive** — it cannot be
scripted from the setup script.

### What works without the devShell (verified)

```text
nix --version
nix eval  .#packages.x86_64-linux.gignews.name   -> gignews-0.1.2
nix build .#gignews                              -> /nix/store/…-gignews-0.1.2
nix run   .#gignews -- list                      -> runs
nix flake metadata / nix flake show              -> ok
substitution from cache.nixos.org                -> ok
```

### How to enable the devShell later, if ever needed

Pick one:

1. **Authorize the input's repo in-session**: run `add_repo cachix/git-hooks.nix`,
   then `direnv allow` (or `nix develop`). Interactive; scoped to that session;
   repeat for any other unauthorized `github:` input.
2. **Guard the shellHook for cloud sessions**: change `flake.nix` so the
   `pre-commit-check` shellHook is skipped when `CLAUDE_CODE_REMOTE=true`,
   removing the `github.com` dependency from the devShell in cloud sessions
   entirely. This is a permanent, repo-level fix (trade-off: pre-commit hooks
   are not installed in cloud devShells).

The scripts also actively run `direnv deny`/`revoke` on the repo `.envrc`,
because a stale `direnv allow` persists across sessions — passively
not-allowing is unreliable, so we revoke it.

## TLS / proxy — already handled

Outbound HTTPS goes through the egress proxy, and the environment pre-sets
`HTTPS_PROXY`, `NIX_SSL_CERT_FILE`, `SSL_CERT_FILE` etc., with the proxy CA in
the system trust store. The scripts install Nix **single-user / daemonless**
(`--no-daemon`) so builds run as root and inherit those variables; a
`nix-daemon` would run without them and its fetches would fail.

## Environment variables

None required — `/etc/nix/nix.conf` (written by the setup script) carries the
flakes settings, and TLS/proxy vars are pre-set. Optional, in `.env` format:

```text
DIRENV_LOG_FORMAT=
```

(An empty `DIRENV_LOG_FORMAT` silences direnv's per-command banner.)

## Using the tools in a session

The scripts symlink the Nix profile into `/usr/local/bin`, so `nix`, `direnv`,
`just`, `nu` (and on `bumble` `clippy`/`rustfmt`/`rust-analyzer`) are on `PATH`
for Claude's non-login shells.

- **gigpkgs:** use `nix build/run/eval/flake` directly (devShell not needed):

  ```bash
  nix build .#gignews
  nix run   .#locker -- --help
  nix eval  .#packages.x86_64-linux.gignews.name
  ```

- **Repo-agnostic (bumble):** `nu`, `cargo`, `clippy`, `cargo fmt`,
  `rust-analyzer`, and the base Python stack are on `PATH`; per-project pins
  come from each repo's own flake (once its inputs are authorized).

## Applying changes

1. Open `claude.ai/code`, click the environment selector.
2. **buzz:** hover → settings → paste `docs/cloud/buzz-setup.sh` into
   *Setup script*, save.
3. **bumble:** **Add environment**, name it `bumble`, paste
   `docs/cloud/bumble-setup.sh`, save.
4. Start a **fresh** session in each (editing the script rebuilds the cache, so
   the first new session re-runs the install). Confirm with `nix --version`,
   `nix build .#gignews`, and `nu --version`.
